import FoundationModels
import XCTest
@testable import LocalLLMChat

// `RemoteChatRuntime` against a fake Gateway client: what it sends, and how it turns the
// Gateway's output into snapshots, an outcome or the errors the chat store already handles.

/// A `GatewayChatControlling` the test drives: `script` runs when a generation is accepted and
/// emits what the Gateway would push for it.
private final class FakeChatGateway: GatewayChatControlling, @unchecked Sendable {
    let chatSignals: AsyncStream<GatewayChatSignal>
    private let continuation: AsyncStream<GatewayChatSignal>.Continuation
    private let lock = NSLock()
    private var _requests: [(id: UUID, request: ChatGenerateRequest)] = []
    private var _cancels: [UUID] = []
    private var script: (@Sendable (UUID, FakeChatGateway) -> Void)?
    private var refusal: GatewayFailure?
    /// While held, `generate` does not return: the request is "on the wire".
    private var held: CheckedContinuation<Void, Never>?
    private var isHolding = false
    private var _accepted: Set<UUID> = []
    private var _effectiveCancels: [UUID] = []
    /// Thrown by `connect()`; nil means the Gateway is reachable.
    var connectError: GatewayError?

    init() { (chatSignals, continuation) = AsyncStream.makeStream(of: GatewayChatSignal.self) }

    var requests: [(id: UUID, request: ChatGenerateRequest)] { lock.withLock { _requests } }
    var cancels: [UUID] { lock.withLock { _cancels } }

    func onGenerate(_ script: @escaping @Sendable (UUID, FakeChatGateway) -> Void) {
        lock.withLock { self.script = script }
    }
    /// Makes the next `generate` wait in `releaseGenerate()`.
    func holdGenerate() { lock.withLock { isHolding = true } }
    func releaseGenerate() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isHolding = false
            defer { held = nil }
            return held
        }
        waiting?.resume()
    }
    /// Cancels that arrived after the generation was accepted: the only ones the real Gateway
    /// acts on, because a cancel for a generation it does not know yet is a no-op.
    var effectiveCancels: [UUID] { lock.withLock { _effectiveCancels } }

    func refuse(with failure: GatewayFailure) { lock.withLock { refusal = failure } }
    func emit(_ signal: GatewayChatSignal) { continuation.yield(signal) }

    func generate(_ request: ChatGenerateRequest, id: UUID) async throws -> GatewayFailure? {
        let (refusal, script) = lock.withLock { () -> (GatewayFailure?, (@Sendable (UUID, FakeChatGateway) -> Void)?) in
            _requests.append((id, request))
            return (self.refusal, self.script)
        }
        if let refusal { return refusal }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                guard isHolding else { return true }
                held = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        lock.withLock { _ = _accepted.insert(id) }
        script?(id, self)
        return nil
    }

    func connect() async throws { if let connectError { throw connectError } }
    func cancel(_ id: UUID) async throws {
        lock.withLock {
            _cancels.append(id)
            if _accepted.contains(id) { _effectiveCancels.append(id) }
        }
    }
    func start() async {}
    func stop() async { continuation.finish() }
}

@MainActor
final class RemoteChatRuntimeTests: XCTestCase {
    private let finishedTranscript = (try? WorkerWire.encoder.encode(Transcript())) ?? Data()

    private func makeRuntime(
        _ gateway: FakeChatGateway, transcript: Transcript? = nil
    ) -> RemoteChatRuntime {
        RemoteChatRuntime(
            model: testModel, transcript: transcript, session: RemoteChatSession(gateway: gateway)
        )
    }

    /// Snapshots are the whole reply so far, not the pieces the Gateway sends, and the token
    /// count the UI shows survives deltas that do not carry one.
    func testDeltasBecomeCumulativeSnapshotsAndTheOutcomeCarriesTheNewTranscript() async throws {
        let gateway = FakeChatGateway()
        let transcriptData = finishedTranscript
        gateway.onGenerate { id, gateway in
            gateway.emit(.delta(requestID: id, text: "Hel", usedTokens: nil))
            gateway.emit(.delta(requestID: id, text: "lo", usedTokens: 12))
            gateway.emit(.delta(requestID: id, text: "!", usedTokens: nil))
            gateway.emit(.finished(requestID: id, transcript: transcriptData, usedTokens: 15))
        }
        let runtime = makeRuntime(gateway)
        var snapshots: [(String, Int)] = []

        let outcome = try await runtime.generate(prompt: "hi") { snapshots.append(($0, $1)) }

        XCTAssertEqual(snapshots.map(\.0), ["Hel", "Hello", "Hello!"])
        XCTAssertEqual(snapshots.map(\.1), [0, 12, 12])
        XCTAssertEqual(outcome.text, "Hello!")
        XCTAssertEqual(outcome.usedTokens, 15)
        XCTAssertEqual(gateway.requests.first?.request.prompt, "hi")
        XCTAssertNil(gateway.requests.first?.request.transcript, "a new conversation sends instructions, not a transcript")
        XCTAssertNotNil(gateway.requests.first?.request.instructions)
    }

