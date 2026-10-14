import Foundation
import OSLog

// Chat replies inside the Gateway. This file is the Gateway's half of `chatGenerate` and
// `chatCancel` (`GatewayIPC.swift`); the output leaves through `GatewayEventPublisher`
// (`GatewayEvents.swift`) and the generation itself runs on `WorkerSupervisor`.

/// What the chat service needs from the worker's owner. `WorkerSupervisor` conforms; tests use a
/// stub. Narrower than `DigestWorkerRunning` on purpose: chat never has to know how a digest
/// run is shaped.
protocol ChatWorkerRunning: Sendable {
    /// One generation in a fresh worker session; see `WorkerSupervisor.generate` for how
    /// cancellation and failures surface.
    func generate(
        _ job: WorkerJob, onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> WorkerJobResult
    /// Clears the crash counter and leaves safe mode.
    func leaveSafeMode() async
}

extension WorkerSupervisor: ChatWorkerRunning {}

/// Where a generation's events go: the one connection that asked. `GatewayEventPublisher`
/// conforms; tests record.
protocol ChatEventSending: Sendable {
    /// False when the connection is gone, in which case nothing was queued.
    func send(chat event: GatewayEvent, to connection: UUID) async -> Bool
}

extension GatewayEventPublisher: ChatEventSending {}

/// Runs chat replies for app connections: one stored task per generation, owned by the
/// connection that asked for it.
///
/// - **The worker keeps no conversation.** Every request carries the transcript to continue
///   from, and the worker session lives for that one reply (see `WorkerSupervisor`).
/// - **Exactly one terminal event** (`chatFinished` or `chatFailed`) per accepted generation,
///   after all its deltas, unless the connection went away first: then nothing more is sent
///   and the generation is cancelled.
/// - **Cancellation is not a failure.** A stopped generation ends with `chatFailed(.cancelled)`.
/// - **A closed connection takes its generations with it** (`connectionClosed`), so a vanished
///   app does not leave a model generating for nobody.
/// - Persists nothing: a Gateway restart ends every generation, and the app sees its connection
///   drop.
actor GatewayChatService {
    /// Generations one connection may have outstanding, counting ones that were cancelled and
    /// have not finished unwinding yet (a worker given `cancelTimeout` to stop), so a quick
    /// Stop-then-Send is not refused while a bad client still cannot queue without bound.
    static let maxActivePerConnection = 4

    private struct Entry {
        var connection: UUID
        var task: Task<Void, Never>
    }

    private let worker: any ChatWorkerRunning
    private let locator: any ModelLocating
    private let events: any ChatEventSending
    private let log = Logger(subsystem: GatewayConstants.label, category: "chat")
    /// Generations accepted and not yet ended, by generation ID. Bounded by
    /// `maxActivePerConnection` per open connection; an entry leaves when its terminal event
    /// has been handed to the publisher.
    private var active: [UUID: Entry] = [:]

    init(worker: any ChatWorkerRunning, locator: any ModelLocating, events: any ChatEventSending) {
        self.worker = worker
        self.locator = locator
        self.events = events
    }

    /// Number of generations accepted and not yet ended.
    var activeCount: Int { active.count }

    /// Accepts a generation. Returns nil when it is running (its output follows as events), or
    /// the refusal to send back as the reply. Nothing is queued on a refusal.
    func start(_ request: ChatGenerateRequest, id: UUID, connection: UUID) -> GatewayFailure? {
        guard active[id] == nil else {
            return GatewayFailure(kind: .requestInProgress, message: "This generation is already running.")
        }
        guard active.values.filter({ $0.connection == connection }).count < Self.maxActivePerConnection else {
            return GatewayFailure(kind: .alreadyRunning, message: "Too many replies are being generated at once.")
        }
        guard let path = locator.localPath(for: request.model) else {
            return GatewayFailure(
                kind: .modelNotDownloaded,
                message: GatewayError.modelNotDownloaded(request.model.catalogID).localizedDescription
            )
        }
        let job = WorkerJob(
            model: .path(path),
            // A transcript already holds the instructions; sending both would duplicate them.
            instructions: request.transcript == nil ? request.instructions : nil,
            transcript: request.transcript,
            prompt: request.prompt,
            options: WorkerGenerationOptions(maximumResponseTokens: request.maximumResponseTokens)
        )
        // Unstructured on purpose: the generation outlives the request that started it. It is
        // stored in `active` before this method returns and is cancelled by `cancel` and
        // `connectionClosed`, so nothing else has to remember it.
        let task = Task { await self.run(id: id, connection: connection, job: job) }
        active[id] = Entry(connection: connection, task: task)
        return nil
    }

    /// Stops generation `id`, if `connection` started it. Safe to call for one that already
    /// ended or never existed; another connection's generation is left alone.
    func cancel(_ id: UUID, connection: UUID) {
        guard let entry = active[id], entry.connection == connection else { return }
        entry.task.cancel()
    }

    /// The connection is gone: cancel everything it started.
    func connectionClosed(_ connection: UUID) {
        for entry in active.values where entry.connection == connection { entry.task.cancel() }
    }

    // MARK: Running

    private func run(id: UUID, connection: UUID, job: WorkerJob) async {
        // Deltas are produced in a synchronous callback on the supervisor and must reach the
        // publisher in order: one `Task` per delta could reorder them, a stream cannot.
        let (deltas, continuation) = AsyncStream<String>.makeStream()
        let events = events
        // Ends when `continuation.finish()` is called below, on every path out of the generation.
        // Returns whether the connection was still there to receive.
        let forwarder = Task { [weak self] () -> Bool in
            for await text in deltas {
                let delivered = await events.send(
                    chat: .chatDelta(requestID: id, text: text, usedTokens: nil), to: connection
                )
                if !delivered {
                    // Nobody to receive: stop the model instead of letting it finish unheard.
                    await self?.cancel(id, connection: connection)
                    return false
                }
            }
            return true
        }

        let terminal: GatewayEvent
        do {
            // A chat message is a deliberate user action; like a digest run it starts clean
            // rather than failing because an earlier crash loop left the worker in safe mode.
            await worker.leaveSafeMode()
            let result = try await worker.generate(job) { continuation.yield($0) }
            terminal = .chatFinished(
                requestID: id, transcript: result.transcript, usedTokens: result.usedTokens
            )
        } catch {
            terminal = .chatFailed(requestID: id, failure: Self.failure(for: error))
        }
        continuation.finish()
        // Every delta is handed over before the terminal event, so the app never sees the end
        // of a reply followed by more of its text.
        let connected = await forwarder.value
        if connected { _ = await events.send(chat: terminal, to: connection) }
        // Last: until here the entry counts against the connection's limit.
        active[id] = nil
    }

    // MARK: Errors

    /// Maps what the supervisor throws to a kind the app acts on. Cancellation is its own kind
    /// so the app can treat a stop as a stop.
    static func failure(for error: any Error) -> GatewayFailure {
        func failure(_ kind: GatewayFailureKind, _ message: String) -> GatewayFailure {
            GatewayFailure(kind: kind, message: message)
        }
        switch error {
        case is CancellationError:
            return failure(.cancelled, "Stopped.")
        case WorkerSupervisorError.worker(let worker):
            switch worker.kind {
            case .contextOverflow: return failure(.contextOverflow, worker.message)
            case .cancelled: return failure(.cancelled, "Stopped.")
            case .modelLoadFailed, .modelNotLoaded, .unsupportedProtocol:
                return failure(.workerUnavailable, worker.message)
            default: return failure(.internalError, worker.message)
            }
        case WorkerSupervisorError.memoryPressure:
            return failure(.memoryPressure, "The Mac is low on memory, so the model was unloaded. Try again.")
        case WorkerSupervisorError.loadTimedOut:
            return failure(.workerUnavailable, "Loading the model timed out.")
        case WorkerSupervisorError.safeMode:
            return failure(.workerUnavailable, "The model worker was stopped after repeated crashes.")
        case WorkerSupervisorError.interrupted(let reason, _):
            let what = reason == .crashed ? "stopped unexpectedly" : "stopped responding"
            return failure(.workerUnavailable, "The model worker \(what).")
        default:
            return failure(.internalError, error.localizedDescription)
        }
    }
}
