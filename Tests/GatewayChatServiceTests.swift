import Foundation
import XCTest
@testable import LocalLLMChat

#if os(macOS)
// Tests for the Gateway's half of chat: `GatewayChatService` on its own, then
// `chatGenerate` / `chatCancel` through the real `GatewayRequestHandler`. The worker, the model
// locator and the connection's event queue are fakes, so nothing here loads a model or opens
// XPC; the real path is only covered by the opt-in live smoke test.

/// Stands in for `WorkerSupervisor`: records every job and runs a scripted behavior that can
/// stream deltas, return, throw, or hang until cancelled.
private final class ChatStubWorker: ChatWorkerRunning, @unchecked Sendable {
    typealias Behavior = @Sendable (WorkerJob, @Sendable (String) -> Void) async throws -> WorkerJobResult

    private let lock = NSLock()
    private var _jobs: [WorkerJob] = []
    private var _log: [String] = []
    private var _cancelled = 0
    private let behavior: Behavior

    init(_ behavior: @escaping Behavior = ChatStubWorker.reply) { self.behavior = behavior }

    /// Streams "Hel" and "lo", then finishes with a transcript and a token count.
    static let reply: Behavior = { _, emit in
        emit("Hel")
        emit("lo")
        return WorkerJobResult(text: "Hello", transcript: Data("T".utf8), usedTokens: 9)
    }

    /// A generation that never ends on its own: it models a worker mid-inference and only
    /// finishes when the service cancels it (the sleep throws on cancellation).
    static let hang: Behavior = { _, _ in
        try await Task.sleep(for: .seconds(3600))
        return WorkerJobResult(text: "", transcript: Data(), usedTokens: 0)
    }

    var jobs: [WorkerJob] { lock.withLock { _jobs } }
    /// "leaveSafeMode" and "generate" in the order they were called.
    var log: [String] { lock.withLock { _log } }
    /// How many generations ended by cancellation.
    var cancelledCount: Int { lock.withLock { _cancelled } }

    func generate(
        _ job: WorkerJob, onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> WorkerJobResult {
        lock.withLock {
            _jobs.append(job)
            _log.append("generate")
        }
        do {
            return try await behavior(job, onDelta)
        } catch {
            if error is CancellationError { lock.withLock { _cancelled += 1 } }
            throw error
        }
    }

    func leaveSafeMode() async { lock.withLock { _log.append("leaveSafeMode") } }
}

private struct ChatStubLocator: ModelLocating {
    var path: String? = "/models/qwen"
    func localPath(for model: ModelReference) -> String? { path }
}

/// The publisher's side of one or more connections: records what was accepted per connection
/// and refuses connections that are marked gone, like `GatewayEventPublisher.send(chat:to:)`.
private final class RecordingEvents: ChatEventSending, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [(event: GatewayEvent, connection: UUID)] = []
    private var gone: Set<UUID> = []
    private var acceptLimit: Int?

    /// Refuses every connection from now on that is in `connections`.
    func markGone(_ connection: UUID) { lock.withLock { _ = gone.insert(connection) } }
    /// Accepts only this many events in total, then behaves as if every connection left.
    func acceptOnly(_ count: Int) { lock.withLock { acceptLimit = count } }

    func events(for connection: UUID) -> [GatewayEvent] {
        lock.withLock { _sent.filter { $0.connection == connection }.map(\.event) }
    }

    func send(chat event: GatewayEvent, to connection: UUID) async -> Bool {
        lock.withLock {
            if gone.contains(connection) { return false }
            if let acceptLimit, _sent.count >= acceptLimit { return false }
            _sent.append((event, connection))
            return true
        }
    }
}

/// Polls until `condition` holds, with a generous ceiling; the only waiting these tests do.
private func settle(_ message: String, _ condition: () async -> Bool) async throws {
    for _ in 0..<1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    let holds = await condition()
    XCTAssertTrue(holds, message)
}

/// A latch for a fake worker to wait at. Deliberately ignores task cancellation, so a test
/// decides when the worker proceeds and can inspect what the cancellation did meanwhile.
private final class ChatGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let passes = lock.withLock { () -> Bool in
                if !opened { waiters.append(continuation) }
                return opened
            }
            if passes { continuation.resume() }
        }
    }

    func open() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in released { waiter.resume() }
    }
}

