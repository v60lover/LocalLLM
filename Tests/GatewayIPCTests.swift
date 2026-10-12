import Foundation
import XCTest
@testable import LocalLLMChat

final class GatewayIPCTests: XCTestCase {
    private var directory: URL!

    override func setUp() { directory = makeTemporaryDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func handler(_ job: StubJob = StubJob(), clock: FakeClock = FakeClock(testDate(2026, 10, 2, 6))) -> (GatewayRequestHandler, GatewayEngine) {
        let engine = GatewayEngine(store: GatewayStateStore(directory: directory), job: job, clock: clock)
        return (GatewayRequestHandler(engine: engine), engine)
    }

    private func call(_ handler: GatewayRequestHandler, _ request: GatewayRequest, version: Int = GatewayConstants.protocolVersion) async throws -> GatewayReply {
        let data = try GatewayWire.encoder.encode(GatewayRequestEnvelope(version: version, request: request))
        let reply = await handler.handle(data)
        return try GatewayWire.decoder.decode(GatewayReplyEnvelope.self, from: reply).reply
    }

    func testStatusUpdateRunAndCancelRoundTrip() async throws {
        let (handler, engine) = handler()
        guard case .status(let initial) = try await call(handler, .status) else { return XCTFail() }
        XCTAssertEqual(initial.protocolVersion, GatewayConstants.protocolVersion)
        XCTAssertFalse(initial.config.isEnabled)

        guard case .status(let updated) = try await call(handler, .updateConfig(enabledConfig(hour: 9, minute: 15))) else { return XCTFail() }
        XCTAssertEqual(updated.config.hour, 9)
        XCTAssertEqual(updated.nextRun, testDate(2026, 10, 2, 9, 15))

        guard case .status(let running) = try await call(handler, .runNow) else { return XCTFail() }
        XCTAssertTrue(running.isRunning || running.lastRun != nil)
        await engine.waitUntilIdle()
        guard case .status(let done) = try await call(handler, .cancelRun) else { return XCTFail() }
        XCTAssertEqual(done.lastRun?.trigger, .manual)
        XCTAssertEqual(done.lastRun?.outcome, .succeeded(path: "/tmp/digest.pages", itemCount: 3))
    }

    func testRunNowWhileBusyAndInvalidConfigAreReportedAsFailures() async throws {
        let (handler, engine) = handler(StubJob(hangingBehavior))
        _ = try await call(handler, .updateConfig(enabledConfig()))
        _ = try await call(handler, .runNow)
        guard case .failure(let busy) = try await call(handler, .runNow) else { return XCTFail("expected failure") }
        XCTAssertEqual(busy, GatewayError.alreadyRunning.localizedDescription)
        await engine.cancelRun()
        await engine.waitUntilIdle()

        var invalid = enabledConfig()
        invalid.minute = 99
        guard case .failure = try await call(handler, .updateConfig(invalid)) else { return XCTFail("expected failure") }
    }

    func testRejectsUnknownProtocolVersionAndMalformedPayloads() async throws {
        let (handler, _) = handler()
        guard case .failure(let message) = try await call(handler, .status, version: 99) else { return XCTFail() }
        XCTAssertEqual(message, GatewayError.unsupportedProtocol(99).localizedDescription)

        let reply = await handler.handle(Data("not json".utf8))
        let decoded = try GatewayWire.decoder.decode(GatewayReplyEnvelope.self, from: reply)
        guard case .failure = decoded.reply else { return XCTFail() }
    }

    func testConfigNeverCarriesCredentials() throws {
        let data = try GatewayWire.encoder.encode(enabledConfig())
        let keys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        XCTAssertEqual(keys, ["isEnabled", "sources", "outputDirectory", "hour", "minute", "model"])
    }
}

final class GatewayInstallerTests: XCTestCase {
    private final class FakeRegistration: AgentRegistering, @unchecked Sendable {
        var status: AgentRegistrationStatus = .notRegistered
        var registerResult: AgentRegistrationStatus = .enabled
        var registerError: Error?
        private(set) var calls: [String] = []
        func register() throws {
            calls.append("register")
            if let registerError { status = registerResult; throw registerError }
            status = registerResult
        }
        func unregister() async throws {
            calls.append("unregister")
            status = .notRegistered
        }
    }

    private actor RecordingRunner: CommandRunning {
        private(set) var commands: [[String]] = []
        func run(_ executable: String, _ arguments: [String]) async throws -> ProcessRunner.Output {
            commands.append([executable] + arguments)
            return ProcessRunner.Output(status: 0, stderr: "")
        }
    }

