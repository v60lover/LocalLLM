import Foundation
setvbuf(stdout, nil, _IOLBF, 0)

// Manual end-to-end driver for LocalLLMWorker.xpc over the real XPC transport.
// usage: Harness [model-bundle-path] ["prompt"]
final class Sink: NSObject, WorkerEventSinkXPC {
    func deliver(_ batch: Data, ack: @escaping @Sendable () -> Void) {
        if let b = try? WorkerWire.decoder.decode(WorkerEventBatch.self, from: batch) {
            for e in b.events { print("event[\(b.sequence)]: \(e)") }
        }
        ack()
    }
}

let conn = NSXPCConnection(serviceName: WorkerConstants.serviceName)
conn.remoteObjectInterface = NSXPCInterface(with: WorkerXPCProtocol.self)
conn.exportedInterface = NSXPCInterface(with: WorkerEventSinkXPC.self)
conn.exportedObject = Sink()
conn.invalidationHandler = { print("INVALIDATED") }
conn.interruptionHandler = { print("INTERRUPTED") }
conn.resume()
let proxy = conn.remoteObjectProxyWithErrorHandler { print("xpc error: \($0)") } as! WorkerXPCProtocol

func call(_ request: WorkerRequest) -> WorkerReply? {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var out: WorkerReply?
    let data = try! WorkerWire.encoder.encode(WorkerRequestEnvelope(requestID: UUID(), request: request))
    proxy.send(data) { reply in
        out = (try? WorkerWire.decoder.decode(WorkerReplyEnvelope.self, from: reply))?.reply
        sem.signal()
    }
    if sem.wait(timeout: .now() + 15) == .timedOut { print("TIMEOUT for \(request)"); return nil }
    return out
}

let args = CommandLine.arguments
print("hello:", call(.hello(version: WorkerConstants.protocolVersion)) as Any)
print("hello v99:", call(.hello(version: 99)) as Any)
print("open without model:", call(.openSession(sessionID: UUID(), instructions: nil, transcript: nil)) as Any)
let path = args.count > 1 ? args[1] : "/nonexistent/model"
let loaded = call(.load(.path(path)))
print("load:", loaded as Any)
if case .loaded? = loaded, args.count > 1 {
    let session = UUID()
    print("open:", call(.openSession(sessionID: session, instructions: "Answer briefly.", transcript: nil)) as Any)
    print("generate:", call(.generate(sessionID: session, prompt: args.count > 2 ? args[2] : "Say hello in one sentence.",
                                      options: WorkerGenerationOptions(temperature: nil, maximumResponseTokens: Int(ProcessInfo.processInfo.environment["MAXTOK"] ?? "512")))) as Any)
    Thread.sleep(forTimeInterval: Double(ProcessInfo.processInfo.environment["WAIT"] ?? "20") ?? 20)
    print("unload:", call(.unload) as Any)
}
