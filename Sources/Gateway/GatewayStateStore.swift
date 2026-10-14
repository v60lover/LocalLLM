import Foundation
import OSLog

/// Everything the Gateway must remember across restarts. Owned by the Gateway process.
struct GatewayPersistedState: Codable, Equatable, Sendable {
    var config = DigestConfig()
    var progress = DailyProgress()
    var lastRun: RunRecord?
    /// A run that was started but never recorded as finished (crash, kill, reboot).
    var inFlight: RunRecord?
}

struct GatewayStateStore: Sendable {
    let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("state.json")
    }

    /// A missing file means a first start. An unreadable one is moved aside (not overwritten
    /// by the next save) before falling back to defaults.
    func load() -> GatewayPersistedState {
        guard let data = try? Data(contentsOf: fileURL) else { return GatewayPersistedState() }
        do {
            return try GatewayWire.decoder.decode(GatewayPersistedState.self, from: data)
        } catch {
            let backup = FileQuarantine.moveAside(fileURL)
            Logger(subsystem: GatewayConstants.label, category: "state").error(
                "state.json is unreadable (\(error.localizedDescription, privacy: .public)); kept as \(backup?.lastPathComponent ?? "nothing", privacy: .public)"
            )
            return GatewayPersistedState()
        }
    }

    func save(_ state: GatewayPersistedState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try GatewayWire.encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}
