#if os(macOS)
import Foundation

/// Versioned app <-> Gateway contract (protocol 2). One XPC method carries a JSON envelope so the
/// wire format can evolve without changing the Objective-C protocol. Pushed output flows the other
/// way through a client-exported `GatewayEventSinkXPC` (see `GatewayEvents.swift`).
///
/// Rules of the contract:
/// - The first request on every connection is `hello`; anything else is answered with
///   `handshakeRequired`.
/// - Every request carries a `requestID`. A mutating request (`updateConfig`, `runNow`,
///   `cancelRun`) is executed at most once per ID: a duplicate gets the stored reply, so a client
///   that lost the reply can ask `requestStatus` instead of guessing.
/// - The interface only grows: new request/reply cases and new event types are added, existing
///   ones keep their shape.
@objc protocol GatewayXPCProtocol {
    func send(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

enum GatewayRequest: Codable, Equatable, Sendable {
    /// First message on a connection; the reply carries the Gateway's version and instance.
    case hello(version: Int)
    /// Read the current status. Needed once after connecting; later changes are pushed.
    case status
    /// Replace the digest configuration. Answered with the resulting status, or `invalidConfig`.
    case updateConfig(DigestConfig)
    /// Start a manual run. Answered as soon as it has started, not when it finishes.
    case runNow
    /// Cancel the active run, if any.
    case cancelRun
    /// Liveness check. Answered with `pong`.
    case ping
    /// What became of an earlier request, by its `requestID`.
    case requestStatus(UUID)

    /// Whether the request changes Gateway state and therefore goes through the ledger.
    var isMutating: Bool {
        switch self {
        case .updateConfig, .runNow, .cancelRun: true
        case .hello, .status, .ping, .requestStatus: false
        }
    }
}

/// Why a request was refused, as something the client can branch on. The first row is about
/// the protocol itself, the second about the request's content or timing.
enum GatewayFailureKind: String, Codable, Sendable {
    case unsupportedProtocol, handshakeRequired, malformedRequest
    case alreadyRunning, invalidConfig, requestInProgress, internalError
}

/// A refusal: `kind` for the code, `message` for the user.
struct GatewayFailure: Codable, Equatable, Sendable {
    var kind: GatewayFailureKind
    var message: String
}

/// The state of an earlier request, as the ledger remembers it.
enum GatewayRequestState: Codable, Equatable, Sendable {
    /// Never seen, evicted, or the Gateway restarted since.
    case unknown
    /// Accepted and still executing; ask again.
    case inProgress
    /// Finished. Carries the reply the original caller would have received.
    case completed(GatewayReply)
}

// `indirect` because `requestState(.completed(GatewayReply))` nests a reply inside a reply.
indirect enum GatewayReply: Codable, Equatable, Sendable {
    /// `instanceID` changes whenever the Gateway process restarts.
    case hello(version: Int, instanceID: UUID)
    /// The answer to `status` and to every mutating request that succeeded.
    case status(GatewayStatus)
    case pong
    case requestState(GatewayRequestState)
    case failure(GatewayFailure)
}

/// What travels in `GatewayXPCProtocol.send`. `version` is read on its own before the rest is
/// decoded, so a peer from another protocol version still gets a readable answer.
struct GatewayRequestEnvelope: Codable, Sendable {
    var version = GatewayConstants.protocolVersion
    /// Chosen by the client; the key under which the ledger remembers a mutating request.
    var requestID = UUID()
    var request: GatewayRequest
}

struct GatewayReplyEnvelope: Codable, Sendable {
    var version = GatewayConstants.protocolVersion
    /// Echoes the request's ID. Nil when the request could not be decoded far enough to have one.
    var requestID: UUID?
    var reply: GatewayReply
}

/// The one encoder/decoder pair for everything that crosses the app <-> Gateway boundary.
/// Dates are ISO-8601 on both sides; encoding with one and decoding with a plain `JSONDecoder`
/// fails on the first `Date`.
enum GatewayWire {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: Ledger

/// Remembers what became of mutating requests, so a retried or re-asked request is never run
/// twice. In memory and bounded: the oldest entry is evicted first. A Gateway restart empties it,
/// which the client detects through the `instanceID` in the `hello` reply.
actor GatewayRequestLedger {
    enum Begin: Equatable, Sendable {
        /// First time this ID is seen: the caller must execute it and then call `complete`.
        case fresh
        /// Seen before: the caller must not execute it, only report the stored state.
        case duplicate(GatewayRequestState)
    }

    /// Far more than a settings window produces between a lost reply and its recovery, which
    /// happens within seconds.
    static let defaultCapacity = 128

    private let capacity: Int
    /// Insertion order, oldest first; decides what is evicted.
    private var order: [UUID] = []
    private var states: [UUID: GatewayRequestState] = [:]

    init(capacity: Int = GatewayRequestLedger.defaultCapacity) { self.capacity = capacity }

    var count: Int { states.count }

    /// Check and record in one actor call with no await in between, so two copies of the same
    /// request can never both be told `fresh`.
    func begin(_ id: UUID) -> Begin {
        if let known = states[id] { return .duplicate(known) }
        states[id] = .inProgress
        order.append(id)
        while order.count > capacity { states[order.removeFirst()] = nil }
        return .fresh
    }

    /// Stores the reply for later duplicates and `requestStatus` questions.
    func complete(_ id: UUID, with reply: GatewayReply) {
        // An entry evicted while it ran stays forgotten rather than coming back out of order.
        if states[id] != nil { states[id] = .completed(reply) }
    }

    func state(of id: UUID) -> GatewayRequestState { states[id] ?? .unknown }
}

// MARK: Handler

/// The full status a client sees: the engine's plus the worker's. The one definition, shared by
/// replies and pushed events.
struct GatewayStatusSource: Sendable {
    let engine: GatewayEngine
    /// Supplies the worker's state; the engine does not know the worker.
    var workerStatus: (@Sendable () async -> WorkerStatus?)?

    func current() async -> GatewayStatus {
        var status = await engine.status()
        status.worker = await workerStatus?()
        return status
    }
}

/// Per-connection protocol state. A class so the transport and the handler share one instance.
// Safe: `greeted` is only accessed under `lock`; `onGreeted` is an immutable `let` and runs after unlock.
final class GatewayConnectionContext: @unchecked Sendable {
    private let lock = NSLock()
    /// A hello with the right version was answered on this connection.
    private var greeted = false
    private let onGreeted: (@Sendable () -> Void)?

    /// `onGreeted` runs once, after a successful `hello` (the transport subscribes to pushes there).
    init(onGreeted: (@Sendable () -> Void)? = nil) { self.onGreeted = onGreeted }

    var hasGreeted: Bool { lock.withLock { greeted } }

    fileprivate func markGreeted() {
        // A client may send hello twice; only the first one subscribes the connection.
        let first = lock.withLock { () -> Bool in
            let first = !greeted
            greeted = true
            return first
        }
        if first { onGreeted?() }
    }
}

/// Transport-independent request handling, shared by the XPC service and by tests.
///
/// One handler serves every connection, so the ledger and `instanceID` are per process; what
/// differs per connection (has it said hello?) comes in as `GatewayConnectionContext`.
struct GatewayRequestHandler: Sendable {
    let engine: GatewayEngine
    /// Supplies the worker's state for the status reply; the engine does not know the worker.
    var workerStatus: (@Sendable () async -> WorkerStatus?)?
    /// Identifies this Gateway process; a client that sees it change knows the ledger is gone.
    var instanceID = UUID()
    var ledger = GatewayRequestLedger()

    init(
        engine: GatewayEngine, workerStatus: (@Sendable () async -> WorkerStatus?)? = nil,
        instanceID: UUID = UUID(), ledger: GatewayRequestLedger = GatewayRequestLedger()
    ) {
        self.engine = engine
        self.workerStatus = workerStatus
        self.instanceID = instanceID
        self.ledger = ledger
    }

    private var statusSource: GatewayStatusSource {
        GatewayStatusSource(engine: engine, workerStatus: workerStatus)
    }

    /// Answers one request. Never throws and never returns nothing: every outcome, including
    /// bytes that cannot be parsed, becomes a reply envelope the peer can decode. The order of
    /// the checks is the contract: version, then decoding, then handshake, then the request.
    func handle(_ data: Data, connection: GatewayConnectionContext) async -> Data {
        // Read only the version first: a peer from another protocol version may send a request
        // this build cannot decode, and still deserves a reply it can show.
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            return encode(.failure(.init(kind: .malformedRequest, message: "Could not parse the Gateway request.")), id: nil)
        }
        guard probe.version == GatewayConstants.protocolVersion else {
            return mismatchReply(peerVersion: probe.version)
        }
        let envelope: GatewayRequestEnvelope
        do {
            envelope = try GatewayWire.decoder.decode(GatewayRequestEnvelope.self, from: data)
        } catch {
            return encode(.failure(.init(
                kind: .malformedRequest,
                message: "Could not parse the Gateway request: \(error.localizedDescription)"
            )), id: nil)
        }
        let id = envelope.requestID

        // Hello is handled before the handshake check, since it is what performs the handshake.
        if case .hello(let version) = envelope.request {
            // The envelope version matched above, but the version the peer states in the hello
            // itself is checked too: only a matching one marks the connection as greeted.
            guard version == GatewayConstants.protocolVersion else { return mismatchReply(peerVersion: version) }
            connection.markGreeted()
            return encode(.hello(version: GatewayConstants.protocolVersion, instanceID: instanceID), id: id)
        }
        // Refused before the ledger or the engine is touched: a peer that skipped the
        // handshake changes nothing.
        guard connection.hasGreeted else {
            return encode(.failure(.init(
                kind: .handshakeRequired, message: "The first request on a connection must be hello."
            )), id: id)
        }

        switch envelope.request {
        case .hello:
            // Returned above; the case is here only to keep the switch exhaustive.
            return encode(.failure(.init(kind: .internalError, message: "unreachable")), id: id)
        case .ping:
            return encode(.pong, id: id)
        case .status:
            return encode(.status(await statusSource.current()), id: id)
        case .requestStatus(let target):
            return encode(.requestState(await ledger.state(of: target)), id: id)
        case .updateConfig, .runNow, .cancelRun:
            // Mutating requests go through the ledger: at most one execution per request ID.
            switch await ledger.begin(id) {
            case .duplicate(.completed(let stored)):
                // Already done: the same answer again, without doing it again.
                return encode(stored, id: id)
            case .duplicate:
                // The first copy is still executing; running a second one is exactly what the
                // ledger exists to prevent.
                return encode(.failure(.init(
                    kind: .requestInProgress, message: "This request is already being processed."
                )), id: id)
            case .fresh:
                // The reply is stored whether it is a success or a refusal, so a duplicate of
                // a refused request is refused the same way.
                let reply = await execute(envelope.request)
                await ledger.complete(id, with: reply)
                return encode(reply, id: id)
            }
        }
    }

    /// Runs one mutating request against the engine and turns the outcome into a reply.
    private func execute(_ request: GatewayRequest) async -> GatewayReply {
        do {
            switch request {
            case .updateConfig(let config): try await engine.updateConfig(config)
            case .runNow: try await engine.startRun(.manual)
            case .cancelRun: await engine.cancelRun()
            default: break
            }
            // The status after the change, so the client can show the result without a second
            // request. The same change is also pushed; `GatewayStatus.revision` orders the two.
            return .status(await statusSource.current())
        } catch let error as GatewayError {
            return .failure(.init(kind: Self.kind(of: error), message: error.localizedDescription))
        } catch {
            return .failure(.init(kind: .internalError, message: error.localizedDescription))
        }
    }

    private static func kind(of error: GatewayError) -> GatewayFailureKind {
        switch error {
        case .alreadyRunning: .alreadyRunning
        case .invalidConfig: .invalidConfig
        default: .internalError
        }
    }

    // Encoding these plain value types does not fail in practice; `Data()` is the last resort,
    // and the client reports bytes it cannot read as an unreadable reply.
    private func encode(_ reply: GatewayReply, id: UUID?) -> Data {
        (try? GatewayWire.encoder.encode(GatewayReplyEnvelope(requestID: id, reply: reply))) ?? Data()
    }

    /// Protocol 1 peers decode `{"version":1,"reply":{"failure":{"_0":"..."}}}`. Anything else is
    /// answered in this build's shape.
    private func mismatchReply(peerVersion: Int) -> Data {
        let message = GatewayError.unsupportedProtocol(peerVersion).localizedDescription
        if peerVersion == 1 {
            let legacy = LegacyFailureEnvelope(version: 1, reply: .init(failure: .init(_0: message)))
            return (try? JSONEncoder().encode(legacy)) ?? Data()
        }
        return encode(.failure(.init(kind: .unsupportedProtocol, message: message)), id: nil)
    }

    /// Just the envelope's `version`, decodable from any protocol version's bytes.
    private struct VersionProbe: Decodable { var version: Int }

    /// The exact bytes a protocol 1 build wrote for `GatewayReply.failure(String)`.
    private struct LegacyFailureEnvelope: Encodable {
        struct Reply: Encodable {
            struct Payload: Encodable { var _0: String }
            var failure: Payload
        }
        var version: Int
        var reply: Reply
    }
}

/// How the app talks to the Gateway. `GatewayClient` is the production conformance.
protocol GatewayControlling: Sendable {
    /// Sends one request and returns the resulting status; a refusal or an unreachable
    /// Gateway is thrown as `GatewayError`.
    func send(_ request: GatewayRequest) async throws -> GatewayStatus
    /// Connection and status events, for a single consumer. Finishes when the client is stopped.
    var events: AsyncStream<GatewayClientEvent> { get }
    /// Keeps the connection alive (heartbeat, reconnect) until `stop()`.
    func start() async
    /// Final: closes the connection, finishes `events`, and makes later `send` calls fail. A
    /// stopped client is not started again; create a new one.
    func stop() async
}

/// What a `GatewayControlling` tells its consumer without being asked.
enum GatewayClientEvent: Equatable, Sendable {
    /// The handshake succeeded; `instanceID` identifies the Gateway process.
    case connected(instanceID: UUID)
    /// The Gateway pushed a new status.
    case status(GatewayStatus)
    /// The connection is down. `reason` is a full sentence fit to show to the user. Sent once
    /// per outage, not once per failed reconnect attempt.
    case disconnected(reason: String)
}
#endif
