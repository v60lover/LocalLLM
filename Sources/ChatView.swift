import SwiftUI
import SwiftStreamingMarkdown

struct ChatView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var chat = ChatStore()
    @State private var input = ""
    #if os(macOS)
    @State private var isGatewayPresented = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            modelBar
            Divider()
            transcript
            Divider()
            composer
        }
        .task { await chat.loadCatalog() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                Task { await chat.flushPersistence() }
            }
        }
        .sheet(isPresented: $chat.isModelPickerPresented) {
            modelPickerSheet
        }
        #if os(macOS)
        .sheet(isPresented: $isGatewayPresented) {
            GatewaySettingsView(
                currentModel: chat.gatewayModelReference,
                currentModelName: chat.selectedModelName,
                currentModelIsCached: chat.cachedModelIDs.contains(chat.selectedModelID)
            )
        }
        .frame(minWidth: 520, minHeight: 600)
        #endif
    }

    private var modelBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Model", selection: Binding(
                    get: { chat.selectedModelID },
                    set: { chat.selectModel($0) }
                )) {
                    ForEach(chat.models, id: \.id) { model in
                        Text(model.name + (chat.cachedModelIDs.contains(model.id) ? " · on disk" : ""))
                            .tag(model.id)
                    }
                }
                .disabled(chat.isBusy || chat.models.isEmpty)

                Button(chat.phase == .ready ? "Reload" :
                    (chat.cachedModelIDs.contains(chat.selectedModelID) ? "Open" : "Download")) {
                    chat.loadModel()
                }
                .disabled(chat.isBusy || chat.models.isEmpty)
            }

            HStack {
                Menu {
                    ForEach(chat.conversations) { conversation in
                        Button(conversation.title) {
                            chat.selectConversation(conversation.id)
                        }
                    }
                } label: {
                    Text(chat.conversations.first(where: { $0.id == chat.selectedConversationID })?.title ?? "Conversations")
                        .lineLimit(1)
                }
                .disabled(chat.isBusy)
                #if os(macOS)
                Button("Digest…") { isGatewayPresented = true }
                #endif
                Spacer()
                if let context = chat.contextLabel {
                    Text(context)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                if chat.isBusy { ProgressView().controlSize(.small) }
                Text(chat.phase.label)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
            }
            if chat.phase == .ready && !chat.toolsAvailable {
                Text("This model does not support tool calls from chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if case .downloading(let fraction) = chat.phase {
                ProgressView(value: fraction)
            }
            if let error = chat.persistenceError {
                Text("Could not save conversations: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if chat.messages.isEmpty {
                        ContentUnavailableView(
                            "Local Chat",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Choose a model and download it. The first run downloads the weights; after that, replies are generated on your device.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    }

                    ForEach(chat.messages) { message in
                        messageView(message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: chat.messages.last?.text) { _, _ in
                if let id = chat.messages.last?.id {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
            .onChange(of: chat.messages.count) { _, _ in
                if let id = chat.messages.last?.id {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private func messageView(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 8) {
                Text(message.role == .user ? "You" :
                    (message.role == .tool ? "Tool" : "Assistant"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !message.thinking.isEmpty {
                    DisclosureGroup("Reasoning") {
                        Text(message.thinking).textSelection(.enabled)
                    }
                    .font(.caption)
                }
                if message.role == .tool {
                    HStack {
                        if message.isStreaming { ProgressView().controlSize(.small) }
                        Text(message.text)
                    }
                } else if !message.text.isEmpty {
                    if message.role == .assistant {
                        if message.isStreaming, let source = message.markdownSource {
                            StreamedMarkdownView(source: source)
                        } else {
                            MarkdownView(text: message.text)
                        }
                    } else {
                        Text(message.text)
                            .textSelection(.enabled)
                    }
                } else if message.isStreaming {
                    ProgressView()
                }
            }
            .padding(12)
            .background(
                message.role == .user ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 14)
            )
            if message.role != .user { Spacer(minLength: 48) }
        }
    }

    private var modelPickerSheet: some View {
        NavigationStack {
            List(chat.models, id: \.id) { model in
                Button {
                    chat.isModelPickerPresented = false
                    chat.selectModel(model.id)
                } label: {
                    HStack {
                        Text(model.name)
                        Spacer()
                        if chat.cachedModelIDs.contains(model.id) {
                            Label("On disk", systemImage: "checkmark.circle")
                                .font(.caption)
                        }
                    }
                }
                .disabled(chat.isBusy)
            }
            .navigationTitle("Choose Model")
            .toolbar {
                Button("Close") { chat.isModelPickerPresented = false }
            }
        }
        .frame(minWidth: 320, minHeight: 360)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .disabled(chat.phase != .ready)
                .onSubmit(send)

            if chat.phase == .generating {
                Button("Stop") { chat.stop() }
            } else {
                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(chat.phase != .ready || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button("New Chat") { chat.newChat() }
                .disabled(chat.phase != .ready || chat.messages.isEmpty)
        }
        .padding()
    }

    private var statusColor: Color {
        if case .failed = chat.phase { return .red }
        return .secondary
    }

    private func send() {
        guard chat.phase == .ready else { return }
        let text = input
        input = ""
        chat.send(text)
    }
}
