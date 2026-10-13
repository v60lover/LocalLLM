import XCTest
@testable import LocalLLMChat

#if os(macOS)
/// Manually advanced clock; sleepers resume when `advance` passes their deadline.
final class SupervisorFakeClock: SupervisorClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time = Duration.zero
    private var waiters: [UUID: (deadline: Duration, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var cancelled: Set<UUID> = []

    var sleeperCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    /// True when some sleeper would wake after exactly `remaining` more time. Lets a test wait for
    /// one specific timer (idle countdown, ping timeout, ...) instead of just "some timer".
    func hasSleeper(remaining: Duration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiters.values.contains { $0.deadline - time == remaining }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let shouldCancel = lock.withLock { () -> Bool in
                    if cancelled.remove(id) != nil || Task.isCancelled { return true }
                    waiters[id] = (time + duration, continuation)
                    return false
                }
                if shouldCancel { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> (deadline: Duration, continuation: CheckedContinuation<Void, Error>)? in
                let waiter = waiters.removeValue(forKey: id)
                if waiter == nil { cancelled.insert(id) }
                return waiter
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        lock.lock()
        time += duration
        let due = waiters.filter { $0.value.deadline <= time }
        for id in due.keys { waiters[id] = nil }
        lock.unlock()
        for waiter in due.values { waiter.continuation.resume() }
    }
}

/// One-shot gate a fake worker can wait on until the test opens it.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let passes = lock.withLock { () -> Bool in
                if !opened { waiters.append(continuation) }
                return opened
            }
            if passes { continuation.resume() }
        }
    }

    func open() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            let released = waiters
            waiters = []
            return released
        }
        for waiter in released { waiter.resume() }
    }
}

private extension WorkerRequest {
    var isHello: Bool { if case .hello = self { true } else { false } }
    var isLoad: Bool { if case .load = self { true } else { false } }
    var isGenerate: Bool { if case .generate = self { true } else { false } }
    var isCancel: Bool { if case .cancel = self { true } else { false } }
    var openedSession: UUID? { if case .openSession(let id, _, _) = self { id } else { nil } }
    var closedSession: UUID? { if case .closeSession(let id) = self { id } else { nil } }
}

private final class FakeLink: WorkerLink, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [WorkerRequest] = []
    private(set) var invalidations: [Bool] = []
    private var dead = false
    private var hung: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelledHangs: Set<UUID> = []
    var onRequest: (@Sendable (WorkerRequestEnvelope, FakeLink) async throws -> WorkerReplyEnvelope?)?
    let events: any WorkerConnectionEvents
    let onTermination: @Sendable () -> Void
    private var nextSequence = 0

    init(events: any WorkerConnectionEvents, onTermination: @escaping @Sendable () -> Void) {
        self.events = events
        self.onTermination = onTermination
    }

    var generateCount: Int { count { $0.isGenerate } }
    var helloCount: Int { count { $0.isHello } }
    var sawUnload: Bool { snapshot { $0.requests.contains(.unload) } }
    var isDead: Bool { snapshot { $0.dead } }

    func count(_ matches: (WorkerRequest) -> Bool) -> Int {
        snapshot { $0.requests.filter(matches).count }
    }

    private func snapshot<T>(_ body: (FakeLink) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }

    func send(_ request: WorkerRequestEnvelope) async throws -> WorkerReplyEnvelope {
        if isDead { throw CocoaError(.xpcConnectionInterrupted) }
        lock.withLock { requests.append(request.request) }
        if let custom = try await onRequest?(request, self) { return custom }
        let reply: WorkerReply
        switch request.request {
        case .hello(let version): reply = .hello(version: version)
        case .load: reply = .loaded(contextSize: 4096)
        default: reply = .accepted
        }
        return WorkerReplyEnvelope(requestID: request.requestID, reply: reply)
    }

    /// Models a worker that never answers: returns only when the connection goes away or the
    /// caller is cancelled, like an XPC call whose reply never comes.
    func hang() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let failure = lock.withLock { () -> Error? in
                    if dead { return CocoaError(.xpcConnectionInterrupted) }
                    if cancelledHangs.remove(id) != nil { return CancellationError() }
                    hung[id] = continuation
                    return nil
                }
                if let failure { continuation.resume(throwing: failure) }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                let waiter = hung.removeValue(forKey: id)
                if waiter == nil { cancelledHangs.insert(id) }
                return waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    private func die() {
        let stuck = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            dead = true
            let stuck = Array(hung.values)
            hung = [:]
            return stuck
        }
        for waiter in stuck { waiter.resume(throwing: CocoaError(.xpcConnectionInterrupted)) }
    }

    func invalidate(terminate: Bool) {
        lock.withLock { invalidations.append(terminate) }
        die()
    }

    /// Simulates the process dying: later sends fail and the connection reports termination.
    func crash() {
        die()
        onTermination()
    }

    func emit(_ events: [WorkerEvent], sequence: Int? = nil) async {
        let number = lock.withLock { () -> Int in
            let number = sequence ?? nextSequence
            nextSequence = number + 1
            return number
        }
        await self.events.deliver(WorkerEventBatch(sequence: number, events: events))
    }

    /// A batch arrived that the Gateway could not decode.
    func emitUndecodableBatch() async {
        await events.protocolBroken()
    }
}

private final class FakeConnector: WorkerConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var all: [FakeLink] = []
    private var attempts = 0
    private var overlapped = false
    var failConnect = false
    /// Called for every new link, so a test can script the worker.
    var configure: (@Sendable (FakeLink) -> Void)?
    /// When set, `connect` waits here before it hands out the link.
    var connectGate: Latch?

    var links: [FakeLink] { lock.withLock { all } }
    var connectCount: Int { lock.withLock { all.count } }
    /// Calls to `connect`, including ones still waiting at `connectGate`.
    var connectAttempts: Int { lock.withLock { attempts } }
    /// True if a link was handed out while an earlier worker had not been invalidated or lost yet:
    /// in production that connection could land on the process being retired.
    var connectedWhileOldAlive: Bool { lock.withLock { overlapped } }

    func connect(
        events: any WorkerConnectionEvents, onTermination: @escaping @Sendable () -> Void
    ) async throws -> any WorkerLink {
        lock.withLock { attempts += 1 }
        if failConnect { throw CocoaError(.xpcConnectionInvalid) }
        await connectGate?.wait()
        let link = FakeLink(events: events, onTermination: onTermination)
        configure?(link)
        lock.withLock {
            if all.contains(where: { !$0.isDead }) { overlapped = true }
            all.append(link)
        }
        return link
    }
}

private func job(_ prompt: String = "hi", model: String = "/models/a") -> WorkerJob {
    WorkerJob(model: .path(model), instructions: nil, transcript: nil, prompt: prompt)
}

private let accepted: @Sendable (WorkerRequestEnvelope) -> WorkerReplyEnvelope = {
    WorkerReplyEnvelope(requestID: $0.requestID, reply: .accepted)
}

