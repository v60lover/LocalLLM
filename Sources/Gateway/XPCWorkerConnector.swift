#if os(macOS)
import Foundation

/// Connects to the worker XPC service embedded in this (Gateway) bundle.
struct XPCWorkerConnector: WorkerConnecting {
    var serviceName = WorkerConstants.serviceName

    func connect(
        events: any WorkerConnectionEvents, onTermination: @escaping @Sendable () -> Void
    ) async throws -> any WorkerLink {
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: WorkerXPCProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: WorkerEventSinkXPC.self)
        connection.exportedObject = EventSinkAdapter(receiver: events)
        let link = XPCWorkerLink(connection: connection)
        // Both handlers mean the worker is gone as far as this connection is concerned.
        connection.interruptionHandler = { [weak link] in
            link?.markGone()
            onTermination()
        }
        connection.invalidationHandler = { [weak link] in
            link?.markGone()
            onTermination()
        }
        connection.resume()
        return link
    }
}

/// Worker -> Gateway: decodes a batch, hands it to the supervisor, acks once it is processed.
/// A batch that cannot be decoded is reported as a protocol break, never silently dropped.
// Safe: the only stored property is an immutable `let` of a Sendable type; NSObject is only for @objc.
final class EventSinkAdapter: NSObject, WorkerEventSinkXPC, @unchecked Sendable {
    private let receiver: any WorkerConnectionEvents

    init(receiver: any WorkerConnectionEvents) { self.receiver = receiver }

    func deliver(_ batch: Data, ack: @escaping @Sendable () -> Void) {
        let receiver = receiver
        Task {
            if let decoded = try? WorkerWire.decoder.decode(WorkerEventBatch.self, from: batch) {
                await receiver.deliver(decoded)
            } else {
                await receiver.protocolBroken()
            }
            ack()
        }
    }
}

// Safe: `connection` is a `let` (NSXPCConnection is thread-safe) and `gone` is only accessed under `lock`.
private final class XPCWorkerLink: WorkerLink, @unchecked Sendable {
    private struct Gone: Error {}

    private let connection: NSXPCConnection
    private let lock = NSLock()
    private var gone = false

    init(connection: NSXPCConnection) { self.connection = connection }

    func markGone() {
        lock.lock()
        gone = true
        lock.unlock()
    }

    private var isGone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return gone
    }

    func send(_ request: WorkerRequestEnvelope) async throws -> WorkerReplyEnvelope {
        guard !isGone else { throw Gone() }
        let data = try WorkerWire.encoder.encode(request)
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            let once = OnceResumer(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { once.resume(throwing: $0) }
            guard let worker = proxy as? any WorkerXPCProtocol else {
                once.resume(throwing: Gone())
                return
            }
            worker.send(data) { once.resume(returning: $0) }
        }
        return try WorkerWire.decoder.decode(WorkerReplyEnvelope.self, from: reply)
    }

    func invalidate(terminate: Bool) {
        markGone()
        let pid = connection.processIdentifier
        connection.invalidate()
        if terminate, pid > 0 { kill(pid, SIGKILL) }
    }
}

// Safe: `continuation` is only accessed under `lock`, and `take()` hands it out once. Also used by `XPCGatewayLink`.
final class OnceResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }

    private func take() -> CheckedContinuation<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }

    func resume(returning data: Data) { take()?.resume(returning: data) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }
}

/// Forwards the system's memory-pressure notifications to the supervisor.
// Safe: `source` is a `let`, configured in `init` before it is resumed; DispatchSource is thread-safe and only cancelled in `deinit`.
final class SystemMemoryPressureMonitor: @unchecked Sendable {
    private let source: DispatchSourceMemoryPressure

    init(supervisor: WorkerSupervisor) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        source.setEventHandler { [source] in
            let level: MemoryPressureLevel = source.data.contains(.critical) ? .critical : .warning
            Task { await supervisor.handleMemoryPressure(level) }
        }
        source.resume()
    }

    deinit { source.cancel() }
}
#endif
