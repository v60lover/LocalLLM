import Foundation

/// Model access behind a seam so the worker's session logic is testable without CoreAI.
protocol WorkerModelLoading: Sendable {
    func load(_ location: WorkerModelLocation) async throws -> any WorkerLoadedModel
}

protocol WorkerLoadedModel: Sendable {
    var contextSize: Int? { get }
    func makeSession(instructions: String?, transcript: Data?) throws -> any WorkerLanguageSession
}

struct WorkerSessionResult: Sendable {
    var transcript: Data
    var usedTokens: Int
}

protocol WorkerLanguageSession: Sendable {
    /// `onSnapshot` receives the full reply so far and the tokens used. Implementations throw
    /// `WorkerFailure(kind: .contextOverflow)` when the context is exhausted.
    func respond(
        to prompt: String, options: WorkerGenerationOptions,
        onSnapshot: @Sendable (String, Int) -> Void
    ) async throws -> WorkerSessionResult
}

/// Keeps the worker process alive while a model is resident (os_transaction in production).
protocol WorkerResidencyHolding: Sendable {
    func acquire()
    func release()
}

struct NoResidencyHolder: WorkerResidencyHolding {
    func acquire() {}
    func release() {}
}

/// Transport-independent worker: one loaded model, many sessions, one generation per session.
/// Streamed output goes to `emit`; the transport batches and applies backpressure.
actor WorkerEngine: WorkerServing {
    private let loader: any WorkerModelLoading
    private let residency: any WorkerResidencyHolding
    private let emit: @Sendable (WorkerEvent) -> Void

    private var model: (any WorkerLoadedModel)?
    private var sessions: [UUID: any WorkerLanguageSession] = [:]
    private var running: [UUID: (session: UUID, task: Task<Void, Never>)] = [:]

    init(
        loader: any WorkerModelLoading,
        residency: any WorkerResidencyHolding = NoResidencyHolder(),
        emit: @escaping @Sendable (WorkerEvent) -> Void
    ) {
        self.loader = loader
        self.residency = residency
        self.emit = emit
    }

    func handle(_ envelope: WorkerRequestEnvelope) async -> WorkerReplyEnvelope {
        let id = envelope.requestID
        func reply(_ reply: WorkerReply) -> WorkerReplyEnvelope {
            WorkerReplyEnvelope(requestID: id, reply: reply)
        }
        func failure(_ kind: WorkerFailureKind, _ message: String) -> WorkerReplyEnvelope {
            reply(.failure(WorkerFailure(kind: kind, message: message)))
        }
        guard envelope.version == WorkerConstants.protocolVersion else {
            return failure(.unsupportedProtocol, "Unsupported worker protocol \(envelope.version).")
        }
        switch envelope.request {
        case .hello(let version):
            guard version == WorkerConstants.protocolVersion else {
                return failure(.unsupportedProtocol, "Unsupported worker protocol \(version).")
            }
            return reply(.hello(version: WorkerConstants.protocolVersion))

        case .load(let location):
            teardown()
            do {
                let loaded = try await loader.load(location)
                model = loaded
                residency.acquire()
                return reply(.loaded(contextSize: loaded.contextSize))
            } catch let error as WorkerFailure {
                return reply(.failure(error))
            } catch {
                return failure(.modelLoadFailed, error.localizedDescription)
            }

        case .unload:
            teardown()
            return reply(.accepted)

        case .openSession(let sessionID, let instructions, let transcript):
            guard let model else { return failure(.modelNotLoaded, "No model is loaded.") }
            do {
                sessions[sessionID] = try model.makeSession(instructions: instructions, transcript: transcript)
                return reply(.accepted)
            } catch {
                return failure(.internalError, error.localizedDescription)
            }

        case .generate(let sessionID, let prompt, let options):
            guard model != nil else { return failure(.modelNotLoaded, "No model is loaded.") }
            guard let session = sessions[sessionID] else { return failure(.unknownSession, "Unknown session.") }
            guard !running.values.contains(where: { $0.session == sessionID }) else {
                return failure(.busy, "The session is already generating.")
            }
            let emit = emit
            let task = Task { [weak self] in
                await Self.run(session, prompt: prompt, options: options, requestID: id, emit: emit)
                await self?.finish(id)
            }
            running[id] = (sessionID, task)
            return reply(.accepted)

        case .cancel(let target):
            running[target]?.task.cancel()
            return reply(.accepted)

        case .closeSession(let sessionID):
            guard sessions.removeValue(forKey: sessionID) != nil else {
                return failure(.unknownSession, "Unknown session.")
            }
            for (_, entry) in running where entry.session == sessionID { entry.task.cancel() }
            return reply(.accepted)
        }
    }

    private func finish(_ requestID: UUID) { running[requestID] = nil }

    private func teardown() {
        for (_, entry) in running { entry.task.cancel() }
        running = [:]
        sessions = [:]
        if model != nil { residency.release() }
        model = nil
    }

    private static func run(
        _ session: any WorkerLanguageSession, prompt: String, options: WorkerGenerationOptions,
        requestID: UUID, emit: @Sendable (WorkerEvent) -> Void
    ) async {
        let sent = Sent()
        do {
            let result = try await session.respond(to: prompt, options: options) { text, used in
                // Snapshots are cumulative; send only the appended suffix. A snapshot that is not
                // an extension of the previous one is skipped: `finished` carries the transcript.
                guard let delta = sent.advance(to: text), !delta.isEmpty else { return }
                emit(.delta(requestID: requestID, text: delta, usedTokens: used))
            }
            try Task.checkCancellation()
            emit(.finished(requestID: requestID, transcript: result.transcript, usedTokens: result.usedTokens))
        } catch is CancellationError {
            emit(.failed(requestID: requestID, WorkerFailure(kind: .cancelled, message: "Cancelled.")))
        } catch let failure as WorkerFailure {
            emit(.failed(requestID: requestID, failure))
        } catch {
            emit(.failed(requestID: requestID, WorkerFailure(kind: .internalError, message: error.localizedDescription)))
        }
    }

    private final class Sent: @unchecked Sendable {
        private var text = ""
        func advance(to snapshot: String) -> String? {
            guard snapshot.hasPrefix(text) else { return nil }
            defer { text = snapshot }
            return String(snapshot.dropFirst(text.count))
        }
    }
}
