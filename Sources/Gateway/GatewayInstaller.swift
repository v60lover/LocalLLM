#if os(macOS)
import Foundation

protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessRunner.Output
}

struct SystemCommandRunner: CommandRunning {
    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessRunner.Output {
        try await ProcessRunner.run(executable, arguments)
    }
}

/// Registers the bundled Gateway executable as a per-user launchd agent.
struct GatewayInstaller: Sendable {
    var executableURL: URL
    var launchAgentsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LaunchAgents", isDirectory: true)
    var logsDirectory = GatewayPaths.logsDirectory
    var userID = getuid()
    var runner: any CommandRunning = SystemCommandRunner()

    static func bundled() -> GatewayInstaller {
        GatewayInstaller(
            executableURL: Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS/\(GatewayConstants.executableName)")
        )
    }

    var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(GatewayConstants.label).plist")
    }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }
    var executableExists: Bool { FileManager.default.isExecutableFile(atPath: executableURL.path) }

    func plistData() throws -> Data {
        let plist: [String: Any] = [
            "Label": GatewayConstants.label,
            "ProgramArguments": [executableURL.path],
            "MachServices": [GatewayConstants.machServiceName: true],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            // Pages must be driven from the logged-in GUI session.
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": logsDirectory.appendingPathComponent("gateway.log").path,
            "StandardErrorPath": logsDirectory.appendingPathComponent("gateway.log").path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Writes the plist and (re)loads the agent so a new app build takes over immediately.
    func install() async throws {
        guard executableExists else {
            throw GatewayError.gatewayUnavailable("The Gateway executable was not found in the app.")
        }
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try plistData().write(to: plistURL, options: .atomic)
        _ = try? await runner.run("/bin/launchctl", ["bootout", "gui/\(userID)/\(GatewayConstants.label)"])
        let result = try await runner.run("/bin/launchctl", ["bootstrap", "gui/\(userID)", plistURL.path])
        guard result.status == 0 else {
            throw GatewayError.gatewayUnavailable(
                "launchctl: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }

    func uninstall() async throws {
        _ = try? await runner.run("/bin/launchctl", ["bootout", "gui/\(userID)/\(GatewayConstants.label)"])
        if isInstalled { try FileManager.default.removeItem(at: plistURL) }
    }
}
#endif
