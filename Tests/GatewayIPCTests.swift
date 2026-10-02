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
    private actor RecordingRunner: CommandRunning {
        private(set) var commands: [[String]] = []
        var bootstrapStatus: Int32 = 0
        func setBootstrapStatus(_ status: Int32) { bootstrapStatus = status }
        func run(_ executable: String, _ arguments: [String]) async throws -> ProcessRunner.Output {
            commands.append([executable] + arguments)
            return ProcessRunner.Output(status: arguments.first == "bootstrap" ? bootstrapStatus : 0, stderr: bootstrapStatus == 0 ? "" : "boom")
        }
    }

    private func makeInstaller(_ runner: RecordingRunner, root: URL, executable: Bool = true) throws -> GatewayInstaller {
        let binary = root.appendingPathComponent("LocalLLMGateway")
        if executable {
            try Data("#!/bin/sh\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        return GatewayInstaller(
            executableURL: binary, launchAgentsDirectory: root.appendingPathComponent("LaunchAgents"),
            logsDirectory: root.appendingPathComponent("Logs"), userID: 501, runner: runner
        )
    }

    func testPlistDescribesAPerUserKeepAliveMachServiceInTheGUISession() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = try makeInstaller(RecordingRunner(), root: root)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: installer.plistData(), format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, GatewayConstants.label)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [installer.executableURL.path])
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")
        XCTAssertEqual((plist["MachServices"] as? [String: Bool])?[GatewayConstants.machServiceName], true)
    }

    func testInstallWritesPlistThenReloadsAgentAndUninstallRemovesIt() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingRunner()
        let installer = try makeInstaller(runner, root: root)
        XCTAssertFalse(installer.isInstalled)
        try await installer.install()
        XCTAssertTrue(installer.isInstalled)
        let commands = await runner.commands
        XCTAssertEqual(commands.map { $0[1] }, ["bootout", "bootstrap"])
        XCTAssertEqual(commands[1][2], "gui/501")
        try await installer.uninstall()
        XCTAssertFalse(installer.isInstalled)
    }

    func testInstallFailsClearlyWithoutBundledExecutableOrWhenLaunchctlRejects() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = try makeInstaller(RecordingRunner(), root: root, executable: false)
        await XCTAssertThrowsGatewayError { try await missing.install() }

        let runner = RecordingRunner()
        await runner.setBootstrapStatus(5)
        let installer = try makeInstaller(runner, root: root)
        await XCTAssertThrowsGatewayError { try await installer.install() }
    }
}
