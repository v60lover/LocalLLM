import Foundation
import FoundationModels

struct ChatConversation: Codable, Identifiable, Sendable {
    let id: UUID
    let modelID: String
    var title: String
    var messages: [ChatMessage]
    var transcript: Transcript?
    var usedTokens: Int?

    init(modelID: String) {
        id = UUID()
        self.modelID = modelID
        title = "New conversation"
        messages = []
        transcript = nil
        usedTokens = nil
    }
}

struct SavedChatState: Codable, Sendable {
    var selectedModelID: String
    var selectedConversationID: UUID?
    var conversations: [ChatConversation]
}

actor ConversationRepository {
    let directory: URL
    private let fileURL: URL
    private var latestRevision = -1

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("LocalLLMChat", isDirectory: true)
        self.directory = base
        fileURL = base.appendingPathComponent("conversations.json")
    }

    func load() throws -> SavedChatState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(SavedChatState.self, from: Data(contentsOf: fileURL))
    }

    func save(_ state: SavedChatState, revision: Int) throws {
        guard revision > latestRevision else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: .atomic)
        latestRevision = revision
    }
}
