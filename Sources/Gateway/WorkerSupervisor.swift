#if os(macOS)
import Foundation
import OSLog

// MARK: Seams

/// Time source for the supervisor's timers. Production uses `SuspendingClock`, which does not
/// advance while the Mac sleeps, so a night's sleep never counts as idle time or a missed ping.
protocol SupervisorClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct SystemSupervisorClock: SupervisorClock {
    func sleep(for duration: Duration) async throws {
        try await SuspendingClock().sleep(for: duration)
    }
}

/// One connection to a worker process.
protocol WorkerLink: Sendable {
    /// Throws when the connection is gone; a reply that never comes is the caller's timeout to handle.
    func send(_ request: WorkerRequestEnvelope) async throws -> WorkerReplyEnvelope
    /// Drops the connection. `terminate` also kills the worker process (needed when it is hung
    /// or crashed, because a resident model keeps it alive past the end of the connection).
    /// The supervisor always passes `true`: without a kill the worker only exits when it notices
    /// the invalidation, and a new connection could reach it before that.
    func invalidate(terminate: Bool)
}

/// What a connector reports to the supervisor for one connection.
protocol WorkerConnectionEvents: WorkerEventReceiving {
    /// A batch arrived that could not be decoded, so output was lost. Like a sequence gap, this
    /// cannot be repaired: the supervisor replaces the worker.
    func protocolBroken() async
}

protocol WorkerConnecting: Sendable {
    /// Starts (or finds) the worker. `events` receives streamed output; `onTermination` fires when
    /// the connection is interrupted or invalidated without the supervisor having asked for it.
    func connect(
        events: any WorkerConnectionEvents,
        onTermination: @escaping @Sendable () -> Void
    ) async throws -> any WorkerLink
}

enum MemoryPressureLevel: Sendable { case warning, critical }

// MARK: Types

struct WorkerSupervisorPolicy: Sendable {
    /// Unload the model this long after the last job.
    var idleTimeout: Duration = .seconds(10 * 60)
    /// Loading a model is slow and has its own, long, threshold.
    var loadTimeout: Duration = .seconds(3 * 60)
    var pingInterval: Duration = .seconds(5)
    /// Also bounds a graceful unload request.
    var pingTimeout: Duration = .seconds(10)
    /// After a cancel request the worker gets this long to end the generation. A worker that is
    /// alive (it answers pings) but stuck inside inference is killed when it runs out.
    var cancelTimeout: Duration = .seconds(10)
    /// Bounds the first `hello` on a new connection. Longer than a ping: launchd does not respawn
    /// a service sooner than its 10 s throttle interval after the previous spawn, so a worker
    /// that was just killed (crash, unload) legitimately takes that long to come back.
    var connectTimeout: Duration = .seconds(30)
    /// This many crashes in a row (no successful job in between) stop automatic restarts.
    var maxConsecutiveCrashes = 3
    /// A job interrupted before it produced any output is re-issued this many times.
    var maxReissues = 1
    var restartDelay: Duration = .seconds(1)
}

enum WorkerSupervisorState: Equatable, Sendable {
    /// No worker connection.
    case idle
    /// Connecting and loading a model.
    case starting
    case ready
    /// Waiting to retry after a crash.
    case restarting
    /// Too many consecutive crashes: nothing is started until `leaveSafeMode()`.
    case safeMode
}

enum WorkerSupervisorError: Error, Equatable, Sendable {
    enum Reason: Equatable, Sendable { case crashed, unresponsive }
    case interrupted(Reason, deliveredOutput: Bool)
    case loadTimedOut
    case memoryPressure
    case safeMode
    case worker(WorkerFailure)
}

struct WorkerJob: Sendable {
    var model: WorkerModelLocation
    var instructions: String?
    var transcript: Data?
    var prompt: String
    var options = WorkerGenerationOptions()
}

