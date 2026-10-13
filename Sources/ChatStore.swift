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

struct ChatMessage: Identifiable, Codable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant, tool }

    let id: UUID
    let role: Role
    var text: String
    var isStreaming = false
    var markdownSource: ChatMarkdownSource?

    init(
        id: UUID = UUID(), role: Role, text: String, isStreaming: Bool = false,
        markdownSource: ChatMarkdownSource? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
        self.markdownSource = markdownSource
    }

    /// Streaming state is transient and never persisted.
    private enum CodingKeys: String, CodingKey {
        case id, role, text
    }
}

enum ContextBudget {
    static func remaining(contextSize: Int?, usedTokens: Int?) -> Int? {
        guard let contextSize, contextSize > 0, let usedTokens else { return nil }
        return max(0, contextSize - usedTokens)
    }

    /// True when another reply might not fit, so old turns should be dropped before sending.
    static func isNearlyFull(contextSize: Int?, usedTokens: Int?, replyBudget: Int) -> Bool {
        guard let remaining = remaining(contextSize: contextSize, usedTokens: usedTokens) else {
            return false
        }
        return remaining < replyBudget + 256
    }
}

@MainActor
@Observable
final class ChatStore {
    enum ModelState: Equatable {
        case idle, downloading(Double), loading, ready
        case failed(String)

        var label: String {
            switch self {
            case .idle: "Choose a model and download it"
            case .downloading(let fraction): "Downloading: \(Int(fraction * 100))%"
            case .loading: "Loading model…"
            case .ready: "Ready · on-device processing"
            case .failed(let message): "Error: \(message)"
            }
        }
    }

    /// Independent of the model: a failed reply leaves the model usable.
    enum GenerationState: Equatable {
        case idle, generating
        case failed(String)
    }

    private(set) var modelState: ModelState = .idle
    private(set) var generation: GenerationState = .idle
    private(set) var conversations: [ChatConversation] = []
    private(set) var models: [ChatModelOption] = []
    private(set) var cachedModelIDs: Set<String> = []
    private(set) var selectedModelID = "qwen3-0.6b"
    private(set) var selectedConversationID: UUID?
    var isModelPickerPresented = false
    private(set) var persistenceError: String?
    /// Set when saved conversations could not be read at launch; stays until the app restarts.
    private(set) var restoreNotice: String?
    private(set) var contextSize: Int?

    private let repository: ConversationRepository
    private let backend: any ChatBackend
    private var loadedModel: (any ChatModelHandle)?
    private var runtime: (any ChatRuntime)?
    private var generationTask: Task<Void, Never>?
    private var loadID = UUID()
    private var revision = 0
    private var didRestore = false
    private var lastSaveTask: Task<Void, Never>?

    init(
        repository: ConversationRepository = ConversationRepository(),
        backend: any ChatBackend = ChatStore.defaultBackend()
    ) {
        self.repository = repository
        self.backend = backend
    }

    /// macOS chats through the Gateway so the model lives outside the app process; iOS has no
    /// Gateway and runs the model in-process.
    static func defaultBackend() -> any ChatBackend {
        #if os(macOS)
        XPCChatBackend()
        #else
        CoreAIBackend()
        #endif
    }

    var isGenerating: Bool { generation == .generating }
    var isModelReady: Bool { modelState == .ready }
    var canSend: Bool { isModelReady && !isGenerating }

    var isBusy: Bool {
        switch modelState {
        case .downloading, .loading: true
        default: isGenerating
        }
    }

    var statusLabel: String { isGenerating ? "Generating…" : modelState.label }

    var generationError: String? {
        if case .failed(let message) = generation { message } else { nil }
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
        var label = "≈\(remaining.formatted()) / \(contextSize.formatted()) tokens left"
        if (conversations[index].droppedTurns ?? 0) > 0 { label += " · older messages trimmed" }
        return label
    }

