import Foundation
import XCTest
@testable import LocalLLMChat

/// In-memory worker: validates the version and session ids and streams a canned reply.
actor FakeWorker: WorkerServing {
    private(set) var sessions: Set<UUID> = []
    private(set) var loaded: WorkerModelLocation?
    private(set) var cancelled: [UUID] = []
    var chunks = ["Hel", "lo", "!"]

    func handle(_ envelope: WorkerRequestEnvelope) async -> WorkerReplyEnvelope {
        func reply(_ reply: WorkerReply) -> WorkerReplyEnvelope {
            WorkerReplyEnvelope(requestID: envelope.requestID, reply: reply)
        }
        func failure(_ kind: WorkerFailureKind, _ message: String = "") -> WorkerReplyEnvelope {
            reply(.failure(WorkerFailure(kind: kind, message: message)))
        }
        guard envelope.version == WorkerConstants.protocolVersion else { return failure(.unsupportedProtocol) }
        switch envelope.request {
        case .hello: return reply(.hello(version: WorkerConstants.protocolVersion))
        case .load(let location):
            loaded = location
            return reply(.loaded(contextSize: 4096))
        case .unload:
            loaded = nil
            sessions = []
            return reply(.accepted)
        case .openSession(let id, _, _):
            guard loaded != nil else { return failure(.modelNotLoaded) }
            sessions.insert(id)
            return reply(.accepted)
        case .generate(let id, _, _):
            return sessions.contains(id) ? reply(.accepted) : failure(.unknownSession)
        case .cancel(let target):
            cancelled.append(target)
            return reply(.accepted)
        case .closeSession(let id):
            return sessions.remove(id) != nil ? reply(.accepted) : failure(.unknownSession)
        }
    }
}

final class WorkerIPCTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try WorkerWire.encoder.encode(value)
        XCTAssertEqual(try WorkerWire.decoder.decode(T.self, from: data), value, file: file, line: line)
    }

    func testEveryRequestAndEventRoundTrips() throws {
        let session = UUID(), target = UUID()
        let requests: [WorkerRequest] = [
            .hello(version: 1), .load(.path("/models/a")), .unload,
            .openSession(sessionID: session, instructions: "Be brief", transcript: Data([1, 2, 3])),
            .openSession(sessionID: session, instructions: nil, transcript: nil),
            .generate(sessionID: session, prompt: "hi", options: WorkerGenerationOptions(temperature: 0.2, maximumResponseTokens: 64)),
            .cancel(target: target), .closeSession(sessionID: session),
        ]
        for request in requests { try roundTrip(WorkerRequestEnvelope(requestID: UUID(), request: request)) }

        let id = UUID()
        let events: [WorkerEvent] = [
            .delta(requestID: id, text: "x", usedTokens: 3),
            .finished(requestID: id, transcript: Data([9]), usedTokens: 10),
            .failed(requestID: id, WorkerFailure(kind: .contextOverflow, message: "full")),
        ]
        try roundTrip(WorkerEventBatch(sequence: 4, events: events))
        try roundTrip(WorkerReplyEnvelope(requestID: id, reply: .loaded(contextSize: nil)))
    }

    func testFakeWorkerSessionLifecycleAndErrors() async {
        let worker = FakeWorker()
        let session = UUID()
        func call(_ request: WorkerRequest, version: Int = WorkerConstants.protocolVersion) async -> WorkerReply {
            let id = UUID()
            let reply = await worker.handle(WorkerRequestEnvelope(version: version, requestID: id, request: request))
            XCTAssertEqual(reply.requestID, id, "replies echo the request id")
            return reply.reply
        }
        let noModel = await call(.openSession(sessionID: session, instructions: nil, transcript: nil))
        XCTAssertEqual(noModel, .failure(WorkerFailure(kind: .modelNotLoaded, message: "")))
        let hello = await call(.hello(version: 1))
        XCTAssertEqual(hello, .hello(version: 1))
        let load = await call(.load(.path("/m")))
        XCTAssertEqual(load, .loaded(contextSize: 4096))
        let open = await call(.openSession(sessionID: session, instructions: nil, transcript: nil))
        XCTAssertEqual(open, .accepted)
        let generate = await call(.generate(sessionID: session, prompt: "p", options: WorkerGenerationOptions()))
        XCTAssertEqual(generate, .accepted)
        let close = await call(.closeSession(sessionID: session))
        XCTAssertEqual(close, .accepted)
        let after = await call(.generate(sessionID: session, prompt: "p", options: WorkerGenerationOptions()))
        XCTAssertEqual(after, .failure(WorkerFailure(kind: .unknownSession, message: "")))
        let old = await call(.unload, version: 99)
        XCTAssertEqual(old, .failure(WorkerFailure(kind: .unsupportedProtocol, message: "")))
    }

    func testQueueCoalescesDeltasPerRequestAndKeepsOrder() throws {
        let a = UUID(), b = UUID()
        var queue = WorkerEventQueue()
        queue.enqueue(.delta(requestID: a, text: "He", usedTokens: 1))
        queue.enqueue(.delta(requestID: a, text: "llo", usedTokens: 2))
        queue.enqueue(.delta(requestID: b, text: "x", usedTokens: 1))
        queue.enqueue(.finished(requestID: a, transcript: Data(), usedTokens: 2))
        let batch = try XCTUnwrap(queue.takeBatch())
        XCTAssertEqual(batch.sequence, 0)
        XCTAssertEqual(batch.events, [
            .delta(requestID: a, text: "Hello", usedTokens: 2),
            .delta(requestID: b, text: "x", usedTokens: 1),
            .finished(requestID: a, transcript: Data(), usedTokens: 2),
        ])
    }

    func testQueueAllowsOneBatchInFlightUntilAcknowledged() throws {
        let id = UUID()
        var queue = WorkerEventQueue()
        XCTAssertNil(queue.takeBatch())
        queue.enqueue(.delta(requestID: id, text: "a", usedTokens: 1))
        XCTAssertNotNil(queue.takeBatch())

        queue.enqueue(.delta(requestID: id, text: "b", usedTokens: 2))
        queue.enqueue(.delta(requestID: id, text: "c", usedTokens: 3))
        XCTAssertNil(queue.takeBatch(), "backpressure: no second batch before the ack")
        XCTAssertFalse(queue.isIdle)

        queue.acknowledge()
        let next = try XCTUnwrap(queue.takeBatch())
        XCTAssertEqual(next.sequence, 1)
        XCTAssertEqual(next.events, [.delta(requestID: id, text: "bc", usedTokens: 3)])
        queue.acknowledge()
        XCTAssertTrue(queue.isIdle)
    }

    func testQueueDiscardsCancelledRequestOnly() throws {
        let a = UUID(), b = UUID()
        var queue = WorkerEventQueue()
        queue.enqueue(.delta(requestID: a, text: "a", usedTokens: 1))
        queue.enqueue(.delta(requestID: b, text: "b", usedTokens: 1))
        queue.discard(requestID: a)
        XCTAssertEqual(try XCTUnwrap(queue.takeBatch()).events, [.delta(requestID: b, text: "b", usedTokens: 1)])
    }
}
