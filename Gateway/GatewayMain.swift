import Foundation
import OSLog

final class GatewayService: NSObject, NSXPCListenerDelegate, GatewayXPCProtocol, @unchecked Sendable {
    private let handler: GatewayRequestHandler

    init(engine: GatewayEngine) {
        handler = GatewayRequestHandler(engine: engine)
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
        let engine = GatewayEngine(
            store: GatewayStateStore(directory: GatewayPaths.supportDirectory),
            job: NewsDigestJob(
                fetcher: URLSessionNewsFetcher(), summarizer: LocalModelSummarizer(),
                publisher: PagesPublisher()
            )
        )
        let service = GatewayService(engine: engine)
        let listener = NSXPCListener(machServiceName: GatewayConstants.machServiceName)
        listener.delegate = service
        listener.resume()
        Task { await engine.runSchedulerLoop() }
        log.info("gateway started, protocol \(GatewayConstants.protocolVersion)")
        dispatchMain()
    }
}