    /// The next reply continues from what the previous one returned: the Gateway keeps no
    /// conversation, so a runtime that forgot to send it would start the chat over.
    func testTheNextReplyContinuesFromTheTranscriptTheGatewayReturned() async throws {
        let gateway = FakeChatGateway()
        let returned = finishedTranscript
        gateway.onGenerate { id, gateway in
            gateway.emit(.finished(requestID: id, transcript: returned, usedTokens: 3))
        }
        let runtime = makeRuntime(gateway)

        _ = try await runtime.generate(prompt: "one") { _, _ in }
        _ = try await runtime.generate(prompt: "two") { _, _ in }

        XCTAssertEqual(gateway.requests.count, 2)
        XCTAssertEqual(gateway.requests[1].request.transcript, returned)
    }

    /// A conversation restored from disk starts from its transcript, not from fresh instructions.
    func testAResumedConversationSendsItsTranscript() async throws {
        let gateway = FakeChatGateway()
        let returned = finishedTranscript
        gateway.onGenerate { id, gateway in
            gateway.emit(.finished(requestID: id, transcript: returned, usedTokens: 0))
        }
        let runtime = makeRuntime(gateway, transcript: Transcript())

        _ = try await runtime.generate(prompt: "again") { _, _ in }

        XCTAssertEqual(gateway.requests.first?.request.transcript, finishedTranscript)
    }

    /// Stop: the Gateway is told which generation to cancel, the call ends as a cancellation
    /// rather than an error, and the conversation stays where it was.
    func testStoppingSendsCancelForThatGenerationAndEndsAsACancellation() async throws {
        let gateway = FakeChatGateway()
        gateway.onGenerate { id, gateway in
            gateway.emit(.delta(requestID: id, text: "par", usedTokens: nil))
        }
        let runtime = makeRuntime(gateway)
        var seen = ""
        let task = Task { @MainActor in
            try await runtime.generate(prompt: "hi") { text, _ in seen = text }
        }
        try await pollUntil("first snapshot") { seen == "par" }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a stopped reply must not return an outcome")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        try await pollUntil("cancel reached the gateway") { gateway.cancels == [gateway.requests[0].id] }
    }

    /// Stop pressed while the request is still on its way. The first cancel reaches the
    /// Gateway before it knows the generation and does nothing; the runtime must ask again
    /// once the request was accepted, or the model would keep generating for nobody.
    func testAStopThatOvertakesTheRequestStillStopsTheGeneration() async throws {
        let gateway = FakeChatGateway()
        gateway.holdGenerate()
        let runtime = makeRuntime(gateway)
        let task = Task { @MainActor in try await runtime.generate(prompt: "hi") { _, _ in } }
        try await pollUntil("request on the wire") { gateway.requests.count == 1 }

        task.cancel()
        try await pollUntil("the early cancel was sent") { gateway.cancels.count == 1 }
        XCTAssertTrue(gateway.effectiveCancels.isEmpty, "precondition: it overtook the request")
        gateway.releaseGenerate()

        do {
            _ = try await task.value
            XCTFail("a stopped reply must not return an outcome")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(gateway.effectiveCancels, [gateway.requests[0].id])
    }

    /// The typed ways a generation ends badly reach the store as the errors it already
    /// handles: overflow triggers trim-and-retry, the rest show the Gateway's words.
    func testFailuresAreMappedToTheErrorsTheStoreHandles() async throws {
        let cases: [(GatewayFailure, (any Error) -> Bool)] = [
            (GatewayFailure(kind: .contextOverflow, message: "full"), { ($0 as? ChatRuntimeError) == .contextOverflow }),
            (GatewayFailure(kind: .cancelled, message: "Stopped."), { $0 is CancellationError }),
            (GatewayFailure(kind: .memoryPressure, message: "low memory"), { ($0 as? GatewayError) == .remote("low memory") }),
        ]
        for (failure, matches) in cases {
            let gateway = FakeChatGateway()
            gateway.onGenerate { id, gateway in gateway.emit(.failed(requestID: id, failure: failure)) }
            let runtime = makeRuntime(gateway)
            do {
                _ = try await runtime.generate(prompt: "hi") { _, _ in }
                XCTFail("\(failure.kind) must throw")
            } catch {
                XCTAssertTrue(matches(error), "\(failure.kind) became \(error)")
            }
            XCTAssertEqual(runtime.transcript.count, Transcript().count, "a failed reply leaves the conversation alone")
        }
    }

    /// A refusal at the door (model not downloaded) is thrown too, with the Gateway's text.
    func testARefusedRequestThrowsWithTheGatewaysMessage() async throws {
        let gateway = FakeChatGateway()
        gateway.refuse(with: GatewayFailure(kind: .modelNotDownloaded, message: "Download it first."))
        let runtime = makeRuntime(gateway)
        do {
            _ = try await runtime.generate(prompt: "hi") { _, _ in }
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? GatewayError, .remote("Download it first."))
        }
    }

