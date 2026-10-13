#if os(macOS)
import Foundation
import XCTest
@testable import LocalLLMChat

// Two suites for the app <-> Gateway protocol v2, both without XPC:
//   GatewayClientTests  the real `GatewayClient` against a loopback Gateway (the real request
//                       handler and engine behind a fake link that can lose a reply or hang)
//   GatewayEventTests   the pushed-event side: wire format, queue, publisher
// Time only moves through `SupervisorFakeClock`. The distinct policy durations below (11 s,
// 13 s, 7 s, ...) let a test tell which timer is waiting by the time it has left.

/// Polls until the condition holds (or fails after ~5 s). Waits on an observable handle; no
/// test here assumes how long anything takes.
private func pollUntil(_ message: String = "", _ condition: () async -> Bool) async throws {
    for _ in 0..<1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    let holds = await condition()
    XCTAssertTrue(holds, message)
}

/// What the fake link throws when its connection is gone.
private struct LinkGone: Error {}

/// A Gateway in the test process: the real request handler behind a link that can lose a reply or
/// hang. `restart()` replaces the handler (new instance, empty ledger) like a relaunched agent.
private final class LoopbackGateway: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private(set) var job: StubJob
    private var handler: GatewayRequestHandler
    private var engine: GatewayEngine
    /// Every request that reached the Gateway on any connection, in order.
    private var _requests: [GatewayRequest] = []
    private var _restarts = 0

    init(directory: URL, job: StubJob = StubJob()) {
        self.directory = directory
        self.job = job
        (engine, handler) = Self.make(directory: directory, job: job)
    }

    private static func make(directory: URL, job: StubJob) -> (GatewayEngine, GatewayRequestHandler) {
        let engine = GatewayEngine(
            store: GatewayStateStore(directory: directory), job: job, clock: FakeClock(testDate(2026, 10, 2, 6))
        )
        return (engine, GatewayRequestHandler(engine: engine))
    }

    var requests: [GatewayRequest] { lock.withLock { _requests } }
    var currentHandler: GatewayRequestHandler { lock.withLock { handler } }
    var currentEngine: GatewayEngine { lock.withLock { engine } }

    func record(_ request: GatewayRequest) { lock.withLock { _requests.append(request) } }

    func restart(job newJob: StubJob = StubJob()) {
        lock.withLock {
            job = newJob
            (engine, handler) = Self.make(directory: directory, job: newJob)
        }
    }
}

/// One fake connection to the `LoopbackGateway`. Has its own handshake state, like a real
/// connection, and can be told to fail one chosen request in a chosen way.
private final class LoopbackLink: GatewayLink, @unchecked Sendable {
    /// `loseUnfinished`: the Gateway accepted the request and is still working on it when the
    /// connection goes.
    /// `loseReply`: the Gateway executes the request, then the connection goes before the reply.
    /// `hang`: the Gateway never answers.
    enum Fault { case none, loseReply, loseUnfinished, hang }

    let gateway: LoopbackGateway
    private let connection = GatewayConnectionContext()
    private let lock = NSLock()
    private var fault: (match: @Sendable (GatewayRequest) -> Bool, kind: Fault, restartGateway: Bool)?
    private var _invalidated = false
    private var _sent: [GatewayRequest] = []
    private var _unfinishedID: UUID?
    /// Calls parked by the `hang` fault; `invalidate()` ends them.
    private var hung: [CheckedContinuation<Void, Error>] = []

    init(gateway: LoopbackGateway) { self.gateway = gateway }

    var isInvalidated: Bool { lock.withLock { _invalidated } }
    var sent: [GatewayRequest] { lock.withLock { _sent } }
    /// The ID of the request that met `loseUnfinished`.
    var unfinishedID: UUID? { lock.withLock { _unfinishedID } }

    /// The next matching request meets `kind` once. `restartGateway` also swaps the Gateway after
    /// it was executed, before the (lost) reply would have arrived.
    func inject(
        _ kind: Fault, restartGateway: Bool = false, when match: @escaping @Sendable (GatewayRequest) -> Bool
    ) {
        lock.withLock { fault = (match, kind, restartGateway) }
    }

