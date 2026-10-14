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
    /// Why the last automatic save was rejected. Unlike `errorMessage` it is not cleared by status updates.
    private(set) var saveError: String?

    /// Created on first use: SwiftUI builds this model more often than it keeps one, and a
    /// client that is never used must not exist.
    @ObservationIgnored private lazy var client: any GatewayControlling = makeClient()
    @ObservationIgnored private let makeClient: () -> any GatewayControlling
    private let installer: GatewayInstaller
    /// Reads `client.events` while the window is open; cancelled in `stop()`.
    private var eventsTask: Task<Void, Never>?
    private var draftLoaded = false
    var currentModel: ModelReference?
    private var saveTask: Task<Void, Never>?
    /// The newest status seen from one Gateway process (`startedAt` identifies it).
    @ObservationIgnored private var newest: (startedAt: Date, revision: Int)?

    /// The model owns `client` for the lifetime of the window and stops it in `stop()`.
    /// `client` is an autoclosure and has no default: the call site names the client it wants,
    /// and writing `GatewayClient()` there does not create one until it is first used.
    init(
        client: @escaping @autoclosure () -> any GatewayControlling,
        installer: GatewayInstaller = .bundled()
    ) {
        makeClient = client
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

    /// Follows the Gateway through pushed events; there is no polling. The client keeps the
    /// connection alive (heartbeat, reconnect) and reports `connected` / `disconnected`.
    func start() {
        guard eventsTask == nil else { return }
        let client = client
        // The task holds the client, not the model: a window that goes away without `stop()`
        // does not stay alive because of its own event loop.
        eventsTask = Task { [weak self] in
            await client.start()
            // Ask once up front, so the window fills in without waiting for the first push.
            await self?.refresh()
            // Ends when the client is stopped (the stream finishes) or the task is cancelled.
            for await event in client.events {
                guard !Task.isCancelled, let self else { return }
                await self.handle(event)
            }
        }
    }

    /// Applies one client event to what the window shows.
    func handle(_ event: GatewayClientEvent) async {
        switch event {
        case .connected:
            // A new connection, possibly to a restarted Gateway: read the status afresh.
            await refresh()
        case .status(let latest):
            // Install state is re-read on every event; nothing else refreshes it.
            isInstalled = installer.isInstalled
            apply(latest)
            // A status arriving proves the Gateway is reachable again. An error from an
            // action still in progress is left for that action to settle.
            if errorMessage != nil, !isWorking { errorMessage = nil }
        case .disconnected(let reason):
            isInstalled = installer.isInstalled
            // No status means "not reachable": the sections that need the Gateway are hidden.
            status = nil
            errorMessage = reason
        }
    }

    /// Called when the window closes. The client is not usable afterwards.
    func stop() {
        eventsTask?.cancel()
        eventsTask = nil
        // Edits are applied automatically; make sure a pending one is not lost on close.
        let hasPendingSave = saveTask != nil
        saveTask?.cancel()
        saveTask = nil
        let client = client
        Task {
            // Stopping the client is final, so the last save goes first.
            if hasPendingSave { await save(model: nil) }
            await client.stop()
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
            apply(try await client.send(.status))
        } catch {
            status = nil
            errorMessage = error.localizedDescription
            return
        }
        if errorMessage != nil, !isWorking { errorMessage = nil }
    }

    /// Replies and pushed events arrive on separate paths with no order between them; a status
    /// older than one already shown (same Gateway process, lower revision) is dropped.
    private func apply(_ latest: GatewayStatus) {
        // A Gateway that sends no revision is taken at its word: there is nothing to compare.
        if let revision = latest.revision {
            // Revisions restart at 0 with the Gateway process, so they are only compared
            // within one process; a different `startedAt` always wins.
            if let newest, newest.startedAt == latest.startedAt, revision < newest.revision { return }
            newest = (latest.startedAt, revision)
        }
        status = latest
        // The draft is taken from the Gateway once. After that it belongs to the user, and
        // later statuses must not overwrite what they are typing.
        if !draftLoaded {
            draft = latest.config
            draftLoaded = true
            adopt(model: currentModel)
        }
    }

    func save(model: ModelReference?) async {
        if let model { draft.model = model }
        guard validationMessage == nil else { return }
        let config = draft
        isWorking = true
        defer { isWorking = false }
        do {
            apply(try await client.send(.updateConfig(config)))
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
            apply(try await action())
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
    @State private var model = GatewaySettingsModel(client: GatewayClient())

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