/// A worker that answers every generate with the given events.
private func answering(
    _ deltas: [String] = ["Hel", "lo"], transcript: Data = Data("T".utf8)
) -> @Sendable (FakeLink) -> Void {
    { link in
        link.onRequest = { envelope, link in
            guard case .generate = envelope.request else { return nil }
            let id = envelope.requestID
            Task {
                for (index, text) in deltas.enumerated() {
                    await link.emit([.delta(requestID: id, text: text, usedTokens: index + 1)])
                }
                await link.emit([.finished(requestID: id, transcript: transcript, usedTokens: deltas.count)])
            }
            return WorkerReplyEnvelope(requestID: id, reply: .accepted)
        }
    }
}

/// Wraps whatever the link already does, adding a hook that runs first and may suspend.
private func before(
    _ link: FakeLink,
    _ hook: @escaping @Sendable (WorkerRequestEnvelope, FakeLink) async throws -> Void
) {
    let normal = link.onRequest
    link.onRequest = { envelope, link in
        try await hook(envelope, link)
        return try await normal?(envelope, link)
    }
}

/// The first link's generate crashes the worker; later links answer normally.
private func crashingOnFirstGenerate() -> @Sendable (FakeLink) -> Void {
    let attempts = LockedBox(0)
    return { link in
        if attempts.mutate({ $0 += 1; return $0 }) == 1 {
            link.onRequest = { envelope, link in
                guard case .generate = envelope.request else { return nil }
                Task { link.crash() }
                return WorkerReplyEnvelope(requestID: envelope.requestID, reply: .accepted)
            }
        } else {
            answering()(link)
        }
    }
}

final class WorkerSupervisorTests: XCTestCase {
    private var policy: WorkerSupervisorPolicy {
        var policy = WorkerSupervisorPolicy()
        policy.idleTimeout = .seconds(600)
        policy.loadTimeout = .seconds(180)
        policy.pingInterval = .seconds(5)
        policy.pingTimeout = .seconds(10)
        policy.cancelTimeout = .seconds(7)
        policy.connectTimeout = .seconds(30)
        policy.restartDelay = .seconds(1)
        return policy
    }

    /// Polls until the condition holds (or fails after ~5 s). The only place the tests wait on wall time.
    private func eventually(_ message: String = "", _ condition: () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let holds = await condition()
        XCTAssertTrue(holds, message)
    }

    private func make(
        _ connector: FakeConnector, clock: SupervisorFakeClock = SupervisorFakeClock(), policy: WorkerSupervisorPolicy? = nil
    ) -> WorkerSupervisor {
        WorkerSupervisor(connector: connector, clock: clock, policy: policy ?? self.policy)
    }

