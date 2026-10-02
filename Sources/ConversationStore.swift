import Foundation
import FoundationModels

struct ChatConversation: Codable, Identifiable, Sendable {
    let id: UUID
    let modelID: String
    var title: String
    var messages: [ChatMessage]
    var transcript: Transcript?
    var usedTokens: Int?
    /// How many of the oldest turns were forgotten by the model to make room (the chat still shows them).
    var droppedTurns: Int?

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

enum ConversationRepositoryError: LocalizedError {
    /// The history file exists but cannot be decoded. It was set aside (not overwritten).
    case unreadable(backup: String?, reason: String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let backup?, let reason):
            "Saved conversations could not be read (\(reason)). The file was kept as “\(backup)”; starting with a new conversation."
        case .unreadable(nil, let reason):
            "Saved conversations could not be read (\(reason)) and could not be backed up, so new ones will not be saved."
        }
    }
}

actor ConversationRepository {
    let directory: URL
    private let fileURL: URL
    private var latestRevision = -1
    /// Set when an unreadable file could not be moved aside; saving would destroy it.
    private var isWriteProtected = false

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("LocalLLMChat", isDirectory: true)
        self.directory = base
        fileURL = base.appendingPathComponent("conversations.json")
    }

    func load() throws -> SavedChatState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        do {
            return try JSONDecoder().decode(SavedChatState.self, from: data)
        } catch {
            let backup = FileQuarantine.moveAside(fileURL)
            isWriteProtected = backup == nil
            throw ConversationRepositoryError.unreadable(
                backup: backup?.lastPathComponent, reason: error.localizedDescription
            )
        }
    }

    func save(_ state: SavedChatState, revision: Int) throws {
        guard revision > latestRevision, !isWriteProtected else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: .atomic)
        latestRevision = revision
    }
}