    /// The connection going away mid-reply cannot be repaired, so the call fails with a
    /// typed error the store shows, and what had streamed is not kept.
    func testALostConnectionEndsTheReplyAsConnectionLost() async throws {
        let gateway = FakeChatGateway()
        gateway.onGenerate { id, gateway in
            gateway.emit(.delta(requestID: id, text: "half", usedTokens: nil))
            gateway.emit(.connectionLost)
        }
        let runtime = makeRuntime(gateway)
        do {
            _ = try await runtime.generate(prompt: "hi") { _, _ in }
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? ChatRuntimeError, .interrupted)
        }
    }

    /// Output of another generation on the same connection (a second conversation, or the
    /// tail of one that was stopped) must not leak into this reply.
    func testOutputOfAnotherGenerationIsNotMixedIn() async throws {
        let gateway = FakeChatGateway()
        let returned = finishedTranscript
        gateway.onGenerate { id, gateway in
            gateway.emit(.delta(requestID: UUID(), text: "STRANGER", usedTokens: nil))
            gateway.emit(.delta(requestID: id, text: "mine", usedTokens: nil))
            gateway.emit(.finished(requestID: id, transcript: returned, usedTokens: 1))
        }
        let runtime = makeRuntime(gateway)

        let outcome = try await runtime.generate(prompt: "hi") { _, _ in }

        XCTAssertEqual(outcome.text, "mine")
    }

    private func pollUntil(_ message: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), message)
    }
}

@MainActor
final class XPCChatBackendTests: XCTestCase {
    private let option = ChatModelOption(id: "m", name: "Model", source: nil)

    /// An unreachable Gateway is reported by `load` before anything is downloaded: an
    /// uninstalled Gateway must not cost the user a multi-gigabyte download first.
    func testAnUnreachableGatewayIsReportedBeforeTheModelIsFetched() async {
        let gateway = FakeChatGateway()
        gateway.connectError = .gatewayUnavailable("not installed")
        let backend = XPCChatBackend(gateway: gateway)
        do {
            _ = try await backend.load(option) { _ in }
            XCTFail("must throw")
        } catch {
            // The catalog was never loaded, so reaching the download step would have been
            // `modelUnavailable`; the gateway error proves the connection came first.
            XCTAssertEqual(error as? GatewayError, .gatewayUnavailable("not installed"))
        }
    }

    /// With the Gateway reachable, loading continues into the local download step.
    func testAReachableGatewayLetsLoadContinueToTheDownloadStep() async {
        let backend = XPCChatBackend(gateway: FakeChatGateway())
        do {
            _ = try await backend.load(option) { _ in }
            XCTFail("the option is not in the catalog")
        } catch {
            XCTAssertTrue(error is ChatBackendError)
        }
    }
}

// MARK: Through the store

/// A backend whose models are `RemoteChatRuntime`s on a fake Gateway: the store sees exactly
/// what it sees on macOS, with the XPC and the model replaced.
@MainActor
private final class RemoteBackend: ChatBackend {
    let gateway = FakeChatGateway()
    private lazy var session = RemoteChatSession(gateway: gateway)

    func loadCatalog() async -> [ChatModelOption] { [ChatModelOption(id: "a", name: "A", source: nil)] }
    func cachedModelIDs(among options: [ChatModelOption]) -> Set<String> { ["a"] }
    func load(
        _ option: ChatModelOption, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> any ChatModelHandle {
        RemoteHandle(session: session, contextSize: 100_000)
    }
}

@MainActor
private struct RemoteHandle: ChatModelHandle {
    let session: RemoteChatSession
    let contextSize: Int?

    func makeRuntime(
        transcript: Transcript?, report: @escaping @Sendable (ToolEvent) async -> Void
    ) -> any ChatRuntime {
        RemoteChatRuntime(model: testModel, transcript: transcript, session: session)
    }
}

/// Counts requests across the closures a test hands to the fake Gateway.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}

@MainActor
final class RemoteChatStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() { directory = makeTemporaryDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func makeStore(_ backend: RemoteBackend) async -> ChatStore {
        let store = ChatStore(repository: ConversationRepository(directory: directory), backend: backend)
        await store.loadCatalog()
        await settle { store.isModelReady }
        return store
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// A transcript of `turns` question/answer pairs, encoded the way the worker returns it.
    private func transcript(turns: Int) throws -> Data {
        var entries: [Transcript.Entry] = [
            .instructions(.init(segments: [.text(.init(content: "be brief"))], toolDefinitions: []))
        ]
        for number in 0..<turns {
            entries.append(.prompt(.init(segments: [.text(.init(content: "q\(number)"))])))
            entries.append(.response(.init(assetIDs: [], segments: [.text(.init(content: "a\(number)"))])))
        }
        return try WorkerWire.encoder.encode(Transcript(entries: entries))
    }

