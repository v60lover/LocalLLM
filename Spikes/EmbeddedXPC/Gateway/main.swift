import Foundation

@objc protocol WorkerProtocol {
    func ping(_ text: String, reply: @escaping (String, Int32) -> Void)
}

let service = ProcessInfo.processInfo.environment["WORKER_SERVICE"] ?? "com.example.localllmchat.worker"
let conn = NSXPCConnection(serviceName: service)
conn.remoteObjectInterface = NSXPCInterface(with: WorkerProtocol.self)
conn.invalidationHandler = { print("gateway: connection INVALIDATED") }
conn.interruptionHandler = { print("gateway: connection interrupted") }
conn.resume()

let done = DispatchSemaphore(value: 0)
let proxy = conn.remoteObjectProxyWithErrorHandler { print("gateway: error \($0)"); done.signal() } as! WorkerProtocol
proxy.ping("hello from gateway pid \(getpid())") { text, pid in
    print("gateway: reply '\(text)' from worker pid \(pid)")
    done.signal()
}
if done.wait(timeout: .now() + 10) == .timedOut { print("gateway: TIMEOUT") }
