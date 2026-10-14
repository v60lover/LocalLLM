import Foundation
import FoundationModels

// A chat conversation whose model runs behind the Gateway instead of in this process.
// `RemoteChatSession` owns the one chat stream of a connection and routes it by generation ID;
// `RemoteChatRuntime` is one conversation's `ChatRuntime` on top of it.

/// Routes the Gateway's chat output to the generation it belongs to. One per Gateway
/// connection; `GatewayChatControlling.chatSignals` has a single consumer, and this is it.
@MainActor
final class RemoteChatSession {
    let gateway: any GatewayChatControlling
    private var listeners: [UUID: AsyncStream<GatewayChatSignal>.Continuation] = [:]
    private var pump: Task<Void, Never>?

    init(gateway: any GatewayChatControlling) {
        self.gateway = gateway
        let signals = gateway.chatSignals
        // Ends when the client is stopped (the stream finishes) or in `stop()`.
        pump = Task { [weak self] in
            for await signal in signals { self?.route(signal) }
        }
    }

    deinit { pump?.cancel() }

    /// Output of generation `id`. Called before the request is sent, so nothing that arrives
    /// right after the Gateway accepted it is missed.
    func subscribe(_ id: UUID) -> AsyncStream<GatewayChatSignal> {
        let (stream, continuation) = AsyncStream.makeStream(of: GatewayChatSignal.self)
        listeners[id] = continuation
        return stream
    }

    func unsubscribe(_ id: UUID) {
        listeners.removeValue(forKey: id)?.finish()
    }

    /// Ends every generation's stream and the connection. Final, like `GatewayClient.stop()`.
    func stop() async {
        pump?.cancel()
        pump = nil
        for continuation in listeners.values { continuation.finish() }
        listeners = [:]
        await gateway.stop()
    }

    private func route(_ signal: GatewayChatSignal) {
        switch signal {
        case .delta(let id, _, _), .finished(let id, _, _), .failed(let id, _):
            // An unknown ID is the tail of a generation that was already abandoned.
            listeners[id]?.yield(signal)
        case .connectionLost:
            for continuation in listeners.values { continuation.yield(signal) }
        }
    }
}

/// One conversation. The Gateway keeps no conversation between replies, so every reply sends
/// the transcript so far and takes the new transcript back.
@MainActor
final class RemoteChatRuntime: ChatRuntime {
    /// Tool calls do not cross the process boundary yet.
    let supportsTools = false
    let responseTokenBudget = 2048
    private(set) var transcript: Transcript

    private let model: ModelReference
    private let session: RemoteChatSession
    /// The transcript to continue from; nil until there is one, in which case the Gateway
    /// opens a fresh conversation with `instructions`.
    private var continuation: Data?
    /// A transcript the conversation was restored with, encoded on the first reply so that
    /// failing to encode it is that reply's error instead of a silently fresh conversation.
    private var restored: Transcript?
    /// Token count of the last finished reply; deltas do not carry one.
    private var usedTokens = 0

    init(model: ModelReference, transcript: Transcript?, session: RemoteChatSession) {
        self.model = model
        self.session = session
        self.transcript = transcript ?? Transcript()
        restored = transcript
    }

    func generate(
        prompt: String, onSnapshot: @MainActor (String, Int) -> Void
    ) async throws -> GenerationOutcome {
        if continuation == nil, let restored {
            continuation = try WorkerWire.encoder.encode(restored)
            self.restored = nil
        }
        let id = UUID()
        let signals = session.subscribe(id)
        defer { session.unsubscribe(id) }
        let gateway = session.gateway
        let request = ChatGenerateRequest(
            model: model, prompt: prompt,
            instructions: "Answer in the user's language.",
            transcript: continuation, maximumResponseTokens: responseTokenBudget
        )
        var text = ""
        var known = usedTokens
        return try await withTaskCancellationHandler {
            if let refusal = try await gateway.generate(request, id: id) { throw Self.error(for: refusal) }
            // Stop arrived while the request was on its way: the handler below may have run
            // before the Gateway knew the generation, so ask again now that it does.
            if Task.isCancelled {
                try? await gateway.cancel(id)
                throw CancellationError()
            }
            for await signal in signals {
                switch signal {
                case .delta(_, let delta, let tokens):
                    text += delta
                    known = tokens ?? known
                    onSnapshot(text, known)
                case .finished(_, let data, let tokens):
                    let decoded = try WorkerWire.decoder.decode(Transcript.self, from: data)
                    transcript = decoded
                    continuation = data
                    usedTokens = tokens
                    return GenerationOutcome(text: text, transcript: decoded, usedTokens: tokens)
                case .failed(_, let failure):
                    throw Self.error(for: failure)
                case .connectionLost:
                    throw ChatRuntimeError.interrupted
                }
            }
            // The stream ends early when this task is cancelled or the session is stopped.
            try Task.checkCancellation()
            throw ChatRuntimeError.interrupted
        } onCancel: {
            // Not awaited: the stop must not wait for the Gateway. The generation ends there
            // with `cancelled`, which nobody is listening for any more.
            Task { try? await gateway.cancel(id) }
        }
    }

    /// What the UI already knows how to show: a stop is a cancellation, a full context is the
    /// typed overflow the store trims and retries on, the rest carries the Gateway's words.
    private static func error(for failure: GatewayFailure) -> any Error {
        switch failure.kind {
        case .cancelled: CancellationError()
        case .contextOverflow: ChatRuntimeError.contextOverflow
        default: GatewayError.remote(failure.message)
        }
    }
}