    private struct Rig {
        var installer: GatewayInstaller
        var registration: FakeRegistration
        var runner: RecordingRunner
        var root: URL
    }

    /// Builds a fake app bundle; `complete: false` leaves out the helper executable.
    private func makeRig(complete: Bool = true) throws -> Rig {
        let root = makeTemporaryDirectory()
        let app = root.appendingPathComponent("LocalLLMChat.app", isDirectory: true)
        let registration = FakeRegistration()
        let runner = RecordingRunner()
        var installer = GatewayInstaller(
            appURL: app, registration: registration,
            legacyLaunchAgentsDirectory: root.appendingPathComponent("LaunchAgents"), userID: 501,
            runner: runner
        )
        if complete {
            let fm = FileManager.default
            try fm.createDirectory(at: installer.executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: installer.embeddedWorkerURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: installer.agentPlistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: installer.executableURL)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installer.executableURL.path)
            try Data("<plist/>".utf8).write(to: installer.agentPlistURL)
        }
        installer.registration = registration
        return Rig(installer: installer, registration: registration, runner: runner, root: root)
    }

    func testBundledAgentPlistDescribesAPerUserKeepAliveMachServiceInTheGUISession() throws {
        // The test host is the app itself, so this checks the plist that actually ships.
        let plistURL = GatewayInstaller.bundled().agentPlistURL
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL), format: nil
        ) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, GatewayConstants.label)
        XCTAssertEqual(
            plist["BundleProgram"] as? String,
            "Contents/Library/LoginItems/\(GatewayConstants.helperAppName)/Contents/MacOS/\(GatewayConstants.executableName)"
        )
        XCTAssertNil(plist["ProgramArguments"])
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")
        XCTAssertEqual((plist["MachServices"] as? [String: Bool])?[GatewayConstants.machServiceName], true)
        XCTAssertEqual(plistURL.lastPathComponent, "\(GatewayConstants.label).plist")
    }

    func testBundledAppEmbedsTheGatewayHelperWithItsWorker() {
        let installer = GatewayInstaller.bundled()
        XCTAssertTrue(installer.executableExists, "helper executable missing at \(installer.executableURL.path)")
        XCTAssertTrue(installer.workerEmbedded, "worker missing at \(installer.embeddedWorkerURL.path)")
        // The service name the Gateway dials is the embedded bundle's identifier.
        let worker = Bundle(url: installer.embeddedWorkerURL)
        XCTAssertEqual(worker?.bundleIdentifier, WorkerConstants.serviceName)
    }

    func testInstallRegistersAgentAndUninstallUnregistersIt() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        XCTAssertFalse(rig.installer.isInstalled)
        try await rig.installer.install()
        XCTAssertTrue(rig.installer.isInstalled)
        XCTAssertEqual(rig.registration.calls, ["register"])
        try await rig.installer.uninstall()
        XCTAssertFalse(rig.installer.isInstalled)
        XCTAssertEqual(rig.registration.calls, ["register", "unregister"])
    }

    func testReinstallReloadsAnAlreadyRegisteredAgent() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        rig.registration.status = .enabled
        try await rig.installer.install()
        XCTAssertEqual(rig.registration.calls, ["unregister", "register"])
    }

    func testInstallFailsClearlyWhenTheBundleIsIncomplete() async throws {
        let rig = try makeRig(complete: false)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        await XCTAssertThrowsGatewayError { try await rig.installer.install() }
        XCTAssertEqual(rig.registration.calls, [])
    }

    func testInstallReportsPendingApprovalAndKeepsTheRegistration() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        rig.registration.registerResult = .requiresApproval
        rig.registration.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        do {
            try await rig.installer.install()
            XCTFail("expected an approval error")
        } catch let error as GatewayError {
            XCTAssertTrue(error.localizedDescription.contains("Login Items"), error.localizedDescription)
        }
        XCTAssertTrue(rig.installer.isInstalled, "a pending item still counts as installed")
    }

    func testInstallSurfacesARealRegistrationFailure() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        rig.registration.registerResult = .notRegistered
        rig.registration.registerError = NSError(
            domain: "SMAppServiceErrorDomain", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "boom"]
        )
        await XCTAssertThrowsGatewayError { try await rig.installer.install() }
        XCTAssertFalse(rig.installer.isInstalled)
    }

    func testInstallRemovesTheLegacyHandWrittenAgent() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let legacy = rig.installer.legacyPlistURL
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: legacy)
        try await rig.installer.install()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let commands = await rig.runner.commands
        XCTAssertEqual(commands.map { $0[1] }, ["bootout"])
        XCTAssertEqual(commands[0][2], "gui/501/\(GatewayConstants.label)")
    }
}