    func send(_ request: Data) async throws -> Data {
        if lock.withLock({ _invalidated }) { throw LinkGone() }
        let envelope = try? GatewayWire.decoder.decode(GatewayRequestEnvelope.self, from: request)
        if let decoded = envelope?.request {
            lock.withLock { _sent.append(decoded) }
            gateway.record(decoded)
        }
        let injected = lock.withLock { () -> (Fault, Bool)? in
            guard let pending = fault, let decoded = envelope?.request, pending.match(decoded) else { return nil }
            fault = nil
            return (pending.kind, pending.restartGateway)
        }
        if let (kind, restart) = injected {
            switch kind {
            case .hang:
                // Models a peer that never answers; like an XPC call, it ends only when the
                // connection is invalidated.
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let gone = lock.withLock { () -> Bool in
                        if _invalidated { return true }
                        hung.append(continuation)
                        return false
                    }
                    if gone { continuation.resume(throwing: LinkGone()) }
                }
                throw LinkGone()
            case .loseUnfinished:
                if let id = envelope?.requestID {
                    // The ledger now says "in progress" for this ID, but nothing executes it.
                    _ = await gateway.currentHandler.ledger.begin(id)
                    lock.withLock { _unfinishedID = id }
                }
                throw LinkGone()
            case .loseReply:
                _ = await gateway.currentHandler.handle(request, connection: connection)
                // Let the run finish before the connection "dies", so a re-sent runNow would be
                // accepted and show up as a second job call.
                await gateway.currentEngine.waitUntilIdle()
                if restart { gateway.restart() }
                throw LinkGone()
            case .none: break
            }
        }
        return await gateway.currentHandler.handle(request, connection: connection)
    }

    func invalidate() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            _invalidated = true
            defer { hung = [] }
            return hung
        }
        waiting.forEach { $0.resume(throwing: LinkGone()) }
    }
}

/// Hands out `LoopbackLink`s and keeps what the client passed in, so a test can push events
/// (`receiver`) or simulate an interruption (`terminate`) on a specific connection.
private final class LoopbackConnector: GatewayConnecting, @unchecked Sendable {
    struct Connection {
        var link: LoopbackLink
        var receiver: any GatewayClientEventReceiving
        var terminate: @Sendable () -> Void
    }

    let gateway: LoopbackGateway
    private let lock = NSLock()
    private var _connections: [Connection] = []
    /// Calls to `connect`, including the ones that failed.
    private var _attempts = 0
    private var _unreachable = false
    private var _helloHangs = false

    init(gateway: LoopbackGateway) { self.gateway = gateway }

    var connections: [Connection] { lock.withLock { _connections } }
    var last: Connection { connections[connections.count - 1] }
    var attempts: Int { lock.withLock { _attempts } }

    /// While set, connecting fails the way it does when the Gateway is not installed.
    func setUnreachable(_ value: Bool) { lock.withLock { _unreachable = value } }
    /// While set, a new connection never answers its hello.
    func setHelloHangs(_ value: Bool) { lock.withLock { _helloHangs = value } }

    func connect(
        events: any GatewayClientEventReceiving, onTermination: @escaping @Sendable () -> Void
    ) async throws -> any GatewayLink {
        let (unreachable, helloHangs) = lock.withLock { () -> (Bool, Bool) in
            _attempts += 1
            return (_unreachable, _helloHangs)
        }
        if unreachable { throw LinkGone() }
        let link = LoopbackLink(gateway: gateway)
        if helloHangs {
            link.inject(.hang) { if case .hello = $0 { true } else { false } }
        }
        lock.withLock { _connections.append(Connection(link: link, receiver: events, terminate: onTermination)) }
        return link
    }
}

/// Collects a client's events so a test can wait on and inspect them.
private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [GatewayClientEvent] = []
    private var _finished = false
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<GatewayClientEvent>) {
        task = Task { [weak self] in
            for await event in stream { self?.lock.withLock { self?._events.append(event) } }
            self?.lock.withLock { self?._finished = true }
        }
    }

    deinit { task?.cancel() }

    var events: [GatewayClientEvent] { lock.withLock { _events } }
    /// The stream ended.
    var isFinished: Bool { lock.withLock { _finished } }
    var disconnectReasons: [String] {
        events.compactMap { if case .disconnected(let reason) = $0 { reason } else { nil } }
    }
    var statuses: [GatewayStatus] {
        events.compactMap { if case .status(let status) = $0 { status } else { nil } }
    }
    var disconnects: Int {
        events.filter { if case .disconnected = $0 { true } else { false } }.count
    }
    var connects: Int {
        events.filter { if case .connected = $0 { true } else { false } }.count
    }
}

/// A status that differs only in `timeZoneID`, which the tests use as a visible label.
private func makeStatus(zone: String = "UTC") -> GatewayStatus {
    GatewayStatus(
        config: DigestConfig(), isRunning: false, nextRun: nil, timeZoneID: zone,
        lastRun: nil, attemptsToday: 0, lastSuccessDay: nil, startedAt: Date(timeIntervalSince1970: 0)
    )
}