struct WorkerJobResult: Equatable, Sendable {
    var text: String
    var transcript: Data
    var usedTokens: Int
}

// MARK: Supervisor

/// The Gateway decides, the worker executes: this owns the worker's lifecycle (start, keep warm,
/// unload when idle or under memory pressure, restart after a crash, give up after repeated
/// crashes) and runs one generation at a time through it.
///
/// The gate serialises everything that changes which worker process the supervisor talks to:
/// a job holds it from connecting to its last request, and every unload holds it until the
/// retiring worker has been killed. Two rules make a reconnect safe. First, no job can start
/// connecting while an unload is in flight, because it queues on the gate. Second, an unload
/// always ends by killing the process instead of waiting for it to exit after the connection
/// closes (the worker would still be alive for a moment, and one XPC service instance serves
/// all connections of a client, so a new connection would land on the process being retired and
/// be torn down with it). A killed process cannot answer, so the next connection gets a fresh one.
actor WorkerSupervisor {
    private struct Pending {
        var onDelta: @Sendable (String) -> Void
        var text = ""
        var deliveredOutput = false
        var continuation: CheckedContinuation<WorkerJobResult, Error>?
        var outcome: Result<WorkerJobResult, Error>?
    }

    private enum UnloadReason: String {
        case idle, memoryPressure, requested
    }

    private struct GateWaiter {
        var id: UUID
        /// Resumed with true when the gate is handed over, false when the waiter gave up.
        var continuation: CheckedContinuation<Bool, Never>
    }

    private let connector: any WorkerConnecting
    private let clock: any SupervisorClock
    private let policy: WorkerSupervisorPolicy
    private let log = Logger(subsystem: GatewayConstants.label, category: "supervisor")

    private(set) var state = WorkerSupervisorState.idle
    private var link: (any WorkerLink)?
    /// Bumped for every connection and every deliberate teardown, so callbacks and events from
    /// a connection that is no longer current are ignored.
    private var epoch = 0
    private var loadedModel: WorkerModelLocation?
    private var lastSequence = -1
    private var consecutiveCrashes = 0
    private var pending: [UUID: Pending] = [:]
    /// Held by a running job or an unload; see the type's documentation.
    private var gateHeld = false
    private var jobRunning = false
    private var gateWaiters: [GateWaiter] = []
    /// Set by critical memory pressure for the running job: whatever interrupts it afterwards
    /// is the pressure's doing, so the job fails instead of being re-issued and no crash counts.
    private var pressureAbort = false
    /// Counts critical memory-pressure events, so a job that was queued when one arrived can
    /// tell and does not load a model straight after the unload.
    private var criticalPressureEvents = 0
    private var deferredUnload: UnloadReason?
    /// Runs after a cancel request was sent, until the job ends or `cancelTimeout` elapses.
    private var cancelWatchdog: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?

    init(
        connector: any WorkerConnecting, clock: any SupervisorClock = SystemSupervisorClock(),
        policy: WorkerSupervisorPolicy = WorkerSupervisorPolicy()
    ) {
        self.connector = connector
        self.clock = clock
        self.policy = policy
    }

    // MARK: Public API

    /// Number of callers waiting for the gate (queued jobs and unloads).
    var queuedCallers: Int { gateWaiters.count }

    /// Runs one generation. Output text is also reported through `onDelta` as it streams.
    /// Jobs run one at a time: there is a single resident model.
    ///
    /// The supervisor puts no limit on how long a generation takes: the caller bounds it by
    /// cancelling. Cancellation takes effect at once while the job is queued, and within
    /// `cancelTimeout` while it generates (a worker that has not ended the request by then is
    /// killed). While the worker is connecting or loading a model the job is not interrupted, so
    /// a load is never thrown away: the cancellation is honored when that step ends, which
    /// `connectTimeout` and `loadTimeout` bound.
    func generate(
        _ job: WorkerJob, onDelta: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> WorkerJobResult {
        let pressureSeen = criticalPressureEvents
        guard await acquireGateUnlessCancelled() else { throw CancellationError() }
        // Critical pressure arrived while this job was queued: loading a model now would undo
        // the unload it caused.
        guard pressureSeen == criticalPressureEvents else {
            releaseGate()
            throw WorkerSupervisorError.memoryPressure
        }
        jobRunning = true
        pressureAbort = false
        idleTask?.cancel()
        idleTask = nil
        do {
            let result = try await runWithRetries(job, onDelta: onDelta)
            await afterJob()
            releaseGate()
            return result
        } catch {
            await afterJob()
            releaseGate()
            throw error
        }
    }

    /// Unloads the model and disconnects, as for an idle timeout.
    func unloadNow() async {
        guard !jobRunning else { deferredUnload = .requested; return }
        await acquireGate()
        await unload(.requested)
        releaseGate()
    }

    func handleMemoryPressure(_ level: MemoryPressureLevel) async {
        if level == .critical { criticalPressureEvents += 1 }
        guard jobRunning else {
            await acquireGate()
            await unload(.memoryPressure)
            releaseGate()
            return
        }
        switch level {
        case .warning:
            deferredUnload = .memoryPressure
        case .critical:
            abortJobForMemoryPressure()
        }
    }

    /// The Mac woke up: restart the idle countdown and the health checks from scratch.
    func systemDidWake() {
        if !jobRunning, link != nil { scheduleIdleUnload() }
        if healthTask != nil { startHealthLoop() }
    }

    func leaveSafeMode() {
        consecutiveCrashes = 0
        if state == .safeMode {
            log.info("Leaving safe mode")
            state = .idle
        }
    }

    // MARK: Job execution

    private func runWithRetries(
        _ job: WorkerJob, onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> WorkerJobResult {
        var reissues = 0
        while true {
            try Task.checkCancellation()
            if pressureAbort { throw WorkerSupervisorError.memoryPressure }
            if state == .safeMode { throw WorkerSupervisorError.safeMode }
            do {
                let result = try await attempt(job, onDelta: onDelta)
                consecutiveCrashes = 0
                return result
            } catch {
                if pressureAbort { throw WorkerSupervisorError.memoryPressure }
                guard case WorkerSupervisorError.interrupted(_, let delivered) = error,
                      !delivered, reissues < policy.maxReissues, state != .safeMode else { throw error }
                reissues += 1
                log.info("Re-issuing the job on a fresh worker (attempt \(reissues + 1, privacy: .public))")
                // `afterJob` clears this if the job ends (cancelled, say) before the restart.
                state = .restarting
                if policy.restartDelay > .zero { try await clock.sleep(for: policy.restartDelay) }
            }
        }
    }

    private func attempt(
        _ job: WorkerJob, onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> WorkerJobResult {
        let link = try await ensureReady(job.model)
        // A caller cancelled during the (long) load has nothing open yet: just stop.
        try Task.checkCancellation()
        let connection = epoch
        let sessionID = UUID()
        let requestID = UUID()
        _ = try await call(link, .openSession(
            sessionID: sessionID, instructions: job.instructions, transcript: job.transcript
        ))
        if Task.isCancelled {
            await closeSession(sessionID, connection: connection)
            throw CancellationError()
        }
        pending[requestID] = Pending(onDelta: onDelta)
        do {
            _ = try await call(
                link, .generate(sessionID: sessionID, prompt: job.prompt, options: job.options),
                requestID: requestID
            )
        } catch {
            pending[requestID] = nil
            await closeSession(sessionID, connection: connection)
            throw error
        }
        let result: WorkerJobResult
        do {
            result = try await withTaskCancellationHandler {
                try await awaitOutcome(requestID)
            } onCancel: {
                Task { await self.requestCancel(requestID, connection: connection) }
            }
        } catch {
            stopCancelWatchdog()
            await closeSession(sessionID, connection: connection)
            throw error
        }
        stopCancelWatchdog()
        await closeSession(sessionID, connection: connection)
        return result
    }

    private func awaitOutcome(_ requestID: UUID) async throws -> WorkerJobResult {
        if let outcome = pending[requestID]?.outcome {
            pending[requestID] = nil
            return try outcome.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            if pending[requestID] != nil {
                pending[requestID]?.continuation = continuation
            } else {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// Asks the worker to stop, then gives it `cancelTimeout`. The health ping cannot stand in
    /// for that bound: the worker answers pings while a generation is stuck inside inference.
    private func requestCancel(_ requestID: UUID, connection: Int) async {
        guard connection == epoch, let link, pending[requestID] != nil else { return }
        _ = try? await call(link, .cancel(target: requestID))
        guard connection == epoch, pending[requestID] != nil else { return }
        cancelWatchdog?.cancel()
        cancelWatchdog = Task { [weak self, clock = self.clock, timeout = policy.cancelTimeout] in
            do { try await clock.sleep(for: timeout) } catch { return }
            await self?.cancelTimedOut(requestID, connection: connection)
        }
    }

    /// The worker accepted the cancel but never ended the request. Kills it so the job (and the
    /// gate it holds) is not stuck forever. The caller asked for this, so it is not a crash.
    private func cancelTimedOut(_ requestID: UUID, connection: Int) {
        guard connection == epoch, pending[requestID] != nil, let stuck = link else { return }
        log.error("Worker did not end a cancelled generation; killing it")
        teardown(stuck)
        failAllPending { _ in CancellationError() }
    }

    private func stopCancelWatchdog() {
        cancelWatchdog?.cancel()
        cancelWatchdog = nil
    }

    private func closeSession(_ sessionID: UUID, connection: Int) async {
        guard connection == epoch, let link else { return }
        _ = try? await call(link, .closeSession(sessionID: sessionID))
    }

    // MARK: Connection and model

    private func ensureReady(_ location: WorkerModelLocation) async throws -> any WorkerLink {
        if state == .safeMode { throw WorkerSupervisorError.safeMode }
        if let link, loadedModel == location, state == .ready { return link }
        state = .starting
        let link: any WorkerLink
        if let existing = self.link {
            link = existing
        } else {
            link = try await connect()
        }
        let connection = epoch
        let reply: WorkerReplyEnvelope?
        do {
            reply = try await raceTimeout(clock: clock, timeout: policy.loadTimeout) {
                try await link.send(WorkerRequestEnvelope(requestID: UUID(), request: .load(location)))
            }
        } catch {
            terminate(connection: connection, reason: .crashed)
            throw WorkerSupervisorError.interrupted(.crashed, deliveredOutput: false)
        }
        guard connection == epoch else {
            throw WorkerSupervisorError.interrupted(.crashed, deliveredOutput: false)
        }
        guard let reply else {
            log.error("Model load timed out")
            terminate(connection: connection, reason: .unresponsive)
            throw WorkerSupervisorError.loadTimedOut
        }
        switch reply.reply {
        case .loaded:
            loadedModel = location
            state = .ready
            if healthTask == nil { startHealthLoop() }
            return link
        case .failure(let failure):
            // The worker dropped whatever it had before trying, so it holds no model now. Such a
            // process is idle to launchd, which may kill it at any moment; kept connected, that
            // would look like a crash. Retire it instead: a refused load is not one.
            teardown(link)
            throw WorkerSupervisorError.worker(failure)
        default:
            teardown(link)
            throw WorkerSupervisorError.worker(WorkerFailure(kind: .internalError, message: "Unexpected load reply."))
        }
    }

    private func connect() async throws -> any WorkerLink {
        epoch += 1
        let connection = epoch
        lastSequence = -1
        let relay = EventRelay(supervisor: self, connection: connection)
        let link: any WorkerLink
        do {
            link = try await connector.connect(events: relay) { [weak self] in
                Task { await self?.terminate(connection: connection, reason: .crashed) }
            }
        } catch {
            // Critical memory pressure may have retired this attempt meanwhile; that is no crash.
            if connection == epoch { noteCrash() }
            throw WorkerSupervisorError.interrupted(.crashed, deliveredOutput: false)
        }
        guard connection == epoch else {
            link.invalidate(terminate: true)
            throw WorkerSupervisorError.interrupted(.crashed, deliveredOutput: false)
        }
        self.link = link
        // No health loop exists yet on a first connection, so the handshake needs its own bound.
        let reply: WorkerReplyEnvelope?
        do {
            reply = try await raceTimeout(clock: clock, timeout: policy.connectTimeout) {
                try await link.send(
                    WorkerRequestEnvelope(requestID: UUID(), request: .hello(version: WorkerConstants.protocolVersion))
                )
            }
        } catch {
            terminate(connection: connection, reason: .crashed)
            throw WorkerSupervisorError.interrupted(.crashed, deliveredOutput: false)
        }
        guard connection == epoch else {
            throw WorkerSupervisorError.interrupted(.crashed, deliveredOutput: false)
        }
        guard let reply else {
            terminate(connection: connection, reason: .unresponsive)
            throw WorkerSupervisorError.interrupted(.unresponsive, deliveredOutput: false)
        }
        switch reply.reply {
        case .hello(let version) where version == WorkerConstants.protocolVersion:
            return link
        case .failure(let failure):
            teardown(link)
            throw WorkerSupervisorError.worker(failure)
        default:
            teardown(link)
            throw WorkerSupervisorError.worker(WorkerFailure(
                kind: .unsupportedProtocol, message: "The worker does not speak this protocol."
            ))
        }
    }

    private func call(
        _ link: any WorkerLink, _ request: WorkerRequest, requestID: UUID = UUID()
    ) async throws -> WorkerReply {
        let connection = epoch
        let envelope = WorkerRequestEnvelope(requestID: requestID, request: request)
        let reply: WorkerReplyEnvelope
        do {
            reply = try await link.send(envelope)
        } catch {
            terminate(connection: connection, reason: .crashed)
            throw WorkerSupervisorError.interrupted(.crashed, deliveredOutput: false)
        }
        if case .failure(let failure) = reply.reply { throw WorkerSupervisorError.worker(failure) }
        return reply.reply
    }

    // MARK: Teardown

    /// The worker died, hung or broke the protocol. Counts toward safe mode.
    private func terminate(connection: Int, reason: WorkerSupervisorError.Reason) {
        guard connection == epoch, let dead = link else { return }
        log.error("Worker terminated: \(String(describing: reason), privacy: .public)")
        teardown(dead)
        failAllPending { WorkerSupervisorError.interrupted(reason, deliveredOutput: $0) }
        noteCrash()
    }

    private func noteCrash() {
        consecutiveCrashes += 1
        if consecutiveCrashes >= policy.maxConsecutiveCrashes {
            if state != .safeMode {
                log.error("Entering safe mode after \(self.consecutiveCrashes, privacy: .public) consecutive crashes")
            }
            state = .safeMode
        } else {
            state = .idle
        }
    }

    /// Forgets the current connection without counting a crash, and kills its worker.
    private func teardown(_ dead: any WorkerLink) {
        forgetConnection()
        dead.invalidate(terminate: true)
    }

    private func forgetConnection() {
        epoch += 1
        link = nil
        loadedModel = nil
        healthTask?.cancel()
        healthTask = nil
        if state != .safeMode { state = .idle }
    }

    /// The caller holds the gate. Asks the worker to drop the model, then kills it (see the
    /// type's documentation for why the kill is not optional).
    private func unload(_ reason: UnloadReason) async {
        idleTask?.cancel()
        idleTask = nil
        deferredUnload = nil
        guard let current = link else { return }
        log.info("Unloading model: \(reason.rawValue, privacy: .public)")
        forgetConnection()
        _ = try? await raceTimeout(clock: clock, timeout: policy.pingTimeout) {
            try await current.send(WorkerRequestEnvelope(requestID: UUID(), request: .unload))
        }
        current.invalidate(terminate: true)
    }

    /// Critical pressure: the running job fails with `memoryPressure` whatever phase it is in
    /// (connecting, loading, between requests or generating) and the worker is killed at once
    /// without the graceful unload. Bumping the epoch makes the interrupted calls look stale, so
    /// they are neither counted as a crash nor re-issued.
    private func abortJobForMemoryPressure() {
        log.error("Critical memory pressure: aborting the running job")
        pressureAbort = true
        deferredUnload = nil
        failAllPending { _ in WorkerSupervisorError.memoryPressure }
        let current = link
        forgetConnection()
        current?.invalidate(terminate: true)
    }

    private func failAllPending(_ error: (Bool) -> any Error) {
        for (id, entry) in pending {
            let failure = error(entry.deliveredOutput)
            if let continuation = entry.continuation {
                pending[id] = nil
                continuation.resume(throwing: failure)
            } else {
                pending[id]?.outcome = .failure(failure)
            }
        }
    }

    // MARK: Idle and health

    private func afterJob() async {
        jobRunning = false
        // The job ended while waiting to restart the worker: nothing is restarting any more.
        if state == .restarting { state = .idle }
        if let reason = deferredUnload {
            await unload(reason)
        } else if link != nil {
            scheduleIdleUnload()
        }
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        idleTask = Task { [weak self, clock = self.clock, idle = policy.idleTimeout] in
            do { try await clock.sleep(for: idle) } catch { return }
            await self?.idleExpired()
        }
    }

    private func idleExpired() async {
        // A job or an unload in progress means this countdown is stale.
        guard !gateHeld, !Task.isCancelled else { return }
        await acquireGate()
        await unload(.idle)
        releaseGate()
    }

    private func startHealthLoop() {
        healthTask?.cancel()
        let connection = epoch
        healthTask = Task { [weak self, clock = self.clock, policy = self.policy] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: policy.pingInterval) } catch { return }
                guard let self else { return }
                await self.ping(connection: connection)
            }
        }
    }

    /// Runs independently of jobs (actor calls interleave at awaits), so a hung worker is found
    /// even while a generation waits on it. Skipped while a model is loading: that is slow by design.
    private func ping(connection: Int) async {
        guard connection == epoch, state == .ready, let link else { return }
        let answer: WorkerReplyEnvelope?
        do {
            answer = try await raceTimeout(clock: clock, timeout: policy.pingTimeout) {
                try await link.send(
                    WorkerRequestEnvelope(requestID: UUID(), request: .hello(version: WorkerConstants.protocolVersion))
                )
            }
        } catch {
            terminate(connection: connection, reason: .crashed)
            return
        }
        // A load that began while this ping was in flight has its own, long, threshold.
        if answer == nil, state != .starting { terminate(connection: connection, reason: .unresponsive) }
    }

    // MARK: Events

    fileprivate func receive(_ batch: WorkerEventBatch, connection: Int) {
        guard connection == epoch else { return }
        guard batch.sequence == lastSequence + 1 else {
            // Lost or reordered output cannot be repaired; start over with a clean worker.
            log.error("Event sequence gap: expected \(self.lastSequence + 1, privacy: .public), got \(batch.sequence, privacy: .public)")
            terminate(connection: connection, reason: .crashed)
            return
        }
        lastSequence = batch.sequence
        for event in batch.events {
            switch event {
            case .delta(let id, let text, _):
                guard var entry = pending[id] else { continue }
                entry.text += text
                entry.deliveredOutput = true
                pending[id] = entry
                entry.onDelta(text)
            case .finished(let id, let transcript, let used):
                guard let entry = pending[id] else { continue }
                complete(id, .success(WorkerJobResult(text: entry.text, transcript: transcript, usedTokens: used)))
            case .failed(let id, let failure):
                complete(id, .failure(
                    failure.kind == .cancelled ? CancellationError() : WorkerSupervisorError.worker(failure)
                ))
            }
        }
    }

    fileprivate func protocolBroken(connection: Int) {
        guard connection == epoch else { return }
        log.error("Undecodable event batch")
        terminate(connection: connection, reason: .crashed)
    }

    private func complete(_ id: UUID, _ outcome: Result<WorkerJobResult, Error>) {
        if let continuation = pending[id]?.continuation {
            pending[id] = nil
            continuation.resume(with: outcome)
        } else {
            pending[id]?.outcome = outcome
        }
    }

    // MARK: Gate

    private func acquireGate() async {
        guard gateHeld else {
            gateHeld = true
            return
        }
        _ = await waitForGate(UUID(), cancellable: false)
    }

    /// For jobs: returns false, without the gate, if the caller is cancelled while queued.
    /// Unloads use `acquireGate`, because they must run whoever asked for them.
    private func acquireGateUnlessCancelled() async -> Bool {
        guard gateHeld else {
            gateHeld = true
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await waitForGate(id, cancellable: true)
        } onCancel: {
            Task { await self.leaveGateQueue(id) }
        }
    }

    private func waitForGate(_ id: UUID, cancellable: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            // Already cancelled: `leaveGateQueue` may have run before this waiter was queued.
            if cancellable, Task.isCancelled {
                continuation.resume(returning: false)
            } else {
                gateWaiters.append(GateWaiter(id: id, continuation: continuation))
            }
        }
    }

    private func leaveGateQueue(_ id: UUID) {
        guard let index = gateWaiters.firstIndex(where: { $0.id == id }) else { return }
        gateWaiters.remove(at: index).continuation.resume(returning: false)
    }

    /// Hands the gate to the next waiter, or frees it.
    private func releaseGate() {
        if gateWaiters.isEmpty {
            gateHeld = false
        } else {
            gateWaiters.removeFirst().continuation.resume(returning: true)
        }
    }
}

private struct EventRelay: WorkerConnectionEvents {
    let supervisor: WorkerSupervisor
    let connection: Int

    func deliver(_ batch: WorkerEventBatch) async {
        await supervisor.receive(batch, connection: connection)
    }

    func protocolBroken() async {
        await supervisor.protocolBroken(connection: connection)
    }
}

// MARK: Timeout racing

// Safe: every mutable field is only touched under `lock`, and `finished` makes the continuation resume once.
private final class RaceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var tasks: [Task<Void, Never>] = []
    private let continuation: CheckedContinuation<T?, Error>

    init(_ continuation: CheckedContinuation<T?, Error>) { self.continuation = continuation }

    func add(_ task: Task<Void, Never>) {
        lock.lock()
        let done = finished
        if !done { tasks.append(task) }
        lock.unlock()
        if done { task.cancel() }
    }

    func finish(_ result: Result<T?, Error>) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let running = tasks
        lock.unlock()
        running.forEach { $0.cancel() }
        continuation.resume(with: result)
    }
}

/// Returns the operation's value, or nil if `timeout` elapsed first. Unlike a task group it
/// does not wait for an operation that ignores cancellation (a hung XPC call), so the caller
/// can go on to invalidate the connection that call is stuck on.
func raceTimeout<T: Sendable>(
    clock: any SupervisorClock, timeout: Duration, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T? {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T?, Error>) in
        let box = RaceBox<T>(continuation)
        box.add(Task {
            do { box.finish(.success(try await operation())) } catch { box.finish(.failure(error)) }
        })
        box.add(Task {
            do {
                try await clock.sleep(for: timeout)
                box.finish(.success(nil))
            } catch {}
        })
    }
}
#endif