    #if os(macOS)
    /// The selected model in a form the background Gateway can resolve on its own.
    var gatewayModelReference: ModelReference? {
        guard let option = models.first(where: { $0.id == selectedModelID }),
              let source = option.source else { return nil }
        return ModelReference(
            catalogID: option.id, repo: source.repo, path: source.path, revision: source.revision
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
        } catch let error as ConversationRepositoryError {
            restoreNotice = error.localizedDescription
        } catch {
            persistenceError = error.localizedDescription
        }
        models = await backend.loadCatalog()
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
        resetModel()
        saveState()
        if cachedModelIDs.contains(id) { loadModel() }
    }

    func selectConversation(_ id: UUID) {
        guard !isBusy, let conversation = conversations.first(where: { $0.id == id }) else {
            return
        }
        selectedConversationID = id
        generation = .idle
        if selectedModelID != conversation.modelID {
            selectedModelID = conversation.modelID
            resetModel()
            if cachedModelIDs.contains(selectedModelID) { loadModel() }
        } else if let loadedModel {
            runtime = makeRuntime(model: loadedModel, transcript: conversation.transcript)
        }
        saveState()
    }

    func loadModel() {
        guard !isBusy, let option = models.first(where: { $0.id == selectedModelID }) else {
            return
        }
        let requestID = UUID()
        loadID = requestID
        runtime = nil
        loadedModel = nil
        generation = .idle
        modelState = .loading
        Task {
            do {
                let handle = try await backend.load(option) { fraction in
                    Task { @MainActor in
                        guard self.loadID == requestID else { return }
                        self.modelState = fraction < 1 ? .downloading(fraction) : .loading
                    }
                }
                guard loadID == requestID else { return }
                loadedModel = handle
                contextSize = handle.contextSize
                runtime = makeRuntime(
                    model: handle, transcript: activeIndex.flatMap { conversations[$0].transcript }
                )
                cachedModelIDs.insert(option.id)
                modelState = .ready
            } catch {
                guard loadID == requestID else { return }
                modelState = .failed(error.localizedDescription)
            }
        }
    }

    func send(_ input: String) {
        guard canSend, runtime != nil, let index = activeIndex else { return }
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let conversationID = conversations[index].id
        if conversations[index].messages.isEmpty {
            conversations[index].title = String(prompt.prefix(48))
        }
        let source = ChatMarkdownSource()
        let answerID = UUID()
        let baseTranscript = conversations[index].transcript
        conversations[index].messages.append(ChatMessage(role: .user, text: prompt))
        conversations[index].messages.append(ChatMessage(
            id: answerID, role: .assistant, text: "", isStreaming: true,
            markdownSource: source
        ))
        generation = .generating
        saveState()
        generationTask = Task {
            await runGeneration(
                prompt: prompt, answerID: answerID, conversationID: conversationID,
                baseTranscript: baseTranscript
            )
            finishAnswer(id: answerID, in: conversationID)
            await saveState().value
            generationTask = nil
        }
    }

    func stop() {
        guard isGenerating else { return }
        generationTask?.cancel()
    }

    func dismissGenerationError() {
        if case .failed = generation { generation = .idle }
    }

    func newChat() {
        guard canSend, let loadedModel else { return }
        let conversation = ChatConversation(modelID: selectedModelID)
        conversations.append(conversation)
        selectedConversationID = conversation.id
        generation = .idle
        runtime = makeRuntime(model: loadedModel, transcript: nil)
        saveState()
    }

    // MARK: - Generation