final class GatewayClientTests: XCTestCase {
    private var directory: URL!
    // Every duration is different on purpose; see the note at the top of the file.
    private let policy = GatewayClientPolicy(
        connectTimeout: .seconds(11), requestTimeout: .seconds(13), pingInterval: .seconds(5),
        pingTimeout: .seconds(7), retryInterval: .seconds(2), recoveryPolls: 2, recoveryPollInterval: .seconds(1)
    )

    override func setUp() { directory = makeTemporaryDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    /// A client wired to a loopback Gateway, plus the handles a test asserts on.
    private struct Rig {
        var client: GatewayClient
        var gateway: LoopbackGateway
        var connector: LoopbackConnector
        var clock: SupervisorFakeClock
        var recorder: EventRecorder
    }

    private func makeRig(job: StubJob = StubJob()) -> Rig {
        let gateway = LoopbackGateway(directory: directory, job: job)
        let connector = LoopbackConnector(gateway: gateway)
        let clock = SupervisorFakeClock()
        let client = GatewayClient(connector: connector, clock: clock, policy: policy)
        return Rig(client: client, gateway: gateway, connector: connector, clock: clock, recorder: EventRecorder(client.events))
    }

    // MARK: Handshake

    /// Two sends racing on a fresh client must share one connection attempt, and hello must be
    /// the first thing on the wire.
    func testTheFirstRequestOnAConnectionIsHelloAndConcurrentSendsShareTheConnection() async throws {
        let rig = makeRig()
        async let first = rig.client.send(.status)
        async let second = rig.client.send(.status)
        _ = try await (first, second)

        XCTAssertEqual(rig.connector.connections.count, 1)
        XCTAssertEqual(rig.connector.last.link.sent.first, .hello(version: GatewayConstants.protocolVersion))
        try await pollUntil("connected event") { rig.recorder.connects == 1 }
    }

    /// New app, old agent (the agent keeps running until "Reinstall"): the user must see
    /// "unsupported protocol", not a decoding error.
    func testAGatewayStillOnProtocolOneSurfacesAsUnsupportedProtocol() async throws {
        struct V1Link: GatewayLink {
            func send(_ request: Data) async throws -> Data {
                // What a protocol 1 Gateway answers to a request it cannot decode.
                Data(#"{"version":1,"reply":{"failure":{"_0":"Could not parse the Gateway request"}}}"#.utf8)
            }
            func invalidate() {}
        }
        struct V1Connector: GatewayConnecting {
            func connect(
                events: any GatewayClientEventReceiving, onTermination: @escaping @Sendable () -> Void
            ) async throws -> any GatewayLink { V1Link() }
        }
        let client = GatewayClient(connector: V1Connector(), clock: SupervisorFakeClock(), policy: policy)
        do {
            _ = try await client.send(.status)
            XCTFail("expected unsupportedProtocol")
        } catch {
            XCTAssertEqual(error as? GatewayError, .unsupportedProtocol(1))
        }
        let connected = await client.isConnected
        XCTAssertFalse(connected)
    }

    // MARK: Unreachable Gateway

    /// The Gateway is not installed or not running: the error is the actionable
    /// `gatewayUnavailable` text, the consumer hears about it once however many reconnect
    /// attempts fail, and the client connects by itself once the Gateway appears.
    func testAGatewayThatCannotBeReachedIsReportedOnceInWordsTheUserCanActOn() async throws {
        let rig = makeRig()
        rig.connector.setUnreachable(true)

        do {
            _ = try await rig.client.send(.status)
            XCTFail("expected gatewayUnavailable")
        } catch {
            guard case .gatewayUnavailable? = error as? GatewayError else { return XCTFail("\(error)") }
        }

        await rig.client.start()
        try await pollUntil("disconnect reported") { rig.recorder.disconnects == 1 }
        XCTAssertTrue(
            rig.recorder.disconnectReasons[0].hasPrefix("The Gateway is not responding."),
            rig.recorder.disconnectReasons[0]
        )
        // Further failed attempts are not reported again.
        for attempt in 2...3 {
            try await pollUntil("retry timer") { rig.clock.hasSleeper(remaining: .seconds(2)) }
            rig.clock.advance(by: .seconds(2))
            try await pollUntil("attempt \(attempt + 1)") { rig.connector.attempts == attempt + 1 }
        }
        XCTAssertEqual(rig.recorder.disconnects, 1)

        rig.connector.setUnreachable(false)
        try await pollUntil("retry timer") { rig.clock.hasSleeper(remaining: .seconds(2)) }
        rig.clock.advance(by: .seconds(2))
        try await pollUntil("connected") { rig.recorder.connects == 1 }
        await rig.client.stop()
    }

    /// A connection that opens but never answers hello must not be waited on forever or left open.
    func testAHandshakeTheGatewayNeverAnswersTimesOutAndClosesThatConnection() async throws {
        let rig = makeRig()
        rig.connector.setHelloHangs(true)

        let outcome = Task<Result<GatewayStatus, Error>, Never> {
            do { return .success(try await rig.client.send(.status)) } catch { return .failure(error) }
        }
        try await pollUntil("handshake timer registered") { rig.clock.hasSleeper(remaining: .seconds(11)) }
        rig.clock.advance(by: .seconds(11))

        guard case .failure(let error) = await outcome.value else { return XCTFail("expected a timeout") }
        guard case .gatewayUnavailable? = error as? GatewayError else { return XCTFail("\(error)") }
        XCTAssertTrue(rig.connector.last.link.isInvalidated)
        let connected = await rig.client.isConnected
        XCTAssertFalse(connected)
    }

    // MARK: Lost replies

    /// The core promise of request IDs: the run happened, its reply was lost, and the client
    /// gets the stored reply by ID instead of starting a second run.
    func testALostReplyToRunNowIsRecoveredByRequestIDAndTheRunIsNotRepeated() async throws {
        let job = StubJob()
        let rig = makeRig(job: job)
        _ = try await rig.client.send(.updateConfig(enabledConfig()))
        rig.connector.last.link.inject(.loseReply) { $0 == .runNow }

        let status = try await rig.client.send(.runNow)

        XCTAssertEqual(rig.connector.connections.count, 2, "reconnected after the loss")
        XCTAssertEqual(job.callCount, 1)
        XCTAssertEqual(rig.gateway.requests.filter { $0 == .runNow }.count, 1, "runNow must never be re-sent")
        XCTAssertEqual(status.lastRun?.trigger, .manual)
        XCTAssertTrue(rig.connector.connections[0].link.isInvalidated)
    }

    /// Same loss, but the Gateway process was replaced: its ledger is gone, so the client must
    /// admit it does not know (`connectionLost`) rather than run the request on the new process.
    func testIfTheGatewayRestartedTheOutcomeIsUnknownAndNothingIsSentAgain() async throws {
        let rig = makeRig()
        _ = try await rig.client.send(.updateConfig(enabledConfig()))
        // The Gateway executes runNow, then dies before the reply; a new process takes over.
        rig.connector.last.link.inject(.loseReply, restartGateway: true) { $0 == .runNow }
        let freshJob = rig.gateway.job

        do {
            _ = try await rig.client.send(.runNow)
            XCTFail("expected connectionLost")
        } catch {
            XCTAssertEqual(error as? GatewayError, .connectionLost)
        }
        let replacementJob = rig.gateway.job
        XCTAssertFalse(replacementJob === freshJob)
        XCTAssertEqual(replacementJob.callCount, 0)
        XCTAssertEqual(rig.gateway.requests.filter { $0 == .runNow }.count, 1)
    }

    /// The Gateway reports the lost request as still in progress: the client waits and asks
    /// again, and returns the reply once the Gateway has one.
    func testARequestTheGatewayIsStillWorkingOnIsAskedAboutAgainUntilItCompletes() async throws {
        let job = StubJob()
        let rig = makeRig(job: job)
        _ = try await rig.client.send(.status)
        let first = rig.connector.last.link
        first.inject(.loseUnfinished) { $0 == .runNow }

        let outcome = Task { try await rig.client.send(.runNow) }
        try await pollUntil("waiting before asking again") { rig.clock.hasSleeper(remaining: .seconds(1)) }
        let id = try XCTUnwrap(first.unfinishedID)
        await rig.gateway.currentHandler.ledger.complete(id, with: .status(makeStatus(zone: "DONE")))
        rig.clock.advance(by: .seconds(1))

        let status = try await outcome.value
        XCTAssertEqual(status.timeZoneID, "DONE", "the stored reply is returned")
        XCTAssertEqual(rig.gateway.requests.filter { $0 == .runNow }.count, 1, "runNow must never be re-sent")
    }

    /// Recovery is bounded: after `recoveryPolls` more questions the client gives up, still
    /// without sending the request a second time.
    func testARequestThatStaysInProgressEndsAsConnectionLostAfterTheLastPoll() async throws {
        let job = StubJob()
        let rig = makeRig(job: job)
        _ = try await rig.client.send(.status)
        rig.connector.last.link.inject(.loseUnfinished) { $0 == .runNow }

        let outcome = Task<Result<GatewayStatus, Error>, Never> {
            do { return .success(try await rig.client.send(.runNow)) } catch { return .failure(error) }
        }
        // `recoveryPolls` is 2: two waits, three questions.
        for _ in 0..<2 {
            try await pollUntil("waiting before asking again") { rig.clock.hasSleeper(remaining: .seconds(1)) }
            rig.clock.advance(by: .seconds(1))
        }

        guard case .failure(let error) = await outcome.value else { return XCTFail("expected connectionLost") }
        XCTAssertEqual(error as? GatewayError, .connectionLost)
        XCTAssertEqual(rig.gateway.requests.filter { $0 == .runNow }.count, 1)
        XCTAssertEqual(rig.gateway.requests.filter { if case .requestStatus = $0 { true } else { false } }.count, 3)
        XCTAssertEqual(job.callCount, 0)
    }

    // MARK: Hung Gateway

    /// A hung Gateway: the request ends at `requestTimeout` and the stuck connection is closed,
    /// so the next request starts on a fresh one.
    func testARequestTheGatewayNeverAnswersTimesOutAndDropsTheConnection() async throws {
        let rig = makeRig()
        _ = try await rig.client.send(.status)
        rig.connector.last.link.inject(.hang) { $0 == .status }

        let outcome = Task<Result<GatewayStatus, Error>, Never> {
            do { return .success(try await rig.client.send(.status)) } catch { return .failure(error) }
        }
        try await pollUntil("request timer registered") { rig.clock.hasSleeper(remaining: .seconds(13)) }
        rig.clock.advance(by: .seconds(13))

        guard case .failure(let error) = await outcome.value else { return XCTFail("expected a timeout") }
        guard case .gatewayUnavailable? = error as? GatewayError else { return XCTFail("\(error)") }
        XCTAssertTrue(rig.connector.last.link.isInvalidated, "the connection the call is stuck on is closed")
        try await pollUntil("disconnect reported") { rig.recorder.disconnects == 1 }
    }

    /// Nobody is sending anything, and the Gateway hangs: only the heartbeat can notice. It
    /// must report the outage and then reconnect on its own.
    func testHeartbeatNoticesAHungGatewayAndReconnects() async throws {
        let rig = makeRig()
        await rig.client.start()
        try await pollUntil("connected") { rig.recorder.connects == 1 }
        try await pollUntil("heartbeat timer") { rig.clock.hasSleeper(remaining: .seconds(5)) }
        rig.connector.last.link.inject(.hang) { $0 == .ping }

        rig.clock.advance(by: .seconds(5))
        try await pollUntil("ping timeout timer") { rig.clock.hasSleeper(remaining: .seconds(7)) }
        rig.clock.advance(by: .seconds(7))

        try await pollUntil("disconnect reported") { rig.recorder.disconnects == 1 }
        XCTAssertTrue(rig.connector.connections[0].link.isInvalidated)
        try await pollUntil("retry timer") { rig.clock.hasSleeper(remaining: .seconds(2)) }
        rig.clock.advance(by: .seconds(2))
        try await pollUntil("reconnected") { rig.connector.connections.count == 2 && rig.recorder.connects == 2 }
        await rig.client.stop()
    }

    // MARK: Stop

    /// After `stop()` nothing may reopen a connection, because nobody would close it again:
    /// requests fail, `start()` does nothing, the event stream ends, no timer is left.
    func testStopIsFinalItClosesTheConnectionEndsTheEventsAndFailsLaterRequests() async throws {
        let rig = makeRig()
        await rig.client.start()
        try await pollUntil("connected") { rig.recorder.connects == 1 }
        let link = rig.connector.last.link

        await rig.client.stop()

        XCTAssertTrue(link.isInvalidated)
        try await pollUntil("events finished") { rig.recorder.isFinished }
        XCTAssertEqual(rig.recorder.disconnects, 0, "stopping is not a failure to report")
        for request in [GatewayRequest.status, .updateConfig(enabledConfig())] {
            do {
                _ = try await rig.client.send(request)
                XCTFail("\(request) was sent after stop")
            } catch {
                guard case .gatewayUnavailable? = error as? GatewayError else { return XCTFail("\(error)") }
            }
        }
        await rig.client.start()
        XCTAssertEqual(rig.connector.attempts, 1, "nothing reopens a connection after stop")
        XCTAssertEqual(rig.clock.sleeperCount, 0, "no heartbeat is left running")
    }

    /// Closing the window while a request is in flight: `stop()` is what ends it (caller
    /// cancellation does not), and it must not trigger a reconnect.
    func testStopEndsARequestThatIsStillWaitingForItsReply() async throws {
        let rig = makeRig()
        _ = try await rig.client.send(.status)
        let link = rig.connector.last.link
        link.inject(.hang) { $0 == .status }

        let outcome = Task<Result<GatewayStatus, Error>, Never> {
            do { return .success(try await rig.client.send(.status)) } catch { return .failure(error) }
        }
        try await pollUntil("request timer registered") { rig.clock.hasSleeper(remaining: .seconds(13)) }
        await rig.client.stop()

        guard case .failure(let error) = await outcome.value else { return XCTFail("expected a failure") }
        guard case .gatewayUnavailable? = error as? GatewayError else { return XCTFail("\(error)") }
        XCTAssertTrue(link.isInvalidated)
        XCTAssertEqual(rig.connector.attempts, 1)
    }

    /// Guards against the retain cycle client -> link -> connection -> relay -> client: a
    /// client that is simply released, without `stop()`, must actually go away.
    func testTheConnectionAndTheHeartbeatDoNotKeepAnUnstoppedClientAlive() async throws {
        let gateway = LoopbackGateway(directory: directory)
        let connector = LoopbackConnector(gateway: gateway)
        let clock = SupervisorFakeClock()
        var client: GatewayClient? = GatewayClient(connector: connector, clock: clock, policy: policy)
        weak let released = client
        await client?.start()
        // Connected, and the loop is asleep until the next ping.
        try await pollUntil("heartbeat timer") { clock.hasSleeper(remaining: .seconds(5)) }
        XCTAssertEqual(connector.connections.count, 1)

        client = nil

        try await pollUntil("client released") { released == nil }
        clock.advance(by: .seconds(5))   // the loop wakes, finds no client and ends
        try await pollUntil("loop ended") { clock.sleeperCount == 0 }
        XCTAssertEqual(connector.last.link.sent.filter { $0 == .ping }.count, 0)
    }

    // MARK: Events

    /// A gap in the batch sequence means a status was lost. The client does not guess: it
    /// drops the connection, and the status after the gap is not shown.
    func testPushedStatusReachesTheConsumerAndALostBatchForcesAReconnect() async throws {
        let rig = makeRig()
        _ = try await rig.client.send(.status)
        let connection = rig.connector.last

        await connection.receiver.deliver(GatewayEventBatch(sequence: 0, events: [.status(makeStatus(zone: "PUSHED"))]))
        try await pollUntil("status event") { rig.recorder.statuses.map(\.timeZoneID) == ["PUSHED"] }

        // Sequence 1 never arrives.
        await connection.receiver.deliver(GatewayEventBatch(sequence: 2, events: [.status(makeStatus(zone: "AFTER-GAP"))]))
        try await pollUntil("disconnect after the gap") { rig.recorder.disconnects == 1 }
        XCTAssertTrue(connection.link.isInvalidated)
        XCTAssertFalse(rig.recorder.statuses.map(\.timeZoneID).contains("AFTER-GAP"))

        _ = try await rig.client.send(.status)
        XCTAssertEqual(rig.connector.connections.count, 2)
    }

    /// A batch the transport could not decode is lost output too, and is handled the same way.
    func testAnUndecodableBatchForcesAReconnect() async throws {
        let rig = makeRig()
        _ = try await rig.client.send(.status)
        await rig.connector.last.receiver.protocolBroken()
        try await pollUntil("disconnect") { rig.recorder.disconnects == 1 }
        XCTAssertTrue(rig.connector.last.link.isInvalidated)
    }

    /// The epoch guard: events and termination callbacks that arrive late from an old
    /// connection must neither be shown nor take down the connection that replaced it.
    func testCallbacksFromAConnectionThatWasReplacedAreIgnored() async throws {
        let rig = makeRig()
        _ = try await rig.client.send(.status)
        let old = rig.connector.last
        old.terminate()
        try await pollUntil("old connection dropped") { rig.recorder.disconnects == 1 }
        _ = try await rig.client.send(.status)
        let current = rig.connector.last
        XCTAssertEqual(rig.connector.connections.count, 2)

        await old.receiver.deliver(GatewayEventBatch(sequence: 0, events: [.status(makeStatus(zone: "STALE"))]))
        await current.receiver.deliver(GatewayEventBatch(sequence: 0, events: [.status(makeStatus(zone: "FRESH"))]))
        try await pollUntil("fresh status") { rig.recorder.statuses.map(\.timeZoneID).contains("FRESH") }
        XCTAssertFalse(rig.recorder.statuses.map(\.timeZoneID).contains("STALE"))
        let connected = await rig.client.isConnected
        XCTAssertTrue(connected, "a late callback of the old connection must not drop the new one")
        old.terminate()   // a late interruption of the connection that is already gone
        _ = try await rig.client.send(.status)
        XCTAssertEqual(rig.connector.connections.count, 2, "no reconnect: the live connection was not dropped")
    }
}

final class GatewayEventTests: XCTestCase {
    private var directory: URL!

    override func setUp() { directory = makeTemporaryDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    /// Old app, newer Gateway: a literal batch with an event type this build has never heard
    /// of. It must be skipped without costing the status that travels next to it.
    func testAnEventTypeFromANewerGatewayDecodesAsUnknownAndItsNeighboursStillApply() throws {
        let status = String(decoding: try GatewayWire.encoder.encode(makeStatus()), as: UTF8.self)
        let literal = """
        {"version":2,"sequence":0,"events":[\
        {"type":"chatDelta","requestID":"x","text":"hi","extra":[1,2]},\
        {"type":"status","status":\(status)}]}
        """
        let batch = try GatewayWire.decoder.decode(GatewayEventBatch.self, from: Data(literal.utf8))
        XCTAssertEqual(batch.events.count, 2)
        XCTAssertEqual(batch.events[0], .unknown(type: "chatDelta"))
        XCTAssertEqual(batch.events[1], .status(makeStatus()))
    }

    /// The memory bound per subscriber: 50 statuses queued while nothing is sent leave one
    /// batch, and a second batch is not handed out before the first is acknowledged.
    func testTheQueueKeepsOnlyTheLatestStatusAndOneBatchInFlight() {
        var queue = GatewayEventQueue()
        for index in 0..<50 { queue.enqueue(status: makeStatus(zone: "Z\(index)")) }
        let first = queue.takeBatch()
        XCTAssertEqual(first?.sequence, 0)
        XCTAssertEqual(first?.events, [.status(makeStatus(zone: "Z49"))])

        queue.enqueue(status: makeStatus(zone: "NEXT"))
        XCTAssertNil(queue.takeBatch(), "no second batch until the first is acknowledged")
        queue.acknowledge()
        let second = queue.takeBatch()
        XCTAssertEqual(second?.sequence, 1)
        XCTAssertEqual(second?.events, [.status(makeStatus(zone: "NEXT"))])
        XCTAssertNil(queue.takeBatch())
    }

    // MARK: Publisher

    /// The app's end of the push channel, with a scripted way of acknowledging.
    private final class FakeSink: GatewayEventSending, @unchecked Sendable {
        /// `hold`: acks only when the test calls `acknowledge()`. `never`: a hung app.
        enum Mode { case ackImmediately, hold, never }

        private let lock = NSLock()
        private var _batches: [GatewayEventBatch] = []
        private var _invalidated = false
        private var held: [CheckedContinuation<Void, Error>] = []
        private var mode: Mode

        init(_ mode: Mode) { self.mode = mode }

        var batches: [GatewayEventBatch] { lock.withLock { _batches } }
        var isInvalidated: Bool { lock.withLock { _invalidated } }

        func deliver(_ batch: GatewayEventBatch) async throws {
            let current = lock.withLock { () -> Mode in
                _batches.append(batch)
                return mode
            }
            switch current {
            case .ackImmediately: return
            case .hold:
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.withLock { held.append(continuation) }
                }
            case .never:
                // A hung app: never acknowledges. Ends when the sink is invalidated.
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.withLock { held.append(continuation) }
                }
            }
        }

        /// Acknowledges the batch the app is holding.
        func acknowledge() {
            let continuation = lock.withLock { held.isEmpty ? nil : held.removeFirst() }
            continuation?.resume()
        }

        func invalidate() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
                _invalidated = true
                defer { held = [] }
                return held
            }
            pending.forEach { $0.resume(throwing: LinkGone()) }
        }
    }

    /// Lets one status read through at a time on request: call number `holding` waits for
    /// `release()`.
    private final class ReadGate: @unchecked Sendable {
        private let lock = NSLock()
        private let holding: Int
        private var calls = 0
        private var held: CheckedContinuation<Void, Never>?

        init(holding: Int) { self.holding = holding }

        var isHolding: Bool { lock.withLock { held != nil } }

        func pass() async {
            let call = lock.withLock { () -> Int in
                calls += 1
                return calls
            }
            guard call == holding else { return }
            await withCheckedContinuation { continuation in lock.withLock { held = continuation } }
        }

        func release() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { held = nil }
                return held
            }
            continuation?.resume()
        }
    }

    /// A publisher wired to a real engine the way `GatewayMain` wires them, with a 9 s ack timeout.
    private func makePublisher(
        clock: SupervisorFakeClock = SupervisorFakeClock(),
        workerStatus: (@Sendable () async -> WorkerStatus?)? = nil
    ) -> (GatewayEventPublisher, GatewayEngine) {
        let relay = GatewayChangeRelay()
        let engine = GatewayEngine(
            store: GatewayStateStore(directory: directory), job: StubJob(),
            clock: FakeClock(testDate(2026, 10, 2, 6)), observer: relay
        )
        let publisher = GatewayEventPublisher(
            source: GatewayStatusSource(engine: engine, workerStatus: workerStatus), clock: clock,
            policy: .init(ackTimeout: .seconds(9))
        )
        relay.attach(publisher)
        return (publisher, engine)
    }

    /// Backpressure end to end: 20 changes while the app sits on its first batch produce
    /// exactly one more batch, carrying the last change.
    func testASlowAppSeesAtMostOneBatchInFlightAndThenOnlyTheLatestStatus() async throws {
        let (publisher, engine) = makePublisher()
        let sink = FakeSink(.hold)
        await publisher.subscribe(UUID(), sink: sink)
        try await pollUntil("first batch delivered") { sink.batches.count == 1 }

        for hour in 0..<20 { try await engine.updateConfig(enabledConfig(hour: hour)) }
        // Either reads the final status itself or makes the publish already running read again.
        await publisher.publishCurrent()
        try await pollUntil("the final status is queued") { await !publisher.isPublishing }
        XCTAssertEqual(sink.batches.count, 1, "nothing further is sent before the ack")

        sink.acknowledge()
        try await pollUntil("second batch delivered") { sink.batches.count == 2 }
        guard case .status(let latest)? = sink.batches[1].events.first else { return XCTFail() }
        XCTAssertEqual(latest.config.hour, 19, "intermediate statuses are coalesced away")
        XCTAssertEqual(sink.batches.map(\.sequence), [0, 1])
        sink.acknowledge()
    }

    /// The single-flight rule. Without it, a publish suspended in its status read could
    /// enqueue its older status after a newer one, and the app would end on stale data.
    func testAPublishAskedForWhileAnotherIsReadingDoesNotLeaveTheOlderStatusLast() async throws {
        // The worker-state read is the second half of a status read: the gate suspends a publish
        // after it has read the engine's status and before it enqueues it.
        let gate = ReadGate(holding: 2)
        let (publisher, engine) = makePublisher(workerStatus: {
            await gate.pass()
            return nil
        })
        let sink = FakeSink(.ackImmediately)
        await publisher.subscribe(UUID(), sink: sink)   // read 1

        try await engine.updateConfig(enabledConfig(hour: 1))   // read 2: holds the hour-1 status
        try await pollUntil("a publish is suspended in its read") { gate.isHolding }
        try await engine.updateConfig(enabledConfig(hour: 2))
        await publisher.publishCurrent()   // must not overtake the suspended publish
        gate.release()

        try await pollUntil("everything delivered") { await publisher.isIdle }
        let statuses = sink.batches.compactMap { batch -> GatewayStatus? in
            if case .status(let status)? = batch.events.first { status } else { nil }
        }
        XCTAssertEqual(statuses.last?.config.hour, 2)
        let revisions = statuses.compactMap(\.revision)
        XCTAssertEqual(revisions, revisions.sorted(), "a status never follows a newer one")
    }

    /// A hung app must not hold a subscription forever: after the ack timeout it is removed
    /// and its connection closed.
    func testAnAppThatNeverAcknowledgesIsDroppedAndItsConnectionClosed() async throws {
        let clock = SupervisorFakeClock()
        let (publisher, _) = makePublisher(clock: clock)
        let sink = FakeSink(.never)
        await publisher.subscribe(UUID(), sink: sink)
        try await pollUntil("ack timer registered") { clock.hasSleeper(remaining: .seconds(9)) }
        let before = await publisher.subscriberCount
        XCTAssertEqual(before, 1)

        clock.advance(by: .seconds(9))

        try await pollUntil("dropped") { await publisher.subscriberCount == 0 }
        XCTAssertTrue(sink.isInvalidated)
    }

    /// A closed connection gets no further pushes.
    func testAnUnsubscribedConnectionReceivesNothingMore() async throws {
        let (publisher, engine) = makePublisher()
        let sink = FakeSink(.ackImmediately)
        let id = UUID()
        await publisher.subscribe(id, sink: sink)
        try await pollUntil("initial status") { sink.batches.count == 1 }

        await publisher.unsubscribe(id)
        try await engine.updateConfig(enabledConfig(hour: 3))
        await publisher.publishCurrent()
        let count = await publisher.subscriberCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(sink.batches.count, 1)
    }
}
#endif
