#if os(macOS)
import Foundation

/// Versioned Gateway <-> Worker contract. Like the app <-> Gateway contract, one XPC method
/// carries a JSON envelope so the wire format can evolve without touching the Objective-C
/// protocol. Token output flows the other way through a client-exported `WorkerEventSinkXPC`.
enum WorkerConstants {
    static let protocolVersion = 1
    /// CFBundleIdentifier of the embedded `Worker.xpc`; also its XPC service name.
    static let serviceName = "com.example.localllmchat.worker"
    /// Target interval for coalescing streamed output into one batch.
    static let batchInterval: Duration = .milliseconds(30)
}

@objc protocol WorkerXPCProtocol {
    /// Gateway -> Worker. `request` is a JSON `WorkerRequestEnvelope`.
    func send(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

@objc protocol WorkerEventSinkXPC {
    /// Worker -> Gateway. `batch` is a JSON `WorkerEventBatch`. The worker must not send the next
    /// batch until `ack` has been called, which bounds memory when the Gateway is slow.
    func deliver(_ batch: Data, ack: @escaping @Sendable () -> Void)
}

// MARK: Requests

struct WorkerGenerationOptions: Codable, Equatable, Sendable {
    var temperature: Double?
    var maximumResponseTokens: Int?
}

enum WorkerModelLocation: Codable, Equatable, Sendable {
    case path(String)
}

enum WorkerRequest: Codable, Equatable, Sendable {
    /// First call on a connection; the reply carries the worker's version.
    case hello(version: Int)
    case load(WorkerModelLocation)
    case unload
    /// `transcript` is an encoded `Transcript` the new session continues from.
    case openSession(sessionID: UUID, instructions: String?, transcript: Data?)
    /// Output arrives as events tagged with this envelope's `requestID`.
    case generate(sessionID: UUID, prompt: String, options: WorkerGenerationOptions)
    /// Cancels the in-flight request whose id is `target`.
    case cancel(target: UUID)
    case closeSession(sessionID: UUID)
}

struct WorkerRequestEnvelope: Codable, Equatable, Sendable {
    var version = WorkerConstants.protocolVersion
    /// Unique per call. Replies and streamed events echo it.
    var requestID: UUID
    var request: WorkerRequest
}

// MARK: Replies and events

enum WorkerFailureKind: String, Codable, Sendable {
    case unsupportedProtocol, malformedRequest, modelNotLoaded, modelLoadFailed
    case unknownSession, contextOverflow, cancelled, busy, internalError
}

struct WorkerFailure: Codable, Equatable, Error, Sendable {
    var kind: WorkerFailureKind
    var message: String
}

enum WorkerReply: Codable, Equatable, Sendable {
    case hello(version: Int)
    case loaded(contextSize: Int?)
    /// The call was accepted (unload, openSession, generate started, cancel, closeSession).
    case accepted
    case failure(WorkerFailure)
}

struct WorkerReplyEnvelope: Codable, Equatable, Sendable {
    var version = WorkerConstants.protocolVersion
    var requestID: UUID?
    var reply: WorkerReply
}

enum WorkerEvent: Codable, Equatable, Sendable {
    /// Text appended since the previous event for this request.
    case delta(requestID: UUID, text: String, usedTokens: Int)
    case finished(requestID: UUID, transcript: Data, usedTokens: Int)
    case failed(requestID: UUID, WorkerFailure)

    var requestID: UUID {
        switch self {
        case .delta(let id, _, _), .finished(let id, _, _), .failed(let id, _): id
        }
    }
}

struct WorkerEventBatch: Codable, Equatable, Sendable {
    var version = WorkerConstants.protocolVersion
    /// Strictly increasing per connection, so the receiver can detect loss or reordering.
    var sequence: Int
    var events: [WorkerEvent]
}

enum WorkerWire {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder { JSONDecoder() }
}

// MARK: Transport-independent seams

/// Worker side of the contract, independent of XPC. The real worker and test fakes conform.
protocol WorkerServing: Sendable {
    func handle(_ request: WorkerRequestEnvelope) async -> WorkerReplyEnvelope
}

/// Receiver of streamed events (the Gateway). `deliver` returns once the batch is processed,
/// which is the ack the sender waits for before producing the next batch.
protocol WorkerEventReceiving: Sendable {
    func deliver(_ batch: WorkerEventBatch) async
}

/// Pure outbound queue for worker events: coalesces consecutive deltas of one request and
/// allows a single batch in flight. The transport owns timing (flush every `batchInterval`)
/// and calls `acknowledge()` when the receiver acks.
struct WorkerEventQueue: Sendable {
    private var pending: [WorkerEvent] = []
    private var inFlight = false
    private var nextSequence = 0

    var isIdle: Bool { pending.isEmpty && !inFlight }

    mutating func enqueue(_ event: WorkerEvent) {
        if case .delta(let id, let text, let used) = event,
           case .delta(let lastID, let lastText, _)? = pending.last, lastID == id {
            pending[pending.count - 1] = .delta(requestID: id, text: lastText + text, usedTokens: used)
        } else {
            pending.append(event)
        }
    }

    /// The next batch to send, or nil when nothing is pending or the previous batch is unacked.
    mutating func takeBatch() -> WorkerEventBatch? {
        guard !inFlight, !pending.isEmpty else { return nil }
        defer { pending = []; inFlight = true; nextSequence += 1 }
        return WorkerEventBatch(sequence: nextSequence, events: pending)
    }

    mutating func acknowledge() { inFlight = false }

    /// Drops everything queued for a cancelled request (an in-flight batch is unaffected).
    mutating func discard(requestID: UUID) {
        pending.removeAll { $0.requestID == requestID }
    }
}
#endif
