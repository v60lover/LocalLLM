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

// MARK: WorkerEngine

private struct StubModel: WorkerLoadedModel {
    var contextSize: Int? = 2048
    var session: any WorkerLanguageSession
    func makeSession(instructions: String?, transcript: Data?) throws -> any WorkerLanguageSession { session }
}

private struct StubLoader: WorkerModelLoading {
    var model: StubModel?
    func load(_ location: WorkerModelLocation) async throws -> any WorkerLoadedModel {
        guard let model else { throw WorkerFailure(kind: .modelLoadFailed, message: "nope") }
        return model
    }
}

private struct ScriptedSession: WorkerLanguageSession {
    var snapshots: [String]
    var failure: WorkerFailure?
    var hangs = false

    func respond(to prompt: String, options: WorkerGenerationOptions, onSnapshot: @Sendable (String, Int) -> Void) async throws -> WorkerSessionResult {
        for (index, text) in snapshots.enumerated() { onSnapshot(text, index + 1) }
        if hangs { try await Task.sleep(for: .seconds(30)) }
        if let failure { throw failure }
        return WorkerSessionResult(transcript: Data("t".utf8), usedTokens: snapshots.count)
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [WorkerEvent] = []
    func append(_ event: WorkerEvent) { lock.lock(); stored.append(event); lock.unlock() }
    var events: [WorkerEvent] { lock.lock(); defer { lock.unlock() }; return stored }

    func waitForTerminal(count: Int = 1) async {
        for _ in 0..<500 {
            let terminal = events.filter {
                switch $0 { case .delta: false; default: true }
            }
            if terminal.count >= count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class CountingResidency: WorkerResidencyHolding, @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (acquired: 0, released: 0)
    func acquire() { lock.lock(); counts.acquired += 1; lock.unlock() }
    func release() { lock.lock(); counts.released += 1; lock.unlock() }
    var snapshot: (acquired: Int, released: Int) { lock.lock(); defer { lock.unlock() }; return counts }
}

final class WorkerEngineTests: XCTestCase {
    private func call(_ engine: WorkerEngine, _ request: WorkerRequest) async -> WorkerReply {
        await engine.handle(WorkerRequestEnvelope(requestID: UUID(), request: request)).reply
    }

    private func readyEngine(
        _ session: ScriptedSession, log: EventLog, residency: any WorkerResidencyHolding = NoResidencyHolder()
    ) async -> (WorkerEngine, UUID) {
        let engine = WorkerEngine(
            loader: StubLoader(model: StubModel(session: session)), residency: residency, emit: { log.append($0) }
        )
        _ = await call(engine, .load(.path("/m")))
        let sessionID = UUID()
        _ = await call(engine, .openSession(sessionID: sessionID, instructions: nil, transcript: nil))
        return (engine, sessionID)
    }

    func testGenerateStreamsAppendedDeltasThenFinished() async {
        let log = EventLog()
        let (engine, session) = await readyEngine(ScriptedSession(snapshots: ["He", "Hello", "Hello!"]), log: log)
        let request = WorkerRequestEnvelope(requestID: UUID(), request: .generate(sessionID: session, prompt: "hi", options: WorkerGenerationOptions()))
        let reply = await engine.handle(request)
        XCTAssertEqual(reply.reply, .accepted)
        await log.waitForTerminal()
        let id = request.requestID
        XCTAssertEqual(log.events, [
            .delta(requestID: id, text: "He", usedTokens: 1),
            .delta(requestID: id, text: "llo", usedTokens: 2),
            .delta(requestID: id, text: "!", usedTokens: 3),
            .finished(requestID: id, transcript: Data("t".utf8), usedTokens: 3),
        ])
    }

    func testContextOverflowIsReportedAsFailedEvent() async {
        let log = EventLog()
        let overflow = WorkerFailure(kind: .contextOverflow, message: "full")
        let (engine, session) = await readyEngine(ScriptedSession(snapshots: [], failure: overflow), log: log)
        let request = WorkerRequestEnvelope(requestID: UUID(), request: .generate(sessionID: session, prompt: "x", options: WorkerGenerationOptions()))
        _ = await engine.handle(request)
        await log.waitForTerminal()
        XCTAssertEqual(log.events, [.failed(requestID: request.requestID, overflow)])
    }

    func testSecondGenerateOnBusySessionIsRejectedAndCancelStopsTheFirst() async {
        let log = EventLog()
        let (engine, session) = await readyEngine(ScriptedSession(snapshots: [], hangs: true), log: log)
        let first = WorkerRequestEnvelope(requestID: UUID(), request: .generate(sessionID: session, prompt: "a", options: WorkerGenerationOptions()))
        let firstReply = await engine.handle(first)
        XCTAssertEqual(firstReply.reply, .accepted)
        let busy = await call(engine, .generate(sessionID: session, prompt: "b", options: WorkerGenerationOptions()))
        guard case .failure(let failure) = busy else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.kind, .busy)

        _ = await call(engine, .cancel(target: first.requestID))
        await log.waitForTerminal()
        guard case .failed(let id, let cancelled)? = log.events.last else { return XCTFail("expected failed event") }
        XCTAssertEqual(id, first.requestID)
        XCTAssertEqual(cancelled.kind, .cancelled)
    }

    func testResidencyIsHeldWhileLoadedAndReleasedOnUnload() async {
        let residency = CountingResidency()
        let log = EventLog()
        let (engine, session) = await readyEngine(ScriptedSession(snapshots: []), log: log, residency: residency)
        XCTAssertEqual(residency.snapshot.acquired, 1)
        XCTAssertEqual(residency.snapshot.released, 0)
        _ = await call(engine, .unload)
        XCTAssertEqual(residency.snapshot.released, 1)
        let after = await call(engine, .generate(sessionID: session, prompt: "x", options: WorkerGenerationOptions()))
        guard case .failure(let failure) = after else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.kind, .modelNotLoaded)
    }

    func testLoadFailureAndProtocolMismatch() async {
        let engine = WorkerEngine(loader: StubLoader(model: nil), emit: { _ in })
        let load = await call(engine, .load(.path("/missing")))
        XCTAssertEqual(load, .failure(WorkerFailure(kind: .modelLoadFailed, message: "nope")))
        let hello = await call(engine, .hello(version: 99))
        guard case .failure(let failure) = hello else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.kind, .unsupportedProtocol)
    }
}
