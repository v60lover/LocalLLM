import Foundation
import FoundationModels
import XCTest
@testable import LocalLLMChat

final class ConversationRepositoryTests: XCTestCase {
    func testSaveAndLoadRoundTripsSelectionConversationsAndMessages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ConversationRepository(directory: directory)

        var first = ChatConversation(modelID: "model-a")
        first.title = "First conversation"
        first.messages = [
            ChatMessage(role: .user, text: "Hello"),
            ChatMessage(role: .assistant, text: "Hi")
        ]
        first.usedTokens = 17
        first.transcript = Transcript(entries: [
            .prompt(.init(segments: [.text(.init(content: "Hello"))]))
        ])
        let second = ChatConversation(modelID: "model-b")
        let state = SavedChatState(
            selectedModelID: "model-b",
            selectedConversationID: second.id,
            conversations: [first, second]
        )

        try await repository.save(state, revision: 4)
        let loadedOptional = try await repository.load()
        let loaded = try XCTUnwrap(loadedOptional)

        XCTAssertEqual(loaded.selectedModelID, "model-b")
        XCTAssertEqual(loaded.selectedConversationID, second.id)
        XCTAssertEqual(loaded.conversations.map(\.id), [first.id, second.id])
        XCTAssertEqual(loaded.conversations[0].modelID, "model-a")
        XCTAssertEqual(loaded.conversations[0].title, "First conversation")
        XCTAssertEqual(loaded.conversations[0].usedTokens, 17)
        XCTAssertEqual(loaded.conversations[0].messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(loaded.conversations[0].messages.map(\.text), ["Hello", "Hi"])
        XCTAssertEqual(loaded.conversations[0].transcript, first.transcript)
    }

    func testOlderRevisionDoesNotReplaceNewerSavedState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ConversationRepository(directory: directory)
        let newer = SavedChatState(selectedModelID: "new", selectedConversationID: nil, conversations: [])
        let stale = SavedChatState(selectedModelID: "stale", selectedConversationID: nil, conversations: [])

        try await repository.save(newer, revision: 8)
        try await repository.save(stale, revision: 7)

        let loaded = try await repository.load()
        XCTAssertEqual(loaded?.selectedModelID, "new")
    }

    func testEncodingOmitsTransientStreamingState() throws {
        let message = ChatMessage(
            role: .assistant,
            text: "partial response",
            isStreaming: true,
            markdownSource: ChatMarkdownSource()
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
        )
        XCTAssertNil(object["isStreaming"])
        XCTAssertNil(object["markdownSource"])
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(restored.isStreaming)
        XCTAssertNil(restored.markdownSource)
        XCTAssertEqual(restored.text, "partial response")
    }
}
