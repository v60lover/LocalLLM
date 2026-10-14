import Foundation
import ServiceManagement

protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessRunner.Output
}

struct SystemCommandRunner: CommandRunning {
    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessRunner.Output {
        try await ProcessRunner.run(executable, arguments)
    }
}

enum AgentRegistrationStatus: Equatable, Sendable {
    case notRegistered, enabled
    /// Registered, but the user has to allow it in System Settings > Login Items.
    case requiresApproval
    /// The agent plist is missing from the app bundle (or the app was moved).
    case notFound
}

/// The launchd side of installation, behind a seam so tests do not touch the real login items.
protocol AgentRegistering: Sendable {
    var status: AgentRegistrationStatus { get }
    func register() throws
    func unregister() async throws
}

/// `SMAppService.agent`: launchd reads the plist from `Contents/Library/LaunchAgents` of the app.
struct SMAppServiceAgent: AgentRegistering {
    var plistName: String

    private var service: SMAppService { SMAppService.agent(plistName: plistName) }

    var status: AgentRegistrationStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notRegistered
        }
    }

    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
}

/// Registers the Gateway helper app (inside the app bundle) as a per-user launchd agent.
///
/// The Gateway is `Contents/Library/LoginItems/LocalLLMGateway.app` so that the worker XPC
/// service embedded in it can be found; the agent plist (MachServices, KeepAlive, Aqua) is
/// shipped in `Contents/Library/LaunchAgents` and references the executable with `BundleProgram`.
struct GatewayInstaller: Sendable {
    var appURL: URL
    var registration: any AgentRegistering
    /// Where earlier builds wrote a hand-made plist (loaded with `launchctl bootstrap`).
    var legacyLaunchAgentsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LaunchAgents", isDirectory: true)
    var userID = getuid()
    var runner: any CommandRunning = SystemCommandRunner()

    static func bundled() -> GatewayInstaller {
        GatewayInstaller(
            appURL: Bundle.main.bundleURL,
            registration: SMAppServiceAgent(plistName: GatewayConstants.agentPlistName)
        )
    }

    var helperURL: URL {
        appURL.appendingPathComponent("Contents/Library/LoginItems/\(GatewayConstants.helperAppName)", isDirectory: true)
    }
    var executableURL: URL {
        helperURL.appendingPathComponent("Contents/MacOS/\(GatewayConstants.executableName)")
    }
    var embeddedWorkerURL: URL {
        helperURL.appendingPathComponent("Contents/XPCServices/\(GatewayConstants.workerBundleName)", isDirectory: true)
    }
    var agentPlistURL: URL {
        appURL.appendingPathComponent("Contents/Library/LaunchAgents/\(GatewayConstants.agentPlistName)")
    }
    var legacyPlistURL: URL {
        legacyLaunchAgentsDirectory.appendingPathComponent("\(GatewayConstants.label).plist")
    }

    var status: AgentRegistrationStatus { registration.status }
    var isInstalled: Bool { status == .enabled || status == .requiresApproval }
    var executableExists: Bool { FileManager.default.isExecutableFile(atPath: executableURL.path) }
    var workerEmbedded: Bool { FileManager.default.fileExists(atPath: embeddedWorkerURL.path) }

    /// (Re)registers the agent so a new app build takes over immediately.
    func install() async throws {
        guard executableExists, FileManager.default.fileExists(atPath: agentPlistURL.path) else {
            throw GatewayError.gatewayUnavailable("The Gateway was not found in the app.")
        }
        await removeLegacyAgent()
        if registration.status != .notRegistered, registration.status != .notFound {
            try? await registration.unregister()
        }
        do {
            try registration.register()
        } catch {
            // Registering fails with this code when the user has not approved the item yet; the
            // status below tells that case apart from a real failure.
            if registration.status != .requiresApproval {
                throw GatewayError.gatewayUnavailable(error.localizedDescription)
            }
        }
        if registration.status == .requiresApproval {
            throw GatewayError.gatewayUnavailable(
                "Allow LocalLLMChat in System Settings → General → Login Items & Extensions, then try again."
            )
        }
    }

    func uninstall() async throws {
        await removeLegacyAgent()
        if registration.status != .notRegistered, registration.status != .notFound {
            try await registration.unregister()
        }
    }

    /// Builds before the helper bundle loaded a hand-written plist from ~/Library/LaunchAgents.
    /// Left in place it would race the new agent for the same Mach service name.
    private func removeLegacyAgent() async {
        guard FileManager.default.fileExists(atPath: legacyPlistURL.path) else { return }
        _ = try? await runner.run("/bin/launchctl", ["bootout", "gui/\(userID)/\(GatewayConstants.label)"])
        try? FileManager.default.removeItem(at: legacyPlistURL)
    }
}