private func request(
    prompt: String = "hi", transcript: Data? = nil, instructions: String? = nil, maxTokens: Int? = nil
) -> ChatGenerateRequest {
    ChatGenerateRequest(
        model: testModel, prompt: prompt, instructions: instructions, transcript: transcript,
        maximumResponseTokens: maxTokens
    )
}

private func terminalCount(_ events: [GatewayEvent]) -> Int {
    events.filter {
        switch $0 {
        case .chatFinished, .chatFailed: true
        default: false
        }
    }.count
}

final class GatewayChatServiceTests: XCTestCase {
    private func makeService(
        _ worker: ChatStubWorker = ChatStubWorker(), locator: ChatStubLocator = ChatStubLocator(),
        events: RecordingEvents = RecordingEvents()
    ) -> (GatewayChatService, RecordingEvents) {
        (GatewayChatService(worker: worker, locator: locator, events: events), events)
    }

    // MARK: Output

    /// The app renders what arrives in order and treats the terminal event as the end. The
    /// deltas must precede it, appear in the order produced, and not repeat the reply so far.
    func testDeltasArriveInOrderFollowedByExactlyOneFinishedEvent() async throws {
        let worker = ChatStubWorker()
        let (service, events) = makeService(worker)
        let id = UUID(), connection = UUID()

        let refusal = await service.start(request(), id: id, connection: connection)
        XCTAssertNil(refusal)
        try await settle("the generation ended") { await service.activeCount == 0 }

        XCTAssertEqual(events.events(for: connection), [
            .chatDelta(requestID: id, text: "Hel", usedTokens: nil),
            .chatDelta(requestID: id, text: "lo", usedTokens: nil),
            .chatFinished(requestID: id, transcript: Data("T".utf8), usedTokens: 9),
        ])
    }

    /// The worker keeps no conversation, so the job must carry everything: the located path, the
    /// prompt, the transcript, the token limit. Instructions are sent only for a conversation
    /// that has no transcript yet, because a transcript already holds them. The worker is told to
    /// leave safe mode before the job, never after.
    func testTheJobCarriesTheTranscriptAndTheInstructionsOnlyForANewConversation() async throws {
        let worker = ChatStubWorker()
        let (service, _) = makeService(worker)
        let transcript = Data("history".utf8)

        _ = await service.start(
            request(prompt: "next", transcript: transcript, instructions: "be brief", maxTokens: 300),
            id: UUID(), connection: UUID()
        )
        _ = await service.start(
            request(prompt: "first", instructions: "be brief"), id: UUID(), connection: UUID()
        )
        try await settle("both jobs ran") { await service.activeCount == 0 }

        let continued = try XCTUnwrap(worker.jobs.first { $0.prompt == "next" })
        XCTAssertEqual(continued.model, .path("/models/qwen"))
        XCTAssertEqual(continued.transcript, transcript)
        XCTAssertNil(continued.instructions, "a transcript already holds the instructions")
        XCTAssertEqual(continued.options.maximumResponseTokens, 300)
        let fresh = try XCTUnwrap(worker.jobs.first { $0.prompt == "first" })
        XCTAssertNil(fresh.transcript)
        XCTAssertEqual(fresh.instructions, "be brief")
        XCTAssertEqual(
            worker.log.filter { $0 == "leaveSafeMode" || $0 == "generate" }.prefix(2).map { $0 },
            ["leaveSafeMode", "generate"], "safe mode is left before the job, not after"
        )
    }

    // MARK: Failures

    /// A model that is not on disk is refused up front with its own kind, so the app can offer
    /// the download; nothing reaches the worker and nothing stays registered.
    func testAModelThatIsNotDownloadedIsRefusedBeforeTheWorkerIsAsked() async {
        let worker = ChatStubWorker()
        let (service, events) = makeService(worker, locator: ChatStubLocator(path: nil))
        let connection = UUID()

        let refusal = await service.start(request(), id: UUID(), connection: connection)

        XCTAssertEqual(refusal?.kind, .modelNotDownloaded)
        XCTAssertTrue(worker.jobs.isEmpty)
        let active = await service.activeCount
        XCTAssertEqual(active, 0)
        XCTAssertTrue(events.events(for: connection).isEmpty)
    }

