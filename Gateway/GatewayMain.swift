import AppKit
import Foundation
import OSLog

/// Gateway -> app event sink over one connection. Thin adapter: the queue, the ack timeout and
/// the drop policy live in `GatewayEventPublisher`.
// Safe: `connection` is a `let` (NSXPCConnection is thread-safe).
final class XPCGatewayEventSink: GatewayEventSending, @unchecked Sendable {
    private let connection: NSXPCConnection

    init(connection: NSXPCConnection) { self.connection = connection }

    func deliver(_ batch: GatewayEventBatch) async throws {
        let data = try GatewayWire.encoder.encode(batch)
        // The ack carries no payload; `Data` is only what `OnceResumer` is typed for.
        let _: Data = try await withCheckedThrowingContinuation { continuation in
            // The ack block and the error handler can both run: resume exactly once.
            let once = OnceResumer(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { once.resume(throwing: $0) }
            guard let sink = proxy as? any GatewayEventSinkXPC else {
                once.resume(throwing: GatewayError.connectionLost)
                return
            }
            sink.deliver(data) { once.resume(returning: Data()) }
        }
    }

    func invalidate() { connection.invalidate() }
}

/// One instance per app connection: requests are handled with that connection's handshake state.
// Safe: both properties are immutable `let`s of Sendable types; NSObject is only for @objc.
final class GatewayConnectionService: NSObject, GatewayXPCProtocol, @unchecked Sendable {
    private let handler: GatewayRequestHandler
    private let context: GatewayConnectionContext

    init(handler: GatewayRequestHandler, context: GatewayConnectionContext) {
        self.handler = handler
        self.context = context
    }

    func send(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let handler = handler
        let context = context
        // XPC calls this on its own queue; the handler is async, so the work moves to a task.
        // `handle` always returns a reply, so `reply` is called exactly once.
        Task { reply(await handler.handle(request, connection: context)) }
    }
}

/// Wires up each incoming app connection: requests in one direction, pushed events in the other.
// Safe: both properties are immutable `let`s of Sendable types; NSObject is only for @objc.
final class GatewayListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    /// Shared by all connections, so the request ledger and the instance ID are per process.
    private let handler: GatewayRequestHandler
    private let publisher: GatewayEventPublisher

    init(handler: GatewayRequestHandler, publisher: GatewayEventPublisher) {
        self.handler = handler
        self.publisher = publisher
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The publisher's key for this connection; used to subscribe it and to remove it.
        let id = UUID()
        let publisher = publisher
        let sink = XPCGatewayEventSink(connection: connection)
        // Pushes start after a successful hello; until then the connection is not subscribed.
        let context = GatewayConnectionContext(onGreeted: {
            Task { await publisher.subscribe(id, sink: sink) }
        })
        // Exported: what the app calls here. Remote: the sink the app exports for pushes.
        connection.exportedInterface = NSXPCInterface(with: GatewayXPCProtocol.self)
        connection.exportedObject = GatewayConnectionService(handler: handler, context: context)
        connection.remoteObjectInterface = NSXPCInterface(with: GatewayEventSinkXPC.self)
        // A vanished app must not stay subscribed.
        connection.invalidationHandler = { Task { await publisher.unsubscribe(id) } }
        connection.interruptionHandler = { Task { await publisher.unsubscribe(id) } }
        connection.resume()
        return true
    }
}

@main
struct GatewayMain {
    static func main() {
        let log = Logger(subsystem: GatewayConstants.label, category: "main")
        // One supervisor per process: it owns the worker's lifecycle.
        let supervisor = WorkerSupervisor(connector: XPCWorkerConnector())
        let memoryMonitor = SystemMemoryPressureMonitor(supervisor: supervisor)
        // The suspending clock does not advance during sleep; wake restarts the idle and health timers.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { _ in
            Task { await supervisor.systemDidWake() }
        }
        // The engine reports changes to the publisher, which reads the engine's status: the
        // relay breaks the construction cycle.
        let relay = GatewayChangeRelay()
        let engine = GatewayEngine(
            store: GatewayStateStore(directory: GatewayPaths.supportDirectory),
            job: NewsDigestJob(
                fetcher: URLSessionNewsFetcher(),
                summarizer: WorkerDigestSummarizer(worker: supervisor, locator: ModelStoreLocator()),
                publisher: PagesPublisher()
            ),
            observer: relay
        )
        // One closure for both consumers below, so replies and pushes describe the worker the
        // same way.
        let workerStatus: @Sendable () async -> WorkerStatus? = { [supervisor] in
            WorkerStatus(await supervisor.state)
        }
        let publisher = GatewayEventPublisher(
            source: GatewayStatusSource(engine: engine, workerStatus: workerStatus)
        )
        // From here on every engine change reaches the publisher. Nothing was missed before
        // this line: the scheduler loop has not started and no connection is accepted yet.
        relay.attach(publisher)
        // One handler for the whole process (see `GatewayListenerDelegate`).
        let handler = GatewayRequestHandler(engine: engine, workerStatus: workerStatus)
        let delegate = GatewayListenerDelegate(handler: handler, publisher: publisher)
        let listener = NSXPCListener(machServiceName: GatewayConstants.machServiceName)
        listener.delegate = delegate
        listener.resume()
        Task { await engine.runSchedulerLoop() }
        log.info("gateway started, protocol \(GatewayConstants.protocolVersion)")
        // A run loop, not dispatchMain(): NSWorkspace delivers the wake notification through the
        // main run loop. The monitor must outlive `main`; the loop never ends, so this pins it.
        withExtendedLifetime((memoryMonitor, delegate)) { RunLoop.main.run() }
    }
}