    private func assertFails(
        _ task: Task<WorkerJobResult, Error>, with expected: WorkerSupervisorError,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as WorkerSupervisorError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: Basics

    func testGenerateStreamsDeltasAndReturnsTheFinishedResult() async throws {
        let connector = FakeConnector()
        connector.configure = answering()
        let supervisor = make(connector)
        let received = LockedBox<[String]>([])
        let result = try await supervisor.generate(job()) { text in received.mutate { $0.append(text) } }
        XCTAssertEqual(result, WorkerJobResult(text: "Hello", transcript: Data("T".utf8), usedTokens: 2))
        XCTAssertEqual(received.value, ["Hel", "lo"])
        let state = await supervisor.state
        XCTAssertEqual(state, .ready)
        XCTAssertTrue(connector.links[0].requests.first?.isHello == true)
        XCTAssertFalse(connector.links[0].sawUnload)
    }

    func testTheWarmModelIsReusedAcrossJobs() async throws {
        let connector = FakeConnector()
        connector.configure = answering()
        let supervisor = make(connector)
        _ = try await supervisor.generate(job())
        _ = try await supervisor.generate(job())
        XCTAssertEqual(connector.connectCount, 1)
        XCTAssertEqual(connector.links[0].generateCount, 2)
        XCTAssertEqual(connector.links[0].count { $0.isLoad }, 1)
    }

    func testJobsRunOneAtATime() async throws {
        let connector = FakeConnector()
        let ids = LockedBox<[UUID]>([])
        connector.configure = { link in
            link.onRequest = { envelope, _ in
                guard case .generate = envelope.request else { return nil }
                ids.mutate { $0.append(envelope.requestID) }
                return accepted(envelope)
            }
        }
        let supervisor = make(connector)
        let first = Task { try await supervisor.generate(job("a")) }
        try await eventually("first job generating") { ids.value.count == 1 }
        let second = Task { try await supervisor.generate(job("b")) }
        try await eventually("second job queued") { await supervisor.queuedCallers == 1 }
        XCTAssertEqual(ids.value.count, 1, "the second job must not start while the first runs")
        let link = connector.links[0]
        await link.emit([.finished(requestID: ids.value[0], transcript: Data(), usedTokens: 0)])
        try await eventually("second job generating") { ids.value.count == 2 }
        await link.emit([.finished(requestID: ids.value[1], transcript: Data(), usedTokens: 0)])
        _ = try await (first.value, second.value)
    }

    // MARK: Idle and wake

    func testIdleTimeoutUnloadsTheModelAndTheNextJobReconnects() async throws {
        let connector = FakeConnector()
        connector.configure = answering()
        let clock = SupervisorFakeClock()
        let supervisor = make(connector, clock: clock)
        _ = try await supervisor.generate(job())
        try await eventually("idle countdown armed") { clock.hasSleeper(remaining: .seconds(600)) }
        clock.advance(by: .seconds(599))
        // The health ping due in that time is the sync point: the idle timer is still one second away.
        try await eventually("ping answered") { connector.links[0].helloCount == 2 }
        try await eventually("idle timer near") { clock.hasSleeper(remaining: .seconds(1)) }
        var state = await supervisor.state
        XCTAssertEqual(state, .ready, "still within the idle timeout")
        XCTAssertFalse(connector.links[0].sawUnload)
        clock.advance(by: .seconds(1))
        try await eventually("idle unload") { connector.links[0].sawUnload }
        try await eventually("worker retired") { connector.links[0].invalidations == [true] }
        state = await supervisor.state
        XCTAssertEqual(state, .idle)
        _ = try await supervisor.generate(job())
        XCTAssertEqual(connector.connectCount, 2)
        XCTAssertFalse(connector.connectedWhileOldAlive)
    }

    func testAJobRestartsTheIdleCountdown() async throws {
        let connector = FakeConnector()
        connector.configure = answering()
        let clock = SupervisorFakeClock()
        let supervisor = make(connector, clock: clock)
        _ = try await supervisor.generate(job())
        try await eventually("idle countdown armed") { clock.hasSleeper(remaining: .seconds(600)) }
        clock.advance(by: .seconds(500))
        try await eventually("ping answered") { connector.links[0].helloCount == 2 }
        try await eventually("100 s left") { clock.hasSleeper(remaining: .seconds(100)) }
        _ = try await supervisor.generate(job())
        try await eventually("countdown restarted") { clock.hasSleeper(remaining: .seconds(600)) }
        clock.advance(by: .seconds(500))
        try await eventually("ping answered again") { connector.links[0].helloCount == 3 }
        try await eventually("100 s left again") { clock.hasSleeper(remaining: .seconds(100)) }
        XCTAssertFalse(connector.links[0].sawUnload)
        clock.advance(by: .seconds(100))
        try await eventually("unloads after the full period") { connector.links[0].sawUnload }
    }

    func testWakeRestartsTheIdleCountdown() async throws {
        let connector = FakeConnector()
        connector.configure = answering()
        let clock = SupervisorFakeClock()
        let supervisor = make(connector, clock: clock)
        _ = try await supervisor.generate(job())
        try await eventually("idle countdown armed") { clock.hasSleeper(remaining: .seconds(600)) }
        clock.advance(by: .seconds(590))
        try await eventually("ping answered") { connector.links[0].helloCount == 2 }
        try await eventually("10 s left") { clock.hasSleeper(remaining: .seconds(10)) }
        await supervisor.systemDidWake()
        try await eventually("countdown restarted") { clock.hasSleeper(remaining: .seconds(600)) }
        clock.advance(by: .seconds(100))
        try await eventually("ping answered after wake") { connector.links[0].helloCount == 3 }
        try await eventually("500 s left") { clock.hasSleeper(remaining: .seconds(500)) }
        XCTAssertFalse(connector.links[0].sawUnload, "the countdown restarted at wake")
        clock.advance(by: .seconds(500))
        try await eventually("unloads after a full idle period") { connector.links[0].sawUnload }
    }

    func testWakeRestartsTheHealthLoop() async throws {
        let connector = FakeConnector()
        connector.configure = answering()
        let clock = SupervisorFakeClock()
        let supervisor = make(connector, clock: clock)
        _ = try await supervisor.generate(job())
        try await eventually("health loop armed") { clock.hasSleeper(remaining: .seconds(5)) }
        clock.advance(by: .seconds(4))
        try await eventually("1 s to the next ping") { clock.hasSleeper(remaining: .seconds(1)) }
        await supervisor.systemDidWake()
        try await eventually("fresh interval") { clock.hasSleeper(remaining: .seconds(5)) }
        clock.advance(by: .seconds(1))
        // Without the restart the old interval would be due now and a ping would go out.
        try await eventually("interval still running") { clock.hasSleeper(remaining: .seconds(4)) }
        XCTAssertEqual(connector.links[0].helloCount, 1)
        clock.advance(by: .seconds(4))
        try await eventually("ping after the fresh interval") { connector.links[0].helloCount == 2 }
    }

    // MARK: Crashes and restarts

    func testCrashBeforeAnyOutputIsReissuedOnAFreshWorker() async throws {
        let connector = FakeConnector()
        connector.configure = crashingOnFirstGenerate()
        let clock = SupervisorFakeClock()
        let supervisor = make(connector, clock: clock)
        let task = Task { try await supervisor.generate(job()) }
        try await eventually("restart delay armed") { clock.hasSleeper(remaining: .seconds(1)) }
        clock.advance(by: .seconds(1))
        let result = try await task.value
        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(connector.connectCount, 2)
        XCTAssertEqual(connector.links[0].invalidations, [true], "the crashed worker is killed")
    }

    func testCrashAfterOutputIsNotReissued() async throws {
        let connector = FakeConnector()
        connector.configure = { link in
            link.onRequest = { envelope, link in
                guard case .generate = envelope.request else { return nil }
                let id = envelope.requestID
                Task {
                    await link.emit([.delta(requestID: id, text: "par", usedTokens: 1)])
                    link.crash()
                }
                return WorkerReplyEnvelope(requestID: id, reply: .accepted)
            }
        }
        let supervisor = make(connector)
        do {
            _ = try await supervisor.generate(job())
            XCTFail("expected an interruption")
        } catch let error as WorkerSupervisorError {
            XCTAssertEqual(error, .interrupted(.crashed, deliveredOutput: true))
        }
        XCTAssertEqual(connector.connectCount, 1)
    }

    func testConsecutiveCrashesEnterSafeModeUntilItIsLeft() async throws {
        let connector = FakeConnector()
        connector.failConnect = true
        // No re-issue, so every job is exactly one crash and the threshold is pinned.
        var single = policy
        single.maxReissues = 0
        let supervisor = make(connector, policy: single)
        for crashes in 1...3 {
            do { _ = try await supervisor.generate(job()) } catch {}
            let state = await supervisor.state
            XCTAssertEqual(state, crashes < 3 ? .idle : .safeMode, "after \(crashes) consecutive crashes")
        }
        connector.failConnect = false
        connector.configure = answering()
        do {
            _ = try await supervisor.generate(job())
            XCTFail("safe mode must not start the worker")
        } catch let error as WorkerSupervisorError {
            XCTAssertEqual(error, .safeMode)
        }
        XCTAssertEqual(connector.connectCount, 0)
        await supervisor.leaveSafeMode()
        let result = try await supervisor.generate(job())
        XCTAssertEqual(result.text, "Hello")
        let state = await supervisor.state
        XCTAssertEqual(state, .ready)
    }

    func testACrashWhileIdleRetiresTheWorkerAndTheNextJobReconnects() async throws {
        let connector = FakeConnector()
        connector.configure = answering()
        let supervisor = make(connector)
        _ = try await supervisor.generate(job())
        connector.links[0].crash()
        try await eventually("crash noticed") { await supervisor.state == .idle }
        XCTAssertEqual(connector.links[0].invalidations, [true])
        let result = try await supervisor.generate(job())
        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(connector.connectCount, 2)
        XCTAssertFalse(connector.connectedWhileOldAlive)
    }

    func testACrashWhileIdleCountsTowardSafeMode() async throws {
        let connector = FakeConnector()
        connector.configure = answering()
        var strict = policy
        strict.maxConsecutiveCrashes = 1
        let supervisor = make(connector, policy: strict)
        _ = try await supervisor.generate(job())
        connector.links[0].crash()
        try await eventually("safe mode after the idle crash") { await supervisor.state == .safeMode }
    }

    func testASuccessfulJobResetsTheCrashCounter() async throws {
        let connector = FakeConnector()
        let attempt = LockedBox(0)
        connector.configure = { link in
            // Links 1 and 3 die on connect-time load; 2 and 4 are healthy.
            let n = attempt.mutate { $0 += 1; return $0 }
            if n % 2 == 1 {
                link.onRequest = { envelope, link in
                    if case .load = envelope.request { link.crash(); throw CocoaError(.xpcConnectionInterrupted) }
                    return nil
                }
            } else {
                answering()(link)
            }
        }
        var quick = policy
        quick.restartDelay = .zero
        quick.maxConsecutiveCrashes = 2
        let supervisor = make(connector, policy: quick)
        for _ in 0..<2 {
            let result = try await supervisor.generate(job())
            XCTAssertEqual(result.text, "Hello")
            await supervisor.unloadNow()
        }
        let state = await supervisor.state
        XCTAssertNotEqual(state, .safeMode)
    }

    func testCancellingDuringTheRestartDelayDoesNotLeaveTheStateRestarting() async throws {
        let connector = FakeConnector()
        connector.configure = crashingOnFirstGenerate()
        let clock = SupervisorFakeClock()
        let supervisor = make(connector, clock: clock)
        let task = Task { try await supervisor.generate(job()) }
        try await eventually("restart delay armed") { clock.hasSleeper(remaining: .seconds(1)) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        let state = await supervisor.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(connector.connectCount, 1, "a cancelled job is not re-issued")
    }

    func testACancelledJobWhoseWorkerDiesDoesNotLeaveTheStateRestarting() async throws {
        let connector = FakeConnector()
        connector.configure = { link in
            link.onRequest = { envelope, link in
                switch envelope.request {
                case .generate:
                    return accepted(envelope)
                case .cancel:
                    link.crash()
                    throw CocoaError(.xpcConnectionInterrupted)
                default:
                    return nil
                }
            }
        }
        // Without a delay nothing sleeps between "restarting" and noticing the cancellation.
        var quick = policy
        quick.restartDelay = .zero
        let supervisor = make(connector, policy: quick)
        let task = Task { try await supervisor.generate(job()) }
        try await eventually("generating") { connector.links.first?.generateCount == 1 }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        let state = await supervisor.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(connector.connectCount, 1, "a cancelled job is not re-issued")
    }

    // MARK: Hangs and timeouts

    func testAHungWorkerIsFoundByThePingAndKilled() async throws {
        let connector = FakeConnector()
        let hang = LockedBox(false)
        connector.configure = { link in
            answering()(link)
            before(link) { envelope, link in
                if hang.value, case .hello = envelope.request { try await link.hang() }
            }
        }
        let clock = SupervisorFakeClock()
        let supervisor = make(connector, clock: clock)
        _ = try await supervisor.generate(job())
        hang.mutate { $0 = true }
        try await eventually("health loop armed") { clock.hasSleeper(remaining: .seconds(5)) }
        clock.advance(by: .seconds(5))
        try await eventually("ping timeout armed") { clock.hasSleeper(remaining: .seconds(10)) }
        clock.advance(by: .seconds(10))
        try await eventually("hung worker killed") { connector.links[0].invalidations == [true] }
        let state = await supervisor.state
        XCTAssertEqual(state, .idle)
    }

    func testAWorkerThatHangsDuringAGenerationFailsTheJobAndIsKilled() async throws {
        let connector = FakeConnector()
        let hung = LockedBox(false)
        connector.configure = { link in
            link.onRequest = { envelope, link in
                switch envelope.request {
                case .generate:
                    hung.mutate { $0 = true }
                    return accepted(envelope)
                case .hello:
                    if hung.value { try await link.hang() }
                    return nil
                default:
                    return nil
                }
            }
        }
        var noRetry = policy
        noRetry.maxReissues = 0
        let clock = SupervisorFakeClock()
        let supervisor = make(connector, clock: clock, policy: noRetry)
        let task = Task { try await supervisor.generate(job()) }
        try await eventually("generating") { connector.links.first?.generateCount == 1 }
        try await eventually("health loop armed") { clock.hasSleeper(remaining: .seconds(5)) }
        clock.advance(by: .seconds(5))
        try await eventually("ping timeout armed") { clock.hasSleeper(remaining: .seconds(10)) }
        clock.advance(by: .seconds(10))
        await assertFails(task, with: .interrupted(.unresponsive, deliveredOutput: false))
        XCTAssertEqual(connector.links[0].invalidations, [true])
        let state = await supervisor.state
        XCTAssertEqual(state, .idle)
    }

    func testLoadHasItsOwnLongTimeout() async throws {
        let connector = FakeConnector()
        connector.configure = { link in
            before(link) { envelope, link in
                if case .load = envelope.request { try await link.hang() }
            }
        }
        let clock = SupervisorFakeClock()
        let supervisor = make(connector, clock: clock)
        let task = Task { try await supervisor.generate(job()) }
        try await eventually("load timeout armed") { clock.hasSleeper(remaining: .seconds(180)) }
        clock.advance(by: .seconds(179))
        try await eventually("1 s left") { clock.hasSleeper(remaining: .seconds(1)) }
        let state = await supervisor.state
        XCTAssertEqual(state, .starting)
        XCTAssertEqual(connector.links[0].invalidations, [])
        clock.advance(by: .seconds(1))
        await assertFails(task, with: .loadTimedOut)
        XCTAssertEqual(connector.links[0].invalidations, [true])
    }

    func testSwitchingModelsOnALiveLinkIsNotPingedWhileLoading() async throws {
        let connector = FakeConnector()
        let release = Latch()
        connector.configure = { link in
            answering()(link)
            before(link) { envelope, _ in
                if case .load(.path("/models/b")) = envelope.request { await release.wait() }
            }
        }
        let clock = SupervisorFakeClock()
        let supervisor = make(connector, clock: clock)
        _ = try await supervisor.generate(job())
        let switching = Task { try await supervisor.generate(job(model: "/models/b")) }
        try await eventually("second model loading") { clock.hasSleeper(remaining: .seconds(180)) }
        var state = await supervisor.state
        XCTAssertEqual(state, .starting)
        // Four ping intervals, twice the ping timeout: a ping would have been sent and would
        // have timed out by now if the health loop did not stand down while a model loads.
        for _ in 0..<4 {
            clock.advance(by: .seconds(5))
            try await eventually("health loop re-armed") { clock.hasSleeper(remaining: .seconds(5)) }
        }
        XCTAssertEqual(connector.links[0].helloCount, 1, "no ping while the model loads")
        XCTAssertEqual(connector.links[0].invalidations, [])
        state = await supervisor.state
        XCTAssertEqual(state, .starting)
        release.open()
        let result = try await switching.value
        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(connector.connectCount, 1)
        state = await supervisor.state
        XCTAssertEqual(state, .ready)
    }

    func testAPingInFlightWhenAModelSwitchStartsDoesNotKillTheLoadingWorker() async throws {
        let connector = FakeConnector()
        let hang = LockedBox(false)
        let release = Latch()
        connector.configure = { link in
            answering()(link)
            before(link) { envelope, link in
                if hang.value, case .hello = envelope.request { try await link.hang() }
                if case .load(.path("/models/b")) = envelope.request { await release.wait() }
            }
        }
        let clock = SupervisorFakeClock()
        let supervisor = make(connector, clock: clock)
        _ = try await supervisor.generate(job())
        hang.mutate { $0 = true }
        try await eventually("health loop armed") { clock.hasSleeper(remaining: .seconds(5)) }
        clock.advance(by: .seconds(5))
        try await eventually("ping in flight") { clock.hasSleeper(remaining: .seconds(10)) }
        let switching = Task { try await supervisor.generate(job(model: "/models/b")) }
        try await eventually("second model loading") { clock.hasSleeper(remaining: .seconds(180)) }
        clock.advance(by: .seconds(10))
        // The ping gave up; the health loop going back to sleep is the sync point.
        try await eventually("health loop re-armed") { clock.hasSleeper(remaining: .seconds(5)) }
        XCTAssertEqual(connector.links[0].invalidations, [], "the load threshold applies, not the ping's")
        let state = await supervisor.state
        XCTAssertEqual(state, .starting)
        hang.mutate { $0 = false }
        release.open()
        let result = try await switching.value
        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(connector.connectCount, 1)
    }

    func testAHelloThatIsNeverAnsweredIsBoundedAndReleasesTheGate() async throws {
        let connector = FakeConnector()
        let attempts = LockedBox(0)
        connector.configure = { link in
            if attempts.mutate({ $0 += 1; return $0 }) == 1 {
                link.onRequest = { envelope, link in
                    if case .hello = envelope.request { try await link.hang() }
                    return nil
                }
            } else {
                answering()(link)
            }
        }
        var noRetry = policy
        noRetry.maxReissues = 0
        let clock = SupervisorFakeClock()
        let supervisor = make(connector, clock: clock, policy: noRetry)
        let stuck = Task { try await supervisor.generate(job("a")) }
        try await eventually("handshake timeout armed") { clock.hasSleeper(remaining: .seconds(30)) }
        let next = Task { try await supervisor.generate(job("b")) }
        try await eventually("next job queued behind the gate") { await supervisor.queuedCallers == 1 }
        clock.advance(by: .seconds(30))
        await assertFails(stuck, with: .interrupted(.unresponsive, deliveredOutput: false))
        XCTAssertEqual(connector.links[0].invalidations, [true])
        let result = try await next.value
        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(connector.connectCount, 2)
        XCTAssertFalse(connector.connectedWhileOldAlive)
    }

    func testAWorkerThatRefusesTheHandshakeIsRetiredWithoutACrashOrARetry() async throws {
        let connector = FakeConnector()
        let refusal = WorkerFailure(kind: .unsupportedProtocol, message: "Unsupported worker protocol 1.")
        connector.configure = { link in
            link.onRequest = { envelope, _ in
                guard case .hello = envelope.request else { return nil }
                return WorkerReplyEnvelope(requestID: envelope.requestID, reply: .failure(refusal))
            }
        }
        var strict = policy
        strict.maxConsecutiveCrashes = 1
        let supervisor = make(connector, policy: strict)
        let task = Task { try await supervisor.generate(job()) }
        await assertFails(task, with: .worker(refusal))
        XCTAssertEqual(connector.connectCount, 1, "a version mismatch is not re-issued")
        XCTAssertEqual(connector.links[0].count { $0.isLoad }, 0, "nothing is loaded into a mismatched worker")
        XCTAssertEqual(connector.links[0].invalidations, [true])
        let state = await supervisor.state
        XCTAssertEqual(state, .idle, "one crash would already mean safe mode here")
    }

    func testAWorkerThatAnswersTheHandshakeWithAnotherVersionIsRetired() async throws {
        let connector = FakeConnector()
        connector.configure = { link in
            link.onRequest = { envelope, _ in
                guard case .hello(let version) = envelope.request else { return nil }
                return WorkerReplyEnvelope(requestID: envelope.requestID, reply: .hello(version: version + 1))
            }
        }
        var strict = policy
        strict.maxConsecutiveCrashes = 1
        let supervisor = make(connector, policy: strict)
        let task = Task { try await supervisor.generate(job()) }
        await assertFails(task, with: .worker(WorkerFailure(
            kind: .unsupportedProtocol, message: "The worker does not speak this protocol."
        )))
        XCTAssertEqual(connector.connectCount, 1, "a version mismatch is not re-issued")
        XCTAssertEqual(connector.links[0].count { $0.isLoad }, 0, "nothing is loaded into a mismatched worker")
        XCTAssertEqual(connector.links[0].invalidations, [true])
        let state = await supervisor.state
        XCTAssertEqual(state, .idle, "one crash would already mean safe mode here")
    }

    func testLoadAnsweredWithAFailureIsNotACrash() async throws {
        let connector = FakeConnector()
        let failure = WorkerFailure(kind: .modelLoadFailed, message: "No such model.")
        connector.configure = { link in
            link.onRequest = { envelope, _ in
                guard case .load = envelope.request else { return nil }
                return WorkerReplyEnvelope(requestID: envelope.requestID, reply: .failure(failure))
            }
        }
        var strict = policy
        strict.maxConsecutiveCrashes = 1
        let supervisor = make(connector, policy: strict)
        let task = Task { try await supervisor.generate(job()) }
        await assertFails(task, with: .worker(failure))
        let state = await supervisor.state
        XCTAssertEqual(state, .idle, "one crash would already mean safe mode here")
        XCTAssertEqual(connector.connectCount, 1, "a refused load is not re-issued")
        XCTAssertEqual(connector.links[0].invalidations, [true])
    }

    func testAWorkerThatRefusedTheLoadIsRetiredSoItsExitIsNeverACrash() async throws {
        let connector = FakeConnector()
        let attempts = LockedBox(0)
        connector.configure = { link in
            if attempts.mutate({ $0 += 1; return $0 }) == 1 {
                link.onRequest = { envelope, _ in
                    guard case .load = envelope.request else { return nil }
                    return WorkerReplyEnvelope(requestID: envelope.requestID, reply: .failure(
                        WorkerFailure(kind: .modelLoadFailed, message: "No such model.")
                    ))
                }
            } else {
                answering()(link)
            }
        }
        var strict = policy
        strict.maxConsecutiveCrashes = 1
        let clock = SupervisorFakeClock()
        let supervisor = make(connector, clock: clock, policy: strict)
        do { _ = try await supervisor.generate(job()) } catch {}
        XCTAssertEqual(connector.links[0].invalidations, [true], "a worker without a model is not kept connected")
        XCTAssertFalse(clock.hasSleeper(remaining: .seconds(600)), "nothing is left to unload")
        // The model-less process going away (launchd reaps idle services) must not count.
        connector.links[0].crash()
        let result = try await supervisor.generate(job())
        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(connector.connectCount, 2)
        XCTAssertFalse(connector.connectedWhileOldAlive)
        let state = await supervisor.state
        XCTAssertEqual(state, .ready, "one crash would already mean safe mode here")
    }

    // MARK: Memory pressure

    func testMemoryPressureUnloadsAnIdleModelImmediately() async throws {
        let connector = FakeConnector()
        connector.configure = answering()
        let supervisor = make(connector)
        _ = try await supervisor.generate(job())
        await supervisor.handleMemoryPressure(.warning)
        XCTAssertTrue(connector.links[0].sawUnload)
        XCTAssertEqual(connector.links[0].invalidations, [true])
        let state = await supervisor.state
        XCTAssertEqual(state, .idle)
    }

    func testCriticalMemoryPressureUnloadsAnIdleModelWithoutACrash() async throws {
        let connector = FakeConnector()
        connector.configure = answering()
        var strict = policy
        strict.maxConsecutiveCrashes = 1
        let supervisor = make(connector, policy: strict)
        _ = try await supervisor.generate(job())
        await supervisor.handleMemoryPressure(.critical)
        XCTAssertTrue(connector.links[0].sawUnload)
        XCTAssertEqual(connector.links[0].invalidations, [true])
        var state = await supervisor.state
        XCTAssertEqual(state, .idle, "memory pressure is not a crash")
        // Only jobs queued when the pressure arrived are failed; a later one runs.
        let result = try await supervisor.generate(job())
        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(connector.connectCount, 2)
        XCTAssertFalse(connector.connectedWhileOldAlive)
        state = await supervisor.state
        XCTAssertEqual(state, .ready)
    }

    func testCriticalMemoryPressureStopsARunningJobAndKillsTheWorker() async throws {
        let connector = FakeConnector()
        connector.configure = { link in
            link.onRequest = { envelope, _ in
                if case .generate = envelope.request { return accepted(envelope) }
                return nil
            }
        }
        var strict = policy
        strict.maxConsecutiveCrashes = 1
        let supervisor = make(connector, policy: strict)
        let task = Task { try await supervisor.generate(job()) }
        try await eventually("generating") { connector.links.first?.generateCount == 1 }
        await supervisor.handleMemoryPressure(.critical)
        await assertFails(task, with: .memoryPressure)
        XCTAssertEqual(connector.links[0].invalidations, [true])
        XCTAssertEqual(connector.connectCount, 1)
        let state = await supervisor.state
        XCTAssertEqual(state, .idle, "memory pressure is not a crash")
    }

    func testCriticalMemoryPressureWhileLoadingFailsTheJobWithoutRestarting() async throws {
        let connector = FakeConnector()
        connector.configure = { link in
            before(link) { envelope, link in
                if case .load = envelope.request { try await link.hang() }
            }
        }
        var strict = policy
        strict.maxConsecutiveCrashes = 1
        let supervisor = make(connector, policy: strict)
        let task = Task { try await supervisor.generate(job()) }
        try await eventually("loading") { connector.links.first?.count { $0.isLoad } == 1 }
        await supervisor.handleMemoryPressure(.critical)
        await assertFails(task, with: .memoryPressure)
        XCTAssertEqual(connector.connectCount, 1, "no new worker may load a model under critical pressure")
        XCTAssertEqual(connector.links[0].invalidations, [true])
        let state = await supervisor.state
        XCTAssertEqual(state, .idle, "memory pressure is not a crash")
    }

    func testCriticalMemoryPressureBetweenOpenSessionAndTheGenerateReply() async throws {
        let connector = FakeConnector()
        connector.configure = { link in
            before(link) { envelope, link in
                if case .generate = envelope.request { try await link.hang() }
            }
        }
        var strict = policy
        strict.maxConsecutiveCrashes = 1
        let supervisor = make(connector, policy: strict)
        let task = Task { try await supervisor.generate(job()) }
        try await eventually("generate sent") { connector.links.first?.generateCount == 1 }
        await supervisor.handleMemoryPressure(.critical)
        await assertFails(task, with: .memoryPressure)
        XCTAssertEqual(connector.connectCount, 1)
        XCTAssertEqual(connector.links[0].invalidations, [true])
        let state = await supervisor.state
        XCTAssertEqual(state, .idle)
    }

    func testCriticalMemoryPressureWhileConnectingNeverStartsTheWorker() async throws {
        let connector = FakeConnector()
        let gate = Latch()
        connector.connectGate = gate
        connector.configure = answering()
        var strict = policy
        strict.maxConsecutiveCrashes = 1
        let supervisor = make(connector, policy: strict)
        let task = Task { try await supervisor.generate(job()) }
        try await eventually("connecting") { connector.connectAttempts == 1 }
        await supervisor.handleMemoryPressure(.critical)
        gate.open()
        await assertFails(task, with: .memoryPressure)
        XCTAssertEqual(connector.connectCount, 1)
        XCTAssertEqual(connector.links[0].invalidations, [true])
        XCTAssertEqual(connector.links[0].helloCount, 0, "the retired connection is not used")
        let state = await supervisor.state
        XCTAssertEqual(state, .idle)
    }

    func testCriticalMemoryPressureAlsoFailsAQueuedJobInsteadOfReloading() async throws {
        let connector = FakeConnector()
        let attempts = LockedBox(0)
        connector.configure = { link in
            if attempts.mutate({ $0 += 1; return $0 }) == 1 {
                link.onRequest = { envelope, _ in
                    if case .generate = envelope.request { return accepted(envelope) }
                    return nil
                }
            } else {
                answering()(link)
            }
        }
        let supervisor = make(connector)
        let running = Task { try await supervisor.generate(job("a")) }
        try await eventually("generating") { connector.links.first?.generateCount == 1 }
        let queued = Task { try await supervisor.generate(job("b")) }
        try await eventually("second job queued") { await supervisor.queuedCallers == 1 }
        await supervisor.handleMemoryPressure(.critical)
        await assertFails(running, with: .memoryPressure)
        await assertFails(queued, with: .memoryPressure)
        XCTAssertEqual(connector.connectCount, 1, "the queued job must not load a model under critical pressure")
        // The pressure event is over: a job that arrives later runs normally.
        let result = try await supervisor.generate(job("c"))
        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(connector.connectCount, 2)
    }

    func testWarningWhileBusyUnloadsAfterTheJob() async throws {
        let connector = FakeConnector()
        let finish = LockedBox<(@Sendable () -> Void)?>(nil)
        connector.configure = { link in
            link.onRequest = { envelope, link in
                guard case .generate = envelope.request else { return nil }
                let id = envelope.requestID
                finish.mutate { $0 = { Task { await link.emit([.finished(requestID: id, transcript: Data(), usedTokens: 0)]) } } }
                return accepted(envelope)
            }
        }
        let supervisor = make(connector)
        let task = Task { try await supervisor.generate(job()) }
        try await eventually("generating") { finish.value != nil }
        await supervisor.handleMemoryPressure(.warning)
        XCTAssertFalse(connector.links[0].sawUnload, "never unload under a running job")
        finish.value?()
        _ = try await task.value
        XCTAssertTrue(connector.links[0].sawUnload)
    }

    func testUnloadNowWhileBusyUnloadsAfterTheJob() async throws {
        let connector = FakeConnector()
        let finish = LockedBox<(@Sendable () -> Void)?>(nil)
        connector.configure = { link in
            link.onRequest = { envelope, link in
                guard case .generate = envelope.request else { return nil }
                let id = envelope.requestID
                finish.mutate { $0 = { Task { await link.emit([.finished(requestID: id, transcript: Data(), usedTokens: 0)]) } } }
                return accepted(envelope)
            }
        }
        let supervisor = make(connector)
        let task = Task { try await supervisor.generate(job()) }
        try await eventually("generating") { finish.value != nil }
        await supervisor.unloadNow()
        XCTAssertFalse(connector.links[0].sawUnload, "never unload under a running job")
        finish.value?()
        _ = try await task.value
        XCTAssertTrue(connector.links[0].sawUnload)
        XCTAssertEqual(connector.links[0].invalidations, [true])
        let state = await supervisor.state
        XCTAssertEqual(state, .idle)
    }

    // MARK: Unload and reconnect

    func testAJobRightAfterAnUnloadGetsAFreshWorkerAndNoCrash() async throws {
        let connector = FakeConnector()
        connector.configure = answering()
        var strict = policy
        strict.maxConsecutiveCrashes = 1
        let supervisor = make(connector, policy: strict)
        _ = try await supervisor.generate(job())
        await supervisor.unloadNow()
        let result = try await supervisor.generate(job())
        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(connector.connectCount, 2)
        XCTAssertEqual(connector.links[0].invalidations, [true], "the retired worker is gone, not left to exit by itself")
        XCTAssertFalse(connector.connectedWhileOldAlive)
        let state = await supervisor.state
        XCTAssertEqual(state, .ready, "one crash would already mean safe mode here")
    }

    /// The unload request is held open so the supervisor stays inside the unload while a job arrives.
    private func assertJobWaitsForAnUnloadInFlight(
        _ startUnload: (WorkerSupervisor, SupervisorFakeClock) async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let connector = FakeConnector()
        let unloadReply = Latch()
        connector.configure = { link in
            answering()(link)
            before(link) { envelope, _ in
                if case .unload = envelope.request { await unloadReply.wait() }
            }
        }
        var strict = policy
        strict.maxConsecutiveCrashes = 1
        let clock = SupervisorFakeClock()
        let supervisor = make(connector, clock: clock, policy: strict)
        _ = try await supervisor.generate(job())
        try await startUnload(supervisor, clock)
        try await eventually("unload in flight") { connector.links[0].sawUnload }
        let arriving = Task { try await supervisor.generate(job("during unload")) }
        try await eventually("job waits for the unload") { await supervisor.queuedCallers == 1 }
        XCTAssertEqual(connector.connectCount, 1, "no connection while the old worker is being retired", file: file, line: line)
        unloadReply.open()
        let result = try await arriving.value
        XCTAssertEqual(result.text, "Hello", file: file, line: line)
        XCTAssertEqual(connector.connectCount, 2, file: file, line: line)
        XCTAssertEqual(connector.links[0].invalidations, [true], file: file, line: line)
        XCTAssertFalse(connector.connectedWhileOldAlive, file: file, line: line)
        let state = await supervisor.state
        XCTAssertEqual(state, .ready, "one crash would already mean safe mode here", file: file, line: line)
    }

    func testAJobArrivingDuringAnExplicitUnloadWaitsForIt() async throws {
        try await assertJobWaitsForAnUnloadInFlight { supervisor, _ in
            Task { await supervisor.unloadNow() }
        }
    }

    func testAJobArrivingDuringAnIdleUnloadWaitsForIt() async throws {
        try await assertJobWaitsForAnUnloadInFlight { _, clock in
            try await self.eventually("idle countdown armed") { clock.hasSleeper(remaining: .seconds(600)) }
            clock.advance(by: .seconds(600))
        }
    }

    func testAJobArrivingDuringAMemoryPressureUnloadWaitsForIt() async throws {
        try await assertJobWaitsForAnUnloadInFlight { supervisor, _ in
            Task { await supervisor.handleMemoryPressure(.warning) }
        }
    }

    // MARK: Cancellation

    func testCancellingTheTaskCancelsTheWorkerRequest() async throws {
        let connector = FakeConnector()
        connector.configure = { link in
            link.onRequest = { envelope, link in
                switch envelope.request {
                case .generate:
                    return accepted(envelope)
                case .cancel(let target):
                    Task {
                        await link.emit([.failed(
                            requestID: target, WorkerFailure(kind: .cancelled, message: "Cancelled.")
                        )])
                    }
                    return nil
                default: return nil
                }
            }
        }
        var strict = policy
        strict.maxConsecutiveCrashes = 1
        let supervisor = make(connector, policy: strict)
        let task = Task { try await supervisor.generate(job()) }
        try await eventually("generating") { connector.links.first?.generateCount == 1 }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        let link = connector.links[0]
        XCTAssertEqual(link.count { $0.isCancel }, 1)
        let opened = link.requests.compactMap(\.openedSession)
        XCTAssertEqual(link.requests.compactMap(\.closedSession), opened, "the session is closed")
        XCTAssertEqual(connector.connectCount, 1)
        XCTAssertEqual(link.invalidations, [])
        let state = await supervisor.state
        XCTAssertEqual(state, .ready, "cancelling is not a crash")
    }

    func testCancellingDuringTheLoadSendsNothingFurther() async throws {
        let connector = FakeConnector()
        let loadReply = Latch()
        connector.configure = { link in
            answering()(link)
            before(link) { envelope, _ in
                if case .load = envelope.request { await loadReply.wait() }
            }
        }
        var strict = policy
        strict.maxConsecutiveCrashes = 1
        let supervisor = make(connector, policy: strict)
        let task = Task { try await supervisor.generate(job()) }
        try await eventually("loading") { connector.links.first?.count { $0.isLoad } == 1 }
        task.cancel()
        loadReply.open()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        let link = connector.links[0]
        XCTAssertEqual(link.generateCount, 0)
        XCTAssertTrue(link.requests.compactMap(\.openedSession).isEmpty, "no session opened for a cancelled job")
        let state = await supervisor.state
        XCTAssertEqual(state, .ready, "the model stays loaded and cancelling is not a crash")
        let result = try await supervisor.generate(job())
        XCTAssertEqual(result.text, "Hello", "the gate was released")
        XCTAssertEqual(connector.connectCount, 1)
    }

    func testCancellingWhileTheSessionOpensClosesItAndNeverGenerates() async throws {
        let connector = FakeConnector()
        let openReply = Latch()
        connector.configure = { link in
            answering()(link)
            before(link) { envelope, _ in
                if envelope.request.openedSession != nil { await openReply.wait() }
            }
        }
        var strict = policy
        strict.maxConsecutiveCrashes = 1
        let supervisor = make(connector, policy: strict)
        let task = Task { try await supervisor.generate(job()) }
        try await eventually("session opening") {
            connector.links.first?.requests.contains { $0.openedSession != nil } == true
        }
        task.cancel()
        openReply.open()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        let link = connector.links[0]
        let opened = link.requests.compactMap(\.openedSession)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(link.requests.compactMap(\.closedSession), opened, "the session is closed")
        XCTAssertEqual(link.generateCount, 0)
        XCTAssertEqual(link.invalidations, [])
        let state = await supervisor.state
        XCTAssertEqual(state, .ready, "the model stays loaded and cancelling is not a crash")
    }

    func testAWorkerThatIgnoresACancelIsKilledAfterTheCancelTimeout() async throws {
        let connector = FakeConnector()
        let attempts = LockedBox(0)
        connector.configure = { link in
            if attempts.mutate({ $0 += 1; return $0 }) == 1 {
                // Alive and polite (it accepts the cancel and answers pings) but the generation never ends.
                link.onRequest = { envelope, _ in
                    if case .generate = envelope.request { return accepted(envelope) }
                    return nil
                }
            } else {
                answering()(link)
            }
        }
        var strict = policy
        strict.maxConsecutiveCrashes = 1
        let clock = SupervisorFakeClock()
        let supervisor = make(connector, clock: clock, policy: strict)
        let stuck = Task { try await supervisor.generate(job("a")) }
        try await eventually("generating") { connector.links.first?.generateCount == 1 }
        let next = Task { try await supervisor.generate(job("b")) }
        try await eventually("next job queued behind the gate") { await supervisor.queuedCallers == 1 }
        stuck.cancel()
        try await eventually("cancel watchdog armed") { clock.hasSleeper(remaining: .seconds(7)) }
        XCTAssertEqual(connector.links[0].count { $0.isCancel }, 1)
        XCTAssertEqual(connector.links[0].invalidations, [], "the worker gets the whole cancel timeout")
        clock.advance(by: .seconds(7))
        do {
            _ = try await stuck.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(connector.links[0].invalidations, [true])
        let result = try await next.value
        XCTAssertEqual(result.text, "Hello", "the gate was released")
        XCTAssertEqual(connector.connectCount, 2)
        XCTAssertFalse(connector.connectedWhileOldAlive)
        let state = await supervisor.state
        XCTAssertEqual(state, .ready, "one crash would already mean safe mode here")
    }

    func testCancellingAQueuedJobLeavesTheQueueAtOnce() async throws {
        let connector = FakeConnector()
        let ids = LockedBox<[UUID]>([])
        connector.configure = { link in
            link.onRequest = { envelope, _ in
                guard case .generate = envelope.request else { return nil }
                ids.mutate { $0.append(envelope.requestID) }
                return accepted(envelope)
            }
        }
        let supervisor = make(connector)
        let first = Task { try await supervisor.generate(job("a")) }
        try await eventually("first job generating") { ids.value.count == 1 }
        let second = Task { try await supervisor.generate(job("b")) }
        try await eventually("second job queued") { await supervisor.queuedCallers == 1 }
        second.cancel()
        do {
            _ = try await second.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        // The first job is still running: the cancelled one did not wait for the gate.
        let queued = await supervisor.queuedCallers
        XCTAssertEqual(queued, 0)
        await connector.links[0].emit([.finished(requestID: ids.value[0], transcript: Data(), usedTokens: 0)])
        _ = try await first.value
        XCTAssertEqual(connector.links[0].generateCount, 1, "the cancelled job never reached the worker")
    }

    // MARK: Worker errors and the wire

    func testAFailedEventIsPassedOnTypedAndIsNotACrash() async throws {
        let connector = FakeConnector()
        let overflow = WorkerFailure(kind: .contextOverflow, message: "The context window is full.")
        connector.configure = { link in
            link.onRequest = { envelope, link in
                guard case .generate = envelope.request else { return nil }
                let id = envelope.requestID
                Task { await link.emit([.failed(requestID: id, overflow)]) }
                return accepted(envelope)
            }
        }
        var strict = policy
        strict.maxConsecutiveCrashes = 1
        let supervisor = make(connector, policy: strict)
        let task = Task { try await supervisor.generate(job()) }
        await assertFails(task, with: .worker(overflow))
        let link = connector.links[0]
        let opened = link.requests.compactMap(\.openedSession)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(link.requests.compactMap(\.closedSession), opened, "the session is closed")
        XCTAssertEqual(link.invalidations, [], "the worker and its model stay")
        XCTAssertEqual(connector.connectCount, 1, "a failed generation is not re-issued")
        let state = await supervisor.state
        XCTAssertEqual(state, .ready, "one crash would already mean safe mode here")
    }

    func testAWorkerThatRejectsGenerateGetsItsSessionClosed() async throws {
        let connector = FakeConnector()
        let failure = WorkerFailure(kind: .busy, message: "Busy.")
        connector.configure = { link in
            link.onRequest = { envelope, _ in
                guard case .generate = envelope.request else { return nil }
                return WorkerReplyEnvelope(requestID: envelope.requestID, reply: .failure(failure))
            }
        }
        let supervisor = make(connector)
        let task = Task { try await supervisor.generate(job()) }
        await assertFails(task, with: .worker(failure))
        let link = connector.links[0]
        let opened = link.requests.compactMap(\.openedSession)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(link.requests.compactMap(\.closedSession), opened)
        let state = await supervisor.state
        XCTAssertEqual(state, .ready)
    }

    func testAGapInEventSequenceRecyclesTheWorker() async throws {
        let connector = FakeConnector()
        connector.configure = { link in
            link.onRequest = { envelope, link in
                guard case .generate = envelope.request else { return nil }
                let id = envelope.requestID
                Task { await link.emit([.delta(requestID: id, text: "x", usedTokens: 1)], sequence: 5) }
                return WorkerReplyEnvelope(requestID: id, reply: .accepted)
            }
        }
        var noRetry = policy
        noRetry.maxReissues = 0
        let supervisor = make(connector, policy: noRetry)
        do {
            _ = try await supervisor.generate(job())
            XCTFail("expected an interruption")
        } catch let error as WorkerSupervisorError {
            XCTAssertEqual(error, .interrupted(.crashed, deliveredOutput: false))
        }
        XCTAssertEqual(connector.links[0].invalidations, [true])
    }

    func testAnUndecodableBatchRecyclesTheWorkerInsteadOfHangingTheJob() async throws {
        let connector = FakeConnector()
        connector.configure = { link in
            link.onRequest = { envelope, link in
                guard case .generate = envelope.request else { return nil }
                Task { await link.emitUndecodableBatch() }
                return accepted(envelope)
            }
        }
        var noRetry = policy
        noRetry.maxReissues = 0
        let supervisor = make(connector, policy: noRetry)
        let task = Task { try await supervisor.generate(job()) }
        await assertFails(task, with: .interrupted(.crashed, deliveredOutput: false))
        XCTAssertEqual(connector.links[0].invalidations, [true])
        let state = await supervisor.state
        XCTAssertEqual(state, .idle)
    }

    func testAJobWhoseBatchWasUndecodableIsReissuedOnAFreshWorker() async throws {
        let connector = FakeConnector()
        let attempts = LockedBox(0)
        connector.configure = { link in
            if attempts.mutate({ $0 += 1; return $0 }) == 1 {
                link.onRequest = { envelope, link in
                    guard case .generate = envelope.request else { return nil }
                    Task { await link.emitUndecodableBatch() }
                    return accepted(envelope)
                }
            } else {
                answering()(link)
            }
        }
        var quick = policy
        quick.restartDelay = .zero
        let supervisor = make(connector, policy: quick)
        let result = try await supervisor.generate(job())
        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(connector.connectCount, 2)
        XCTAssertEqual(connector.links[0].invalidations, [true])
        XCTAssertFalse(connector.connectedWhileOldAlive)
    }

    func testTheEventSinkReportsAnUndecodableBatchAndStillAcks() async throws {
        let recorder = RecordingEvents()
        let adapter = EventSinkAdapter(receiver: recorder)
        await withCheckedContinuation { continuation in
            adapter.deliver(Data("not json".utf8)) { continuation.resume() }
        }
        XCTAssertEqual(recorder.broken, 1)
        XCTAssertTrue(recorder.batches.isEmpty)
        let good = try WorkerWire.encoder.encode(WorkerEventBatch(sequence: 0, events: []))
        await withCheckedContinuation { continuation in
            adapter.deliver(good) { continuation.resume() }
        }
        XCTAssertEqual(recorder.broken, 1)
        XCTAssertEqual(recorder.batches.map(\.sequence), [0])
    }
}

private final class RecordingEvents: WorkerConnectionEvents, @unchecked Sendable {
    private let state = LockedBox((batches: [WorkerEventBatch](), broken: 0))
    var batches: [WorkerEventBatch] { state.value.batches }
    var broken: Int { state.value.broken }

    func deliver(_ batch: WorkerEventBatch) async { state.mutate { $0.batches.append(batch) } }
    func protocolBroken() async { state.mutate { $0.broken += 1 } }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    @discardableResult
    func mutate<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&stored)
    }
}
#endif
