import Foundation
import FoundationModels
import XCTest
@testable import LocalLLMChat

private func turn(_ prompt: String, _ answer: String) -> [Transcript.Entry] {
    [
        .prompt(.init(segments: [.text(.init(content: prompt))])),
        .response(.init(assetIDs: [], segments: [.text(.init(content: answer))]))
    ]
}

private func instructions() -> Transcript.Entry {
    .instructions(.init(segments: [.text(.init(content: "be brief"))], toolDefinitions: []))
}

/// Scripted replies shared by every runtime a store creates, so rebuilds keep consuming the script.
@MainActor
private final class Script {
    enum Step {
        case reply(String, usedTokens: Int)
        case fail(any Error)
        case hang
    }

    var steps: [Step] = []
    var prompts: [String] = []
    var runtimeTranscripts: [Transcript?] = []
}

@MainActor
private final class FakeRuntime: ChatRuntime {
    let supportsTools = false
    let responseTokenBudget = 100
    private(set) var transcript: Transcript
    private let script: Script

    init(transcript: Transcript?, script: Script) {
        self.transcript = transcript ?? Transcript(entries: [instructions()])
        self.script = script
    }

    func generate(
        prompt: String, onSnapshot: @MainActor (String, Int) -> Void
    ) async throws -> GenerationOutcome {
        script.prompts.append(prompt)
        guard !script.steps.isEmpty else { throw TestFailure.unscripted }
        switch script.steps.removeFirst() {
        case .reply(let text, let used):
            onSnapshot(text, used)
            transcript = Transcript(entries: Array(transcript) + turn(prompt, text))
            return GenerationOutcome(text: text, transcript: transcript, usedTokens: used)
        case .fail(let error):
            throw error
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
    }
}

private enum TestFailure: LocalizedError {
    case unscripted, boom
    var errorDescription: String? { self == .boom ? "boom" : "unscripted" }
}

@MainActor
private struct FakeHandle: ChatModelHandle {
    let contextSize: Int?
    let script: Script

    func makeRuntime(
        transcript: Transcript?, report: @escaping @Sendable (ToolEvent) async -> Void
    ) -> any ChatRuntime {
        script.runtimeTranscripts.append(transcript)
        return FakeRuntime(transcript: transcript, script: script)
    }
}

@MainActor
private final class FakeBackend: ChatBackend {
    let script = Script()
    var contextSize: Int? = 1000
    var loadError: (any Error)?
    let options = [
        ChatModelOption(id: "a", name: "Model A", source: nil),
        ChatModelOption(id: "b", name: "Model B", source: nil)
    ]

    func loadCatalog() async -> [ChatModelOption] { options }
    func cachedModelIDs(among options: [ChatModelOption]) -> Set<String> { ["a", "b"] }
    func load(
        _ option: ChatModelOption, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> any ChatModelHandle {
        if let loadError { throw loadError }
        return FakeHandle(contextSize: contextSize, script: script)
    }
}

@MainActor
final class ChatStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(_ backend: FakeBackend) async -> ChatStore {
        let store = ChatStore(
            repository: ConversationRepository(directory: directory), backend: backend
        )
        await store.loadCatalog()
        await settle { store.isModelReady }
        return store
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func send(_ text: String, to store: ChatStore) async {
        store.send(text)
        await settle { !store.isGenerating }
        await store.flushPersistence()
    }

    func testFailedReplyDoesNotBlockChatAndLeavesNoEmptyBubble() async {
        let backend = FakeBackend()
        let store = await makeStore(backend)
        backend.script.steps = [.fail(TestFailure.boom), .reply("fine", usedTokens: 10)]

        await send("first", to: store)

        XCTAssertTrue(store.isModelReady)
        XCTAssertEqual(store.generation, .failed("boom"))
        XCTAssertTrue(store.canSend)
        XCTAssertEqual(store.messages.map(\.role), [.user])

        await send("second", to: store)

        XCTAssertEqual(store.generation, .idle)
        XCTAssertEqual(store.messages.map(\.text), ["first", "second", "fine"])
    }

    func testFailedReplyRollsTranscriptBackToBeforeThePrompt() async {
        let backend = FakeBackend()
        let store = await makeStore(backend)
        backend.script.steps = [.reply("one", usedTokens: 10), .fail(TestFailure.boom)]
        await send("first", to: store)
        let before = store.conversations[0].transcript

        await send("second", to: store)

        XCTAssertEqual(store.conversations[0].transcript, before)
        XCTAssertEqual(backend.script.runtimeTranscripts.last ?? nil, before)
    }

