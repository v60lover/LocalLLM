#if os(macOS)
import Foundation

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

    func load() -> GatewayPersistedState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? GatewayWire.decoder.decode(GatewayPersistedState.self, from: data)
        else { return GatewayPersistedState() }
        return state
    }

    func save(_ state: GatewayPersistedState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try GatewayWire.encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}
#endif