    /// Each supervisor error is mapped to the kind the app reacts to differently. This is the
    /// whole table, so a new `WorkerSupervisorError` that falls into `internalError` by accident
    /// shows up as a change here.
    func testWorkerErrorsAreMappedToTheKindsTheAppActsOn() {
        func kind(_ error: any Error) -> GatewayFailureKind { GatewayChatService.failure(for: error).kind }
        func worker(_ kind: WorkerFailureKind) -> WorkerSupervisorError {
            .worker(WorkerFailure(kind: kind, message: "m"))
        }
        XCTAssertEqual(kind(CancellationError()), .cancelled)
        XCTAssertEqual(kind(worker(.cancelled)), .cancelled)
        XCTAssertEqual(kind(worker(.contextOverflow)), .contextOverflow)
        XCTAssertEqual(kind(worker(.modelLoadFailed)), .workerUnavailable)
        XCTAssertEqual(kind(worker(.modelNotLoaded)), .workerUnavailable)
        XCTAssertEqual(kind(worker(.internalError)), .internalError)
        XCTAssertEqual(kind(WorkerSupervisorError.memoryPressure), .memoryPressure)
        XCTAssertEqual(kind(WorkerSupervisorError.loadTimedOut), .workerUnavailable)
        XCTAssertEqual(kind(WorkerSupervisorError.safeMode), .workerUnavailable)
        XCTAssertEqual(kind(WorkerSupervisorError.interrupted(.crashed, deliveredOutput: true)), .workerUnavailable)
        XCTAssertEqual(kind(WorkerSupervisorError.interrupted(.unresponsive, deliveredOutput: false)), .workerUnavailable)
        XCTAssertEqual(kind(URLError(.badURL)), .internalError)
    }

    /// The mapping is wired to what the app receives: a context overflow from the worker reaches
    /// the connection as `chatFailed(.contextOverflow)` after the deltas already streamed, which
    /// is what makes the app trim and retry.
    func testAnOverflowAfterSomeOutputEndsTheReplyWithTheOverflowKind() async throws {
        let worker = ChatStubWorker { _, emit in
            emit("partial")
            throw WorkerSupervisorError.worker(WorkerFailure(kind: .contextOverflow, message: "full"))
        }
        let (service, events) = makeService(worker)
        let id = UUID(), connection = UUID()

        _ = await service.start(request(), id: id, connection: connection)
        try await settle("ended") { await service.activeCount == 0 }

        XCTAssertEqual(events.events(for: connection), [
            .chatDelta(requestID: id, text: "partial", usedTokens: nil),
            .chatFailed(requestID: id, failure: GatewayFailure(kind: .contextOverflow, message: "full")),
        ])
    }

    // MARK: Cancellation

    /// Stop is a stop, not an error: the generation is cancelled, the worker sees the
    /// cancellation, and the connection gets one `cancelled` terminal event.
    func testCancelEndsTheGenerationWithACancelledEventAndNoError() async throws {
        let worker = ChatStubWorker(ChatStubWorker.hang)
        let (service, events) = makeService(worker)
        let id = UUID(), connection = UUID()
        _ = await service.start(request(), id: id, connection: connection)
        try await settle("the worker is generating") { worker.jobs.count == 1 }

        await service.cancel(id, connection: connection)
        try await settle("ended") { await service.activeCount == 0 }

        let received = events.events(for: connection)
        XCTAssertEqual(terminalCount(received), 1)
        guard case .chatFailed(_, let failure)? = received.last else { return XCTFail("no terminal event") }
        XCTAssertEqual(failure.kind, .cancelled)
        XCTAssertEqual(worker.cancelledCount, 1, "the worker was asked to stop, not abandoned")
    }

    /// A connection can stop only what it started. The worker waits at a gate that ignores
    /// cancellation and then checks whether it was cancelled, so the outcome tells whether the
    /// stranger's cancel reached it: the cancel is processed before the gate opens, and a
    /// wrongly honored one would turn the reply into `cancelled`. Asserting right after the
    /// cancel would pass either way, because a cancelled task unwinds asynchronously.
    func testAnotherConnectionCannotCancelAGeneration() async throws {
        let gate = ChatGate()
        let worker = ChatStubWorker { _, _ in
            await gate.wait()
            try Task.checkCancellation()
            return WorkerJobResult(text: "ok", transcript: Data("T".utf8), usedTokens: 1)
        }
        let (service, events) = makeService(worker)
        let id = UUID(), owner = UUID(), stranger = UUID()
        _ = await service.start(request(), id: id, connection: owner)
        try await settle("the worker is waiting") { worker.jobs.count == 1 }

        await service.cancel(id, connection: stranger)
        gate.open()
        try await settle("ended") { await service.activeCount == 0 }

        guard case .chatFinished? = events.events(for: owner).last else {
            return XCTFail("the stranger's cancel was honored: \(events.events(for: owner))")
        }
        XCTAssertEqual(worker.cancelledCount, 0)
    }