    /// What the user sees while a reply streams in and after it ends, with the model behind
    /// the Gateway: the answer, its token count, the saved transcript, the model still ready.
    func testAReplyStreamsIntoTheConversationAndTheTranscriptAdvances() async throws {
        let backend = RemoteBackend()
        let data = try transcript(turns: 1)
        backend.gateway.onGenerate { id, gateway in
            gateway.emit(.delta(requestID: id, text: "Hi ", usedTokens: nil))
            gateway.emit(.delta(requestID: id, text: "there", usedTokens: nil))
            gateway.emit(.finished(requestID: id, transcript: data, usedTokens: 21))
        }
        let store = await makeStore(backend)

        store.send("hello")
        await settle { !store.isGenerating }

        XCTAssertEqual(store.messages.map(\.text), ["hello", "Hi there"])
        XCTAssertEqual(store.conversations.first?.usedTokens, 21)
        XCTAssertNotNil(store.conversations.first?.transcript)
        XCTAssertNil(store.generationError)
        XCTAssertTrue(store.canSend)
    }

    /// Stop is not an error: the user sees the reply stop, no banner, and the model is
    /// still usable. The Gateway was told which generation to cancel.
    func testStopCancelsOnTheGatewayAndShowsNoError() async throws {
        let backend = RemoteBackend()
        backend.gateway.onGenerate { id, gateway in
            gateway.emit(.delta(requestID: id, text: "partial", usedTokens: nil))
        }
        let store = await makeStore(backend)
        store.send("hello")
        await settle { store.messages.last?.text == "partial" }

        store.stop()
        await settle { !store.isGenerating }

        XCTAssertNil(store.generationError)
        XCTAssertTrue(store.canSend)
        await settle { backend.gateway.cancels.count == 1 }
        XCTAssertEqual(backend.gateway.cancels, [backend.gateway.requests[0].id])
    }

    /// The Gateway going away mid-reply: the conversation is rolled back to before the reply,
    /// the user is told in words, and the model stays ready so the next Send reconnects.
    func testALostConnectionRollsTheReplyBackAndLeavesTheModelReady() async throws {
        let backend = RemoteBackend()
        backend.gateway.onGenerate { id, gateway in
            gateway.emit(.delta(requestID: id, text: "half", usedTokens: nil))
            gateway.emit(.connectionLost)
        }
        let store = await makeStore(backend)

        store.send("hello")
        await settle { !store.isGenerating }

        XCTAssertEqual(store.generationError, ChatRuntimeError.interrupted.errorDescription)
        XCTAssertNil(store.conversations.first?.transcript, "the failed reply must not advance the transcript")
        XCTAssertEqual(store.modelState, .ready)
    }

    /// A full context window is answered by dropping the older half and asking again, as it
    /// is in-process: the retry carries a shorter transcript and the user sees one reply.
    func testContextOverflowTrimsTheTranscriptAndRetries() async throws {
        let backend = RemoteBackend()
        let long = try transcript(turns: 4)
        let calls = Counter()
        backend.gateway.onGenerate { id, gateway in
            switch calls.next() {
            case 0:
                gateway.emit(.finished(requestID: id, transcript: long, usedTokens: 10))
            case 1:
                gateway.emit(.failed(requestID: id, failure: GatewayFailure(kind: .contextOverflow, message: "full")))
            default:
                gateway.emit(.delta(requestID: id, text: "ok", usedTokens: nil))
                gateway.emit(.finished(requestID: id, transcript: long, usedTokens: 5))
            }
        }
        let store = await makeStore(backend)
        store.send("first")
        await settle { !store.isGenerating }

        store.send("second")
        await settle { !store.isGenerating && backend.gateway.requests.count == 3 }

        XCTAssertNil(store.generationError)
        XCTAssertEqual(store.messages.last?.text, "ok")
        let sent = backend.gateway.requests.map { $0.request.transcript?.count }
        XCTAssertEqual(sent[1], long.count)
        let retry = try XCTUnwrap(sent[2])
        XCTAssertLessThan(retry, long.count, "the retry must carry the trimmed transcript")
        XCTAssertGreaterThan(store.conversations.first?.droppedTurns ?? 0, 0)
    }
}
