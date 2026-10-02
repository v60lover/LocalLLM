import CoreAIKit
import Foundation
import FoundationModels
import Observation
import SwiftStreamingMarkdown

final class ChatMarkdownSource: StreamedMarkdownSource, Sendable {
    let text: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init() {
        (text, continuation) = AsyncStream.makeStream()
    }

    func update(_ snapshot: String) {
        continuation.yield(snapshot)
    }

    func finish() {
        continuation.finish()
    }
}

@available(macOS 27, *)
struct ChatMessage: Identifiable, Codable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant, tool }

    let id: UUID
    let role: Role
    var text: String
    var thinking: String
    var isStreaming = false
    var markdownSource: ChatMarkdownSource?

    init(
        id: UUID = UUID(), role: Role, text: String, thinking: String = "",
        isStreaming: Bool = false,
        markdownSource: ChatMarkdownSource? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.thinking = thinking
        self.isStreaming = isStreaming
        self.markdownSource = markdownSource
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, thinking
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(Role.self, forKey: .role)
        text = try values.decode(String.self, forKey: .text)
        thinking = try values.decodeIfPresent(String.self, forKey: .thinking) ?? ""
        isStreaming = false
        markdownSource = nil
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(role, forKey: .role)
        try values.encode(text, forKey: .text)
        try values.encode(thinking, forKey: .thinking)
    }
}

enum ContextBudget {
    static func remaining(contextSize: Int?, usedTokens: Int?) -> Int? {
        guard let contextSize, contextSize > 0, let usedTokens else { return nil }
        return max(0, contextSize - usedTokens)
    }
}

@MainActor
@Observable
@available(macOS 27, *)
final class ChatStore {
    enum Phase: Equatable {
        case idle, downloading(Double), loading, ready, generating
        case failed(String)

