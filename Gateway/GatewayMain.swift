import AppKit
import Foundation
import OSLog

final class GatewayService: NSObject, NSXPCListenerDelegate, GatewayXPCProtocol, @unchecked Sendable {
    private let handler: GatewayRequestHandler

    init(engine: GatewayEngine, supervisor: WorkerSupervisor) {
        handler = GatewayRequestHandler(engine: engine, workerStatus: { [supervisor] in
            WorkerStatus(await supervisor.state)
        })
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: GatewayXPCProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func send(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let handler = handler
        Task { reply(await handler.handle(request)) }
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
        let engine = GatewayEngine(
            store: GatewayStateStore(directory: GatewayPaths.supportDirectory),
            job: NewsDigestJob(
                fetcher: URLSessionNewsFetcher(),
                summarizer: WorkerDigestSummarizer(worker: supervisor, locator: ModelStoreLocator()),
                publisher: PagesPublisher()
            )
        )
        let service = GatewayService(engine: engine, supervisor: supervisor)
        let listener = NSXPCListener(machServiceName: GatewayConstants.machServiceName)
        listener.delegate = service
        listener.resume()
        Task { await engine.runSchedulerLoop() }
        log.info("gateway started, protocol \(GatewayConstants.protocolVersion)")
        // A run loop, not dispatchMain(): NSWorkspace delivers the wake notification through the
        // main run loop. The monitor must outlive `main`; the loop never ends, so this pins it.
        withExtendedLifetime(memoryMonitor) { RunLoop.main.run() }
    }
}
