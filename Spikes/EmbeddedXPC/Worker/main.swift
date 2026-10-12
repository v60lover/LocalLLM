import Foundation

@objc protocol WorkerProtocol {
    func ping(_ text: String, reply: @escaping (String, Int32) -> Void)
}

final class Worker: NSObject, NSXPCListenerDelegate, WorkerProtocol {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: WorkerProtocol.self)
        c.exportedObject = self
        c.resume()
        return true
    }
    func ping(_ text: String, reply: @escaping (String, Int32) -> Void) {
        reply("worker echo: \(text)", getpid())
    }
}

let worker = Worker()
let listener = NSXPCListener.service()
listener.delegate = worker
listener.resume()
