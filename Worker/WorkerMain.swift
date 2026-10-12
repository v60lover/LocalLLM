import Foundation
import OSLog

/// Holds the process alive while a model is resident, so XPC idle-exit doesn't kill it.
struct ProcessResidencyHolder: WorkerResidencyHolding {
    func acquire() { xpc_transaction_begin() }
    func release() { xpc_transaction_end() }
}

/// NSXPCConnection proxies are thread-safe but not annotated Sendable.
struct SinkBox: @unchecked Sendable {
    let sink: any WorkerEventSinkXPC
}

/// Sends engine events to the Gateway: coalesced into ~30 ms batches, one batch in flight.
actor WorkerEventPump {
    private var queue = WorkerEventQueue()
    private var sink: SinkBox?
    private var flushing = false

    func attach(_ sink: SinkBox) {
        self.sink = sink
        scheduleFlush()
    }

    func submit(_ event: WorkerEvent) {
        queue.enqueue(event)
        scheduleFlush()
    }

    func acknowledged() {
        queue.acknowledge()
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushing, !queue.isIdle else { return }
        flushing = true
        Task {
            try? await Task.sleep(for: WorkerConstants.batchInterval)
            flush()
        }
    }

    private func flush() {
        flushing = false
        guard let sink, let batch = queue.takeBatch(),
              let data = try? WorkerWire.encoder.encode(batch) else {
            // Nothing to send, or a batch is in flight: `submit`/`acknowledged` reschedule.
            return
        }
        sink.sink.deliver(data) { [self] in Task { await acknowledged() } }
    }
}

final class WorkerService: NSObject, NSXPCListenerDelegate, WorkerXPCProtocol, @unchecked Sendable {
    private let engine: WorkerEngine
    private let pump: WorkerEventPump

    override init() {
        let pump = WorkerEventPump()
        self.pump = pump
        engine = WorkerEngine(
            loader: CoreAIModelLoader(), residency: ProcessResidencyHolder(),
            emit: { event in Task { await pump.submit(event) } }
        )
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: WorkerXPCProtocol.self)
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(with: WorkerEventSinkXPC.self)
        if let sink = connection.remoteObjectProxy as? any WorkerEventSinkXPC {
            let pump = pump
            let box = SinkBox(sink: sink)
            Task { await pump.attach(box) }
        }
        connection.resume()
        return true
    }

    func send(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let engine = engine
        Task {
            let response: WorkerReplyEnvelope
            do {
                let envelope = try WorkerWire.decoder.decode(WorkerRequestEnvelope.self, from: request)
                response = await engine.handle(envelope)
            } catch {
                response = WorkerReplyEnvelope(reply: .failure(WorkerFailure(
                    kind: .malformedRequest, message: "Could not parse the worker request."
                )))
            }
            reply((try? WorkerWire.encoder.encode(response)) ?? Data())
        }
    }
}

@main
struct WorkerMain {
    static func main() {
        let service = WorkerService()
        let listener = NSXPCListener.service()
        listener.delegate = service
        listener.resume()
    }
}