        var label: String {
            switch self {
            case .idle: "Choose a model and download it"
            case .downloading(let fraction): "Downloading: \(Int(fraction * 100))%"
            case .loading: "Loading model…"
            case .ready: "Ready · on-device processing"
            case .generating: "Generating…"
            case .failed(let message): "Error: \(message)"
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var conversations: [ChatConversation] = []
    private(set) var models: [CatalogEntry] = []
    private(set) var cachedModelIDs: Set<String> = []
    private(set) var selectedModelID = "qwen3-0.6b"
    private(set) var selectedConversationID: UUID?
    var isModelPickerPresented = false
    private(set) var persistenceError: String?
    private(set) var contextSize: Int?

    private let repository: ConversationRepository
    private let executor: InProcessToolExecutor
    private var loadedModel: KitLanguageModel?
    private var runtime: AgentRuntime?
    private var generationTask: Task<Void, Never>?
    private var loadID = UUID()
    private var revision = 0
    private var didRestore = false
    private var lastSaveTask: Task<Void, Never>?

    init(repository: ConversationRepository = ConversationRepository()) {
        self.repository = repository
        executor = InProcessToolExecutor()
    }

    var isBusy: Bool {
        switch phase {
        case .downloading, .loading, .generating: true
        default: false
        }
    }

    var messages: [ChatMessage] { activeIndex.map { conversations[$0].messages } ?? [] }
    var toolsAvailable: Bool { runtime?.supportsTools ?? false }

    var contextLabel: String? {
        guard let contextSize else { return nil }
        guard let index = activeIndex,
              let remaining = ContextBudget.remaining(
                contextSize: contextSize, usedTokens: conversations[index].usedTokens
              ) else {
            return "Context window: \(contextSize.formatted()) tokens"
        }
        return "≈\(remaining.formatted()) / \(contextSize.formatted()) tokens left"
    }

    #if os(macOS)
    /// The selected model in a form the background Gateway can resolve on its own.
    var gatewayModelReference: ModelReference? {
        guard let entry = models.first(where: { $0.id == selectedModelID }),
              let id = entry.modelID else { return nil }
        return ModelReference(
            catalogID: entry.id, repo: id.repo, path: id.path, revision: id.revision
        )
    }

    var selectedModelName: String? {
        models.first(where: { $0.id == selectedModelID })?.name
    }
    #endif

    func loadCatalog() async {
        guard !didRestore else { return }
        didRestore = true
        do {
            if let saved = try await repository.load() {
                selectedModelID = saved.selectedModelID
                selectedConversationID = saved.selectedConversationID
                conversations = saved.conversations
                for index in conversations.indices {
                    if let last = conversations[index].messages.indices.last,
                       conversations[index].messages[last].role == .assistant,
                       conversations[index].messages[last].text.isEmpty {
                        conversations[index].messages[last].text = "The response was interrupted."
                    }
                }
            }
        } catch {
            persistenceError = error.localizedDescription
        }
        models = await ModelCatalog.load().available(.chat)
        if !models.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = models.first?.id ?? selectedModelID
        }
        if !conversations.contains(where: { $0.id == selectedConversationID }) {
            selectedConversationID = conversations.last?.id
        }
        if conversations.isEmpty {
            let conversation = ChatConversation(modelID: selectedModelID)
            selectedConversationID = conversation.id
            conversations.append(conversation)
        } else if let index = activeIndex {
            selectedModelID = conversations[index].modelID
        }
        refreshCachedModels()
        if cachedModelIDs.contains(selectedModelID) { loadModel() }
    }

    func selectModel(_ id: String) {
        guard !isBusy, id != selectedModelID,
              models.contains(where: { $0.id == id }) else { return }
        selectedModelID = id
        if let previous = conversations.last(where: { $0.modelID == id }) {
            selectedConversationID = previous.id
        } else {
            let conversation = ChatConversation(modelID: id)
            conversations.append(conversation)
            selectedConversationID = conversation.id
        }
        loadedModel = nil
        runtime = nil
        contextSize = nil
        phase = .idle
        saveState()
        if cachedModelIDs.contains(id) { loadModel() }
    }

    func selectConversation(_ id: UUID) {
        guard !isBusy, let conversation = conversations.first(where: { $0.id == id }) else {
            return
        }
        selectedConversationID = id
        if selectedModelID != conversation.modelID {
            selectedModelID = conversation.modelID
            loadedModel = nil
            runtime = nil
            contextSize = nil
            phase = .idle
            if cachedModelIDs.contains(selectedModelID) { loadModel() }
        } else if let loadedModel {
            runtime = makeRuntime(model: loadedModel)
        }
        saveState()
    }

    func loadModel() {
        guard !isBusy, let entry = models.first(where: { $0.id == selectedModelID }),
              let modelID = entry.modelID else { return }
        let requestID = UUID()
        loadID = requestID
        runtime = nil
        loadedModel = nil
        phase = .loading
        Task {
            do {
                let url = try await ModelStore.default.download(modelID) { progress in
                    Task { @MainActor in
                        guard self.loadID == requestID else { return }
                        self.phase = progress.fraction < 1
                            ? .downloading(progress.fraction) : .loading
                    }
                }
                guard loadID == requestID else { return }
                let model = try await KitLanguageModel(bundleAt: url)
                guard loadID == requestID else { return }
                loadedModel = model
                contextSize = Self.readContextSize(from: url)
                runtime = makeRuntime(model: model)
                cachedModelIDs.insert(selectedModelID)
                phase = .ready
            } catch {
                guard loadID == requestID else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func send(_ input: String) {
        guard phase == .ready, let runtime, let index = activeIndex else { return }
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let conversationID = conversations[index].id
        if conversations[index].messages.isEmpty {
            conversations[index].title = String(prompt.prefix(48))
        }
        let source = ChatMarkdownSource()
        let answerID = UUID()
        conversations[index].messages.append(ChatMessage(role: .user, text: prompt))
        conversations[index].messages.append(ChatMessage(
            id: answerID, role: .assistant, text: "", isStreaming: true,
            markdownSource: source
        ))
        phase = .generating
        saveState()
        generationTask = Task {
            do {
                let result = try await runtime.generate(prompt: prompt) { snapshot, usedTokens in
                    self.updateAnswer(id: answerID, in: conversationID, text: snapshot)
                    if let position = self.conversations.firstIndex(where: { $0.id == conversationID }) {
                        self.conversations[position].usedTokens = usedTokens
                    }
                }
                if let position = conversations.firstIndex(where: { $0.id == conversationID }) {
                    conversations[position].transcript = result.transcript
                    conversations[position].usedTokens = result.usedTokens
                }
                updateAnswer(id: answerID, in: conversationID, text: result.text)
                phase = .ready
            } catch is CancellationError {
                if let position = conversations.firstIndex(where: { $0.id == conversationID }) {
                    conversations[position].transcript = runtime.transcript
                }
                phase = .ready
            } catch {
                if let position = conversations.firstIndex(where: { $0.id == conversationID }) {
                    conversations[position].transcript = runtime.transcript
                }
                phase = .failed(error.localizedDescription)
            }
            finishAnswer(id: answerID, in: conversationID)
            await saveState().value
            generationTask = nil
        }
    }

    func stop() {
        guard phase == .generating else { return }
        generationTask?.cancel()
    }

    func newChat() {
        guard phase == .ready, let loadedModel else { return }
        let conversation = ChatConversation(modelID: selectedModelID)
        conversations.append(conversation)
        selectedConversationID = conversation.id
        runtime = makeRuntime(model: loadedModel)
        saveState()
    }

    private var activeIndex: Int? {
        conversations.firstIndex(where: { $0.id == selectedConversationID })
    }

    private func makeRuntime(model: KitLanguageModel) -> AgentRuntime {
        let conversationID = selectedConversationID
        let transcript = activeIndex.flatMap { conversations[$0].transcript }
        return AgentRuntime(
            model: model, transcript: transcript, executor: executor
        ) {
            [weak self] event in
            await self?.handleToolEvent(event, conversationID: conversationID)
        }
    }

    private func handleToolEvent(_ event: ToolEvent, conversationID: UUID?) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }
        switch event {
        case .started(let id, let title):
            conversations[index].messages.append(ChatMessage(
                id: id, role: .tool, text: title, isStreaming: true
            ))
        case .completed(let id, let result):
            if let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == id }) {
                conversations[index].messages[messageIndex].text = result.message
                conversations[index].messages[messageIndex].isStreaming = false
            }
            if result.opensModelPicker { isModelPickerPresented = true }
            saveState()
        case .failed(let id, let message):
            if let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == id }) {
                conversations[index].messages[messageIndex].text = "Tool error: \(message)"
                conversations[index].messages[messageIndex].isStreaming = false
            }
            saveState()
        }
    }

    private func updateAnswer(id: UUID, in conversationID: UUID, text: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == id })
        else { return }
        conversations[index].messages[messageIndex].text = text
        conversations[index].messages[messageIndex].markdownSource?.update(text)
    }

    private func updateToolMessage(id: UUID, in conversationID: UUID, text: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == id })
        else { return }
        conversations[index].messages[messageIndex].text = text
    }

    private func finishAnswer(id: UUID, in conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == id })
        else { return }
        conversations[index].messages[messageIndex].markdownSource?.finish()
        conversations[index].messages[messageIndex].markdownSource = nil
        conversations[index].messages[messageIndex].isStreaming = false
    }

    private func refreshCachedModels() {
        cachedModelIDs = Set(models.compactMap { entry in
            guard let model = entry.modelID,
                  ModelStore.default.localURL(for: model) != nil else { return nil }
            return entry.id
        })
    }

    func flushPersistence() async {
        await lastSaveTask?.value
    }

    @discardableResult
    private func saveState() -> Task<Void, Never> {
        revision += 1
        let currentRevision = revision
        let state = SavedChatState(
            selectedModelID: selectedModelID,
            selectedConversationID: selectedConversationID,
            conversations: conversations
        )
        let task = Task {
            do {
                try await repository.save(state, revision: currentRevision)
                persistenceError = nil
            } catch {
                persistenceError = error.localizedDescription
            }
        }
        lastSaveTask = task
        return task
    }

    private static func readContextSize(from url: URL) -> Int? {
        struct Metadata: Decodable {
            struct Language: Decodable {
                let maxContextLength: Int
                enum CodingKeys: String, CodingKey {
                    case maxContextLength = "max_context_length"
                }
            }
            let language: Language
        }
        let metadataURL = url.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let size = try? JSONDecoder().decode(Metadata.self, from: data).language.maxContextLength,
              size > 0 else { return nil }
        return size
    }
}
