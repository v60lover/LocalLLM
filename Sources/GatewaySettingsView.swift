#if os(macOS)
import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class GatewaySettingsModel {
    var draft = DigestConfig() {
        didSet { if draftLoaded, draft != oldValue { scheduleAutoSave() } }
    }
    private(set) var status: GatewayStatus?
    private(set) var isInstalled = false
    private(set) var errorMessage: String?
    private(set) var isWorking = false
    /// Why the last automatic save was rejected. Unlike `errorMessage` it is not cleared by polling.
    private(set) var saveError: String?

    private let client: any GatewayControlling
    private let installer: GatewayInstaller
    private var pollTask: Task<Void, Never>?
    private var draftLoaded = false
    var currentModel: ModelReference?
    private var saveTask: Task<Void, Never>?

    init(
        client: any GatewayControlling = GatewayXPCClient(),
        installer: GatewayInstaller = .bundled()
    ) {
        self.client = client
        self.installer = installer
    }

    var isReachable: Bool { status != nil }
    var isDirty: Bool { status.map { $0.config != draft } ?? false }

    /// A reason the current draft cannot be saved, found on the client before bothering the Gateway.
    var validationMessage: String? {
        do { try draft.validate(); return nil } catch { return error.localizedDescription }
    }

    enum SyncState: Equatable {
        case saved, saving
        case notSaved(String)
    }

    var syncState: SyncState {
        if let reason = validationMessage ?? saveError { return .notSaved(reason) }
        return isDirty ? .saving : .saved
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        // Edits are applied automatically; make sure a pending one is not lost on close.
        if saveTask != nil {
            saveTask?.cancel()
            saveTask = nil
            Task { await save(model: nil) }
        }
    }

    /// Persists every edit in the Gateway shortly after it is made, so there is no separate Save step to forget.
    private func scheduleAutoSave() {
        saveTask?.cancel()
        saveTask = nil
        saveError = nil
        guard validationMessage == nil else { return }
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            saveTask = nil
            await save(model: nil)
        }
    }

    /// Keeps the Gateway's model in step with the one selected in the chat.
    func adopt(model: ModelReference?) {
        if let model, draft.model != model { draft.model = model }
    }

    func refresh() async {
        isInstalled = installer.isInstalled
        do {
            let latest = try await client.send(.status)
            status = latest
            if !draftLoaded {
                draft = latest.config
                draftLoaded = true
                adopt(model: currentModel)
            }
        } catch {
            status = nil
            errorMessage = error.localizedDescription
            return
        }
        if errorMessage != nil, !isWorking { errorMessage = nil }
    }

    func save(model: ModelReference?) async {
        if let model { draft.model = model }
        guard validationMessage == nil else { return }
        let config = draft
        isWorking = true
        defer { isWorking = false }
        do {
            status = try await client.send(.updateConfig(config))
            saveError = nil
            errorMessage = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    func runNow(model: ModelReference?) async {
        if let model { draft.model = model }
        guard validationMessage == nil else { return }
        await perform {
            if self.isDirty { _ = try await self.client.send(.updateConfig(self.draft)) }
            return try await self.client.send(.runNow)
        }
    }

    func cancelRun() async {
        await perform { try await self.client.send(.cancelRun) }
    }

    func install() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await installer.install()
            errorMessage = nil
            // launchd starts the agent on demand; give the XPC service a moment to register.
            try? await Task.sleep(for: .seconds(1))
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            isInstalled = installer.isInstalled
        }
    }

    func uninstall() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await installer.uninstall()
            status = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isInstalled = installer.isInstalled
    }

    private func perform(_ action: () async throws -> GatewayStatus) async {
        isWorking = true
        defer { isWorking = false }
        do {
            status = try await action()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct GatewaySettingsView: View {
    let currentModel: ModelReference?
    let currentModelName: String?
    let currentModelIsCached: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var model = GatewaySettingsModel()

    var body: some View {
        NavigationStack {
            Form {
                serviceSection
                if model.isReachable {
                    scheduleSection
                    sourcesSection
                    outputSection
                    modelSection
                    resultSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Daily Digest")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 640)
        .task {
            model.currentModel = currentModel
            model.start()
        }
        .onChange(of: currentModel) { _, new in
            model.currentModel = new
            model.adopt(model: new)
        }
        .onDisappear { model.stop() }
    }

    private var serviceSection: some View {
        Section("Gateway") {
            LabeledContent("Status") {
                Text(serviceLabel).foregroundStyle(model.isReachable ? .green : .secondary)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button(model.isInstalled ? "Reinstall" : "Install and Start") {
                    Task { await model.install() }
                }
                if model.isInstalled {
                    Button("Remove", role: .destructive) { Task { await model.uninstall() } }
                }
            }
            .disabled(model.isWorking)
            Text("The Gateway is a separate background process (launchd). It keeps running even when this window and the app are closed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var scheduleSection: some View {
        Section("Schedule") {
            Toggle("Daily digest enabled", isOn: $model.draft.isEnabled)
            DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
            LabeledContent("Time zone") {
                Text(timeZoneLabel)
            }
            LabeledContent("Next run") {
                Text(nextRunLabel)
            }
            Text("Time is evaluated in the time zone currently set in macOS. If the Mac was asleep at the scheduled time, the digest is created after wake-up the same day; missed past days are not made up.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sourcesSection: some View {
        Section("News sources (RSS/Atom, one URL per line)") {
            TextEditor(text: sourcesBinding)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90)
        }
    }

    private var outputSection: some View {
        Section("Folder for Pages documents") {
            HStack {
                TextField("Folder", text: $model.draft.outputDirectory)
                Button("Choose…") { chooseFolder() }
            }
        }
    }

    private var modelSection: some View {
        Section("Model") {
            let name = currentModelName ?? model.draft.model?.catalogID ?? "none selected"
            LabeledContent("Used for summarizing") { Text(name) }
            if currentModel != nil && !currentModelIsCached {
                Text("This model is not downloaded yet. Open it in the chat, otherwise the Gateway cannot create a digest.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("The model selected in the chat is used; the Gateway follows when you switch models.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var resultSection: some View {
        Section("Run") {
            HStack {
                switch model.syncState {
                case .saved:
                    Text("Saved").font(.caption).foregroundStyle(.secondary)
                case .saving:
                    Text("Saving…").font(.caption).foregroundStyle(.secondary)
                case .notSaved(let reason):
                    Text("Not saved: \(reason)").font(.caption).foregroundStyle(.red)
                }
                if model.status?.isRunning == true {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { Task { await model.cancelRun() } }
                } else {
                    Button("Run Now") { Task { await model.runNow(model: currentModel) } }
                        .disabled(model.isWorking || model.validationMessage != nil)
                }
            }
            if let run = model.status?.lastRun {
                LabeledContent("Last run") {
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened) + " · " + run.trigger.label)
                }
                switch run.outcome {
                case .running:
                    Text("Running…").foregroundStyle(.secondary)
                case .succeeded(let path, let count):
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Done: \(count) news items").foregroundStyle(.green)
                        Button("Show Document") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                    }
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red)
                case .cancelled:
                    Text("Cancelled").foregroundStyle(.secondary)
                }
            }
            if let attempts = model.status?.attemptsToday, attempts > 0 {
                Text("Failed attempts today: \(attempts) of \(DigestSchedule.maxAttemptsPerDay). The next attempt happens automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bindings and labels

    private var timeBinding: Binding<Date> {
        Binding {
            Calendar.current.date(
                bySettingHour: model.draft.hour, minute: model.draft.minute, second: 0, of: Date()
            ) ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            model.draft.hour = parts.hour ?? 8
            model.draft.minute = parts.minute ?? 0
        }
    }

    private var sourcesBinding: Binding<String> {
        Binding {
            model.draft.sources.joined(separator: "\n")
        } set: { text in
            model.draft.sources = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    private var serviceLabel: String {
        if model.isReachable { return "running" }
        return model.isInstalled ? "installed, not responding" : "not installed"
    }

    private var timeZoneLabel: String {
        guard let id = model.status?.timeZoneID, let zone = TimeZone(identifier: id) else {
            return TimeZone.current.identifier
        }
        return "\(id) (\(zone.abbreviation() ?? ""))"
    }

    private var nextRunLabel: String {
        guard model.status?.config.isEnabled == true else { return "off" }
        guard let next = model.status?.nextRun else { return "—" }
        return next.formatted(date: .abbreviated, time: .shortened)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { model.draft.outputDirectory = url.path }
    }
}
#endif
