#if os(macOS)
import Foundation

/// Versioned app <-> Gateway contract. One XPC method carries a JSON envelope so the wire
/// format can evolve without changing the Objective-C protocol.
@objc protocol GatewayXPCProtocol {
    func send(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

enum GatewayRequest: Codable, Equatable, Sendable {
    case status
    case updateConfig(DigestConfig)
    case runNow
    case cancelRun
}

enum GatewayReply: Codable, Equatable, Sendable {
    case status(GatewayStatus)
    case failure(String)
}

struct GatewayRequestEnvelope: Codable, Sendable {
    var version = GatewayConstants.protocolVersion
    var request: GatewayRequest
}

struct GatewayReplyEnvelope: Codable, Sendable {
    var version = GatewayConstants.protocolVersion
    var reply: GatewayReply
}

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

/// Transport-independent request handling, shared by the XPC service and by tests.
struct GatewayRequestHandler: Sendable {
    let engine: GatewayEngine
    /// Supplies the worker's state for the status reply; the engine does not know the worker.
    var workerStatus: (@Sendable () async -> WorkerStatus?)?

    func handle(_ data: Data) async -> Data {
        let reply: GatewayReply
        do {
            let envelope = try GatewayWire.decoder.decode(GatewayRequestEnvelope.self, from: data)
            guard envelope.version == GatewayConstants.protocolVersion else {
                throw GatewayError.unsupportedProtocol(envelope.version)
            }
            switch envelope.request {
            case .status: break
            case .updateConfig(let config): try await engine.updateConfig(config)
            case .runNow: try await engine.startRun(.manual)
            case .cancelRun: await engine.cancelRun()
            }
            var status = await engine.status()
            status.worker = await workerStatus?()
            reply = .status(status)
        } catch let error as DecodingError {
            reply = .failure("Could not parse the Gateway request: \(error.localizedDescription)")
        } catch {
            reply = .failure(error.localizedDescription)
        }
        return (try? GatewayWire.encoder.encode(GatewayReplyEnvelope(reply: reply))) ?? Data()
    }
}

protocol GatewayControlling: Sendable {
    func send(_ request: GatewayRequest) async throws -> GatewayStatus
}

/// App-side XPC client. A connection is made per call: requests are rare and this keeps
/// the client trivially recoverable when launchd restarts the Gateway.
struct GatewayXPCClient: GatewayControlling {
    var machServiceName = GatewayConstants.machServiceName

    func send(_ request: GatewayRequest) async throws -> GatewayStatus {
        let payload = try GatewayWire.encoder.encode(GatewayRequestEnvelope(request: request))
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: machServiceName)
            let once = OnceResume(continuation, connection: connection)
            connection.remoteObjectInterface = NSXPCInterface(with: GatewayXPCProtocol.self)
            connection.invalidationHandler = {
                once.resume(throwing: GatewayError.gatewayUnavailable(""))
            }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(throwing: GatewayError.gatewayUnavailable(error.localizedDescription))
            } as? GatewayXPCProtocol
            guard let proxy else {
                once.resume(throwing: GatewayError.gatewayUnavailable(""))
                return
            }
            proxy.send(payload) { reply in
                once.resume(returning: reply)
            }
        }
        let envelope = try GatewayWire.decoder.decode(GatewayReplyEnvelope.self, from: data)
        guard envelope.version == GatewayConstants.protocolVersion else {
            throw GatewayError.unsupportedProtocol(envelope.version)
        }
        switch envelope.reply {
        case .status(let status): return status
        case .failure(let message): throw GatewayError.remote(message)
        }
    }
}

private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private let connection: NSXPCConnection

    init(_ continuation: CheckedContinuation<Data, any Error>, connection: NSXPCConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func resume(returning value: Data) { take()?.resume(returning: value) }
    func resume(throwing error: any Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<Data, any Error>? {
        lock.lock()
        let taken = continuation
        continuation = nil
        lock.unlock()
        if taken != nil { connection.invalidate() }
        return taken
    }
}
#endif
