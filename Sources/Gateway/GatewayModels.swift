#if os(macOS)
import Foundation

enum GatewayConstants {
    static let protocolVersion = 1
    static let label = "com.example.localllmchat.gateway"
    static let machServiceName = label
    static let executableName = "LocalLLMGateway"
}

enum GatewayPaths {
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLLMChat/Gateway", isDirectory: true)
    }

    static var logsDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/LocalLLMChat", isDirectory: true)
    }

    static var defaultDigestDirectory: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLLMChat Digests", isDirectory: true).path
    }
}

/// Points at a model bundle in the CoreAIKit cache. The Gateway resolves it itself so the
/// app does not need to be running (or to hand over file paths that may go stale).
struct ModelReference: Codable, Equatable, Sendable {
    var catalogID: String
    var repo: String
    var path: String?
    var revision: String
}

struct DigestConfig: Codable, Equatable, Sendable {
    static let maxSources = 20

    var isEnabled = false
    var sources: [String] = ["https://feeds.bbci.co.uk/news/world/rss.xml"]
    var outputDirectory = GatewayPaths.defaultDigestDirectory
    var hour = 8
    var minute = 0
    var model: ModelReference?

    /// Throws `GatewayError.invalidConfig` for values the Gateway must never persist.
    func validate() throws {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else {
            throw GatewayError.invalidConfig("Time must be between 00:00 and 23:59.")
        }
        guard !outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatewayError.invalidConfig("Choose a folder for the digests.")
        }
        guard sources.count <= Self.maxSources else {
            throw GatewayError.invalidConfig("At most \(Self.maxSources) sources are allowed.")
        }
        for source in sources where Self.url(from: source) == nil {
            throw GatewayError.invalidConfig("Source “\(source)” must be an http or https URL.")
        }
    }

    var sourceURLs: [URL] { sources.compactMap(Self.url(from:)) }

    static func url(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
}

enum RunTrigger: String, Codable, Sendable {
    case scheduled, catchUp, retry, manual

    var label: String {
        switch self {
        case .scheduled: "scheduled"
        case .catchUp: "catch-up"
        case .retry: "retry after failure"
        case .manual: "manual"
        }
    }
}

struct RunRecord: Codable, Equatable, Sendable, Identifiable {
    enum Outcome: Codable, Equatable, Sendable {
        case running
        case succeeded(path: String, itemCount: Int)
        case failed(message: String)
        case cancelled
    }

    let id: UUID
    let trigger: RunTrigger
    let startedAt: Date
    var finishedAt: Date?
    var outcome: Outcome
}

struct GatewayStatus: Codable, Equatable, Sendable {
    var protocolVersion = GatewayConstants.protocolVersion
    var config: DigestConfig
    var isRunning: Bool
    var nextRun: Date?
    var timeZoneID: String
    var lastRun: RunRecord?
    var attemptsToday: Int
    var lastSuccessDay: String?
    var startedAt: Date
}

enum GatewayError: LocalizedError, Equatable, Sendable {
    case invalidConfig(String)
    case noSources
    case noModelSelected
    case modelNotDownloaded(String)
    case modelUnavailable(String)
    case summarizationFailed(String)
    case allSourcesFailed([String])
    case noNews
    case noGoodNews
    case outputDirectoryUnavailable(String)
    case pagesFailed(String)
    case timeout
    case alreadyRunning
    case unsupportedProtocol(Int)
    case gatewayUnavailable(String)
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig(let detail): detail
        case .noSources: "No news sources are configured."
        case .noModelSelected: "No model selected. Choose and download a model in the chat."
        case .modelNotDownloaded(let id): "Model “\(id)” is not downloaded. Open it in the chat to download it."
        case .modelUnavailable(let detail): "Could not open the model: \(detail)"
        case .summarizationFailed(let detail): "The model did not produce a digest: \(detail)"
        case .allSourcesFailed(let details):
            "Could not fetch news from any source. " + details.joined(separator: " ")
        case .noNews: "The sources responded, but there is no fresh news."
        case .noGoodNews: "The model found no good news among today's items."
        case .outputDirectoryUnavailable(let detail): "The digest folder is unavailable: \(detail)"
        case .pagesFailed(let detail): detail
        case .timeout: "The run timed out."
        case .alreadyRunning: "A digest is already being prepared."
        case .unsupportedProtocol(let version):
            "Incompatible Gateway protocol version (\(version)). Reinstall the Gateway from the app."
        case .gatewayUnavailable(let detail):
            "The Gateway is not responding. Install or restart it in the settings. \(detail)"
        case .remote(let detail): detail
        }
    }
}

protocol GatewayClock: Sendable {
    var now: Date { get }
    /// Calendar in the Mac's *current* time zone; re-read on every call so travel is honored.
    var calendar: Calendar { get }
}

struct SystemGatewayClock: GatewayClock {
    var now: Date { Date() }
    var calendar: Calendar { Calendar.autoupdatingCurrent }
}
#endif