    /// Runs one reply. The conversation's transcript only ever advances on success; on failure it
    /// is rolled back to `baseTranscript` so the model and the chat stay usable. A context overflow
    /// drops the older half of the conversation and retries once.
    private func runGeneration(
        prompt: String, answerID: UUID, conversationID: UUID, baseTranscript: Transcript?
    ) async {
        guard var runtime, let handle = loadedModel else { return }
        var base = baseTranscript
        var didTrim = false

        if let position = position(of: conversationID),
           ContextBudget.isNearlyFull(
               contextSize: contextSize, usedTokens: conversations[position].usedTokens,
               replyBudget: runtime.responseTokenBudget
           ),
           let trimmed = trim(base, conversationID: conversationID) {
            base = trimmed
            runtime = replaceRuntime(handle: handle, transcript: base)
        }

        while true {
            do {
                let result = try await runtime.generate(prompt: prompt) { snapshot, usedTokens in
                    self.updateAnswer(id: answerID, in: conversationID, text: snapshot)
                    if let position = self.position(of: conversationID) {
                        self.conversations[position].usedTokens = usedTokens
                    }
                }
                if let position = position(of: conversationID) {
                    conversations[position].transcript = result.transcript
                    conversations[position].usedTokens = result.usedTokens
                }
                updateAnswer(id: answerID, in: conversationID, text: result.text)
                generation = .idle
            } catch is CancellationError {
                if let position = position(of: conversationID) {
                    conversations[position].transcript = runtime.transcript
                }
                generation = .idle
            } catch ChatRuntimeError.contextOverflow where !didTrim {
                didTrim = true
                if let trimmed = trim(base, conversationID: conversationID) {
                    base = trimmed
                    runtime = replaceRuntime(handle: handle, transcript: base)
                    updateAnswer(id: answerID, in: conversationID, text: "")
                    continue
                }
                fail(ChatRuntimeError.contextOverflow, answerID: answerID,
                     conversationID: conversationID, rollbackTo: base, handle: handle)
            } catch {
                fail(error, answerID: answerID, conversationID: conversationID,
                     rollbackTo: base, handle: handle)
            }
            return
        }
    }

    /// Drops the older half of `transcript`. Returns nil when there was nothing left to drop.
    private func trim(_ transcript: Transcript?, conversationID: UUID) -> Transcript? {
        guard let transcript, let position = position(of: conversationID) else { return nil }
        let result = TranscriptTrimmer.dropOldestHalf(of: transcript)
        guard result.droppedTurns > 0 else { return nil }
        conversations[position].transcript = result.transcript
        conversations[position].droppedTurns = (conversations[position].droppedTurns ?? 0)
            + result.droppedTurns
        conversations[position].usedTokens = nil
        return result.transcript
    }

    private func replaceRuntime(
        handle: any ChatModelHandle, transcript: Transcript?
    ) -> any ChatRuntime {
        let fresh = makeRuntime(model: handle, transcript: transcript)
        runtime = fresh
        return fresh
    }

    private func fail(
        _ error: any Error, answerID: UUID, conversationID: UUID, rollbackTo base: Transcript?,
        handle: any ChatModelHandle
    ) {
        if let position = position(of: conversationID) {
            conversations[position].transcript = base
            // Do not leave an empty "Assistant" bubble behind.
            if let messageIndex = conversations[position].messages.firstIndex(where: { $0.id == answerID }),
               conversations[position].messages[messageIndex].text.isEmpty {
                conversations[position].messages[messageIndex].markdownSource?.finish()
                conversations[position].messages.remove(at: messageIndex)
            }
        }
        _ = replaceRuntime(handle: handle, transcript: base)
        generation = .failed(error.localizedDescription)
    }

    // MARK: - Helpers

    private var activeIndex: Int? {
        conversations.firstIndex(where: { $0.id == selectedConversationID })
    }

    private func position(of conversationID: UUID) -> Int? {
        conversations.firstIndex(where: { $0.id == conversationID })
    }

    private func resetModel() {
        loadedModel = nil
        runtime = nil
        contextSize = nil
        generation = .idle
        modelState = .idle
    }

    private func makeRuntime(model: any ChatModelHandle, transcript: Transcript?) -> any ChatRuntime {
        let conversationID = selectedConversationID
        return model.makeRuntime(transcript: transcript) { [weak self] event in
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

    private func finishAnswer(id: UUID, in conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == id })
        else { return }
        conversations[index].messages[messageIndex].markdownSource?.finish()
        conversations[index].messages[messageIndex].markdownSource = nil
        conversations[index].messages[messageIndex].isStreaming = false
    }

    private func refreshCachedModels() {
        cachedModelIDs = backend.cachedModelIDs(among: models)
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
}
