#if os(macOS)
import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class GatewaySettingsModel {
    var draft = DigestConfig()
    private(set) var status: GatewayStatus?
    private(set) var isInstalled = false
    private(set) var errorMessage: String?
    private(set) var isWorking = false

    private let client: any GatewayControlling
    private let installer: GatewayInstaller
    private var pollTask: Task<Void, Never>?
    private var draftLoaded = false

    init(
        client: any GatewayControlling = GatewayXPCClient(),
        installer: GatewayInstaller = .bundled()
    ) {
        self.client = client
        self.installer = installer
    }

    var isReachable: Bool { status != nil }
    var isDirty: Bool { status.map { $0.config != draft } ?? false }

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
    }

    func refresh() async {
        isInstalled = installer.isInstalled
        do {
            let latest = try await client.send(.status)
            status = latest
            if !draftLoaded {
                draft = latest.config
                draftLoaded = true
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
        await perform { try await self.client.send(.updateConfig(self.draft)) }
    }

    func runNow(model: ModelReference?) async {
        if let model { draft.model = model }
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
            model.start()
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
            Text("The model selected in the chat at the time you save the settings is used.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var resultSection: some View {
        Section("Run") {
            HStack {
                Button("Save") { Task { await model.save(model: currentModel) } }
                    .disabled(!model.isDirty || model.isWorking)
                if model.status?.isRunning == true {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { Task { await model.cancelRun() } }
                } else {
                    Button("Run Now") { Task { await model.runNow(model: currentModel) } }
                        .disabled(model.isWorking)
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