    func testStopCancelsAndReturnsToIdle() async {
        let backend = FakeBackend()
        let store = await makeStore(backend)
        backend.script.steps = [.hang]

        store.send("hello")
        await settle { store.isGenerating }
        XCTAssertFalse(store.canSend)
        store.stop()
        await settle { !store.isGenerating }

        XCTAssertEqual(store.generation, .idle)
        XCTAssertTrue(store.canSend)
    }

    func testContextOverflowDropsOlderTurnsAndRetries() async {
        let backend = FakeBackend()
        let store = await makeStore(backend)
        backend.script.steps = [
            .reply("1", usedTokens: 10), .reply("2", usedTokens: 20),
            .fail(ChatRuntimeError.contextOverflow), .reply("3", usedTokens: 15)
        ]
        await send("a", to: store)
        await send("b", to: store)

        await send("c", to: store)

        XCTAssertEqual(store.generation, .idle)
        XCTAssertEqual(store.messages.map(\.text), ["a", "1", "b", "2", "c", "3"])
        XCTAssertEqual(store.conversations[0].droppedTurns, 1)
        XCTAssertEqual(TranscriptTrimmer.turnCount(in: store.conversations[0].transcript!), 2)
        XCTAssertTrue(store.contextLabel?.contains("trimmed") == true)
    }

    func testNearlyFullContextIsTrimmedBeforeSending() async {
        let backend = FakeBackend()
        let store = await makeStore(backend)
        backend.script.steps = [.reply("1", usedTokens: 900), .reply("2", usedTokens: 100)]
        await send("a", to: store)

        await send("b", to: store)

        XCTAssertEqual(store.conversations[0].droppedTurns, 1)
        XCTAssertEqual(store.generation, .idle)
    }

    func testOverflowWithNothingToDropFailsWithHint() async {
        let backend = FakeBackend()
        let store = await makeStore(backend)
        backend.script.steps = [.fail(ChatRuntimeError.contextOverflow)]

        await send("huge", to: store)

        XCTAssertEqual(store.generation, .failed(ChatRuntimeError.contextOverflow.localizedDescription))
        XCTAssertTrue(store.canSend)
    }

    func testModelLoadFailureIsReportedAndRecoverable() async {
        let backend = FakeBackend()
        backend.loadError = TestFailure.boom
        let store = ChatStore(
            repository: ConversationRepository(directory: directory), backend: backend
        )
        await store.loadCatalog()
        await settle { store.modelState != .loading }
        XCTAssertEqual(store.modelState, .failed("boom"))

        backend.loadError = nil
        store.loadModel()
        await settle { store.isModelReady }
        XCTAssertTrue(store.canSend)
    }

    func testSwitchingModelWhileIdleKeepsGenerationClean() async {
        let backend = FakeBackend()
        let store = await makeStore(backend)
        backend.script.steps = [.fail(TestFailure.boom)]
        await send("x", to: store)

        store.selectModel("b")
        await settle { store.isModelReady }

        XCTAssertEqual(store.generation, .idle)
        XCTAssertEqual(store.selectedModelID, "b")
    }

    func testUnreadableHistoryIsKeptAndNotOverwritten() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("conversations.json")
        try Data("{ broken".utf8).write(to: file)
        let backend = FakeBackend()
        let store = await makeStore(backend)
        backend.script.steps = [.reply("ok", usedTokens: 5)]

        await send("hi", to: store)

        XCTAssertNotNil(store.restoreNotice)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let backup = try XCTUnwrap(names.first { $0.hasPrefix("conversations.corrupt-") })
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: directory.appendingPathComponent(backup)), as: UTF8.self),
            "{ broken"
        )
        XCTAssertEqual(store.messages.map(\.text), ["hi", "ok"])
    }
}

final class TranscriptTrimmerTests: XCTestCase {
    func testDropsOlderHalfOfTurnsAndKeepsInstructions() {
        let transcript = Transcript(entries:
            [instructions()] + turn("1", "a") + turn("2", "b") + turn("3", "c")
        )

        let result = TranscriptTrimmer.dropOldestHalf(of: transcript)

        XCTAssertEqual(result.droppedTurns, 2)
        XCTAssertEqual(TranscriptTrimmer.turnCount(in: result.transcript), 1)
        XCTAssertEqual(result.transcript.count, 3)
        guard case .instructions = result.transcript[0] else { return XCTFail("instructions lost") }
    }

    func testNothingToDropWithoutTurns() {
        let transcript = Transcript(entries: [instructions()])

        XCTAssertEqual(TranscriptTrimmer.dropOldestHalf(of: transcript).droppedTurns, 0)
    }
}