    /// An app that vanishes takes its generations with it, and only its own: another
    /// connection's reply keeps running. Nothing is sent to the closed connection.
    func testClosingAConnectionCancelsItsGenerationsAndLeavesOthersAlone() async throws {
        let worker = ChatStubWorker(ChatStubWorker.hang)
        let (service, events) = makeService(worker)
        let closing = UUID(), staying = UUID()
        _ = await service.start(request(prompt: "a"), id: UUID(), connection: closing)
        _ = await service.start(request(prompt: "b"), id: UUID(), connection: staying)
        try await settle("both are generating") { worker.jobs.count == 2 }

        // The publisher stops accepting for a connection before the service is told it closed.
        events.markGone(closing)
        await service.connectionClosed(closing)
        try await settle("the closed connection's generation ended") { worker.cancelledCount == 1 }

        let remaining = await service.activeCount
        XCTAssertEqual(remaining, 1, "the other connection's generation is untouched")
        XCTAssertTrue(events.events(for: closing).isEmpty)
        XCTAssertTrue(events.events(for: staying).isEmpty, "still generating, nothing terminal yet")
        await service.connectionClosed(staying)
        try await settle("cleaned up") { await service.activeCount == 0 }
    }

    /// Output nobody can receive must not keep a model busy: when the publisher stops accepting
    /// events mid-reply (the app was dropped for a missed ack), the generation is cancelled and
    /// no terminal event is attempted.
    func testAnUndeliverableDeltaStopsTheGeneration() async throws {
        let worker = ChatStubWorker { _, emit in
            emit("a")
            // Keeps going until the service cancels: a model that has more to say.
            try await Task.sleep(for: .seconds(3600))
            return WorkerJobResult(text: "", transcript: Data(), usedTokens: 0)
        }
        let events = RecordingEvents()
        events.acceptOnly(0)
        let (service, _) = makeService(worker, events: events)
        let connection = UUID()

        _ = await service.start(request(), id: UUID(), connection: connection)
        try await settle("the worker was cancelled") { worker.cancelledCount == 1 }
        try await settle("ended") { await service.activeCount == 0 }
        XCTAssertTrue(events.events(for: connection).isEmpty)
    }

    // MARK: Bounds and duplicates

    /// One connection cannot queue without bound, another is not affected, and a repeated ID is
    /// not started twice.
    func testAConnectionIsLimitedAndADuplicateIDIsRefused() async throws {
        let worker = ChatStubWorker(ChatStubWorker.hang)
        let (service, _) = makeService(worker)
        let connection = UUID()
        var ids: [UUID] = []
        for _ in 0..<GatewayChatService.maxActivePerConnection {
            let id = UUID()
            ids.append(id)
            let refusal = await service.start(request(), id: id, connection: connection)
            XCTAssertNil(refusal)
        }

        let over = await service.start(request(), id: UUID(), connection: connection)
        XCTAssertEqual(over?.kind, .alreadyRunning)
        let duplicate = await service.start(request(), id: ids[0], connection: UUID())
        XCTAssertEqual(duplicate?.kind, .requestInProgress)
        let other = await service.start(request(), id: UUID(), connection: UUID())
        XCTAssertNil(other, "another connection has its own allowance")

        await service.connectionClosed(connection)
    }
}

/// `chatGenerate` and `chatCancel` through the real handler, as the XPC service calls it.
final class GatewayChatHandlerTests: XCTestCase {
    private var directory: URL!

    override func setUp() { directory = makeTemporaryDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func makeHandler(
        chat: GatewayChatService?
    ) -> GatewayRequestHandler {
        let engine = GatewayEngine(
            store: GatewayStateStore(directory: directory), job: StubJob(),
            clock: FakeClock(testDate(2026, 10, 2, 6))
        )
        return GatewayRequestHandler(engine: engine, chat: chat)
    }

    private func call(
        _ handler: GatewayRequestHandler, _ request: GatewayRequest, id: UUID = UUID(),
        on connection: GatewayConnectionContext
    ) async throws -> GatewayReply {
        let data = try GatewayWire.encoder.encode(GatewayRequestEnvelope(requestID: id, request: request))
        let reply = await handler.handle(data, connection: connection)
        return try GatewayWire.decoder.decode(GatewayReplyEnvelope.self, from: reply).reply
    }

    private func greeted(_ handler: GatewayRequestHandler, id: UUID = UUID()) async throws -> GatewayConnectionContext {
        let connection = GatewayConnectionContext(id: id)
        _ = try await call(handler, .hello(version: GatewayConstants.protocolVersion), on: connection)
        return connection
    }

    /// The reply comes back as soon as the generation is running, before it produces anything,
    /// and the output then reaches the connection that asked, tagged with the request's ID.
    func testChatGenerateIsAcceptedAtOnceAndItsOutputFollowsToTheAskingConnection() async throws {
        let worker = ChatStubWorker()
        let events = RecordingEvents()
        let service = GatewayChatService(worker: worker, locator: ChatStubLocator(), events: events)
        let handler = makeHandler(chat: service)
        let connectionID = UUID()
        let connection = try await greeted(handler, id: connectionID)
        let id = UUID()

        let reply = try await call(handler, .chatGenerate(request()), id: id, on: connection)

        XCTAssertEqual(reply, .accepted)
        try await settle("finished") { await service.activeCount == 0 }
        guard case .chatFinished(let finishedID, _, _)? = events.events(for: connectionID).last else {
            return XCTFail("no finished event")
        }
        XCTAssertEqual(finishedID, id, "the request ID names the generation")
    }

    /// A client that lost the reply and repeats the request must not start a second generation:
    /// the ledger answers the duplicate with the stored reply.
    func testARepeatedChatGenerateDoesNotStartASecondGeneration() async throws {
        let worker = ChatStubWorker()
        let service = GatewayChatService(worker: worker, locator: ChatStubLocator(), events: RecordingEvents())
        let handler = makeHandler(chat: service)
        let connection = try await greeted(handler)
        let id = UUID()

        let first = try await call(handler, .chatGenerate(request()), id: id, on: connection)
        let second = try await call(handler, .chatGenerate(request()), id: id, on: connection)

        XCTAssertEqual(first, .accepted)
        XCTAssertEqual(second, .accepted)
        try await settle("finished") { await service.activeCount == 0 }
        XCTAssertEqual(worker.jobs.count, 1)
    }

    /// A refusal is a typed failure in the reply, not an event that never comes.
    func testARefusedChatGenerateIsATypedFailureInTheReply() async throws {
        let service = GatewayChatService(
            worker: ChatStubWorker(), locator: ChatStubLocator(path: nil), events: RecordingEvents()
        )
        let handler = makeHandler(chat: service)
        let connection = try await greeted(handler)

        let reply = try await call(handler, .chatGenerate(request()), on: connection)

        guard case .failure(let failure) = reply else { return XCTFail("expected a failure, got \(reply)") }
        XCTAssertEqual(failure.kind, .modelNotDownloaded)
    }

    /// `chatCancel` stops the generation of the connection it arrives on, and is accepted
    /// (not refused) when the target no longer exists.
    func testChatCancelStopsTheGenerationAndIsAcceptedForAnUnknownTarget() async throws {
        let worker = ChatStubWorker(ChatStubWorker.hang)
        let events = RecordingEvents()
        let service = GatewayChatService(worker: worker, locator: ChatStubLocator(), events: events)
        let handler = makeHandler(chat: service)
        let connectionID = UUID()
        let connection = try await greeted(handler, id: connectionID)
        let id = UUID()
        _ = try await call(handler, .chatGenerate(request()), id: id, on: connection)
        try await settle("generating") { worker.jobs.count == 1 }

        let cancel = try await call(handler, .chatCancel(target: id), on: connection)
        let unknown = try await call(handler, .chatCancel(target: UUID()), on: connection)

        XCTAssertEqual(cancel, .accepted)
        XCTAssertEqual(unknown, .accepted)
        try await settle("ended") { await service.activeCount == 0 }
        guard case .chatFailed(_, let failure)? = events.events(for: connectionID).last else {
            return XCTFail("no terminal event")
        }
        XCTAssertEqual(failure.kind, .cancelled)
    }

    /// A handler built without a chat service (the digest-only wiring) refuses chat with a typed
    /// failure instead of dropping the request.
    func testAHandlerWithoutAChatServiceRefusesChatRequests() async throws {
        let handler = makeHandler(chat: nil)
        let connection = try await greeted(handler)

        let reply = try await call(handler, .chatGenerate(request()), on: connection)

        guard case .failure(let failure) = reply else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.kind, .internalError)
    }
}
#endif
