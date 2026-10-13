import Foundation
import XCTest
@testable import LocalLLMChat

final class GatewayIPCTests: XCTestCase {
    private var directory: URL!

    override func setUp() { directory = makeTemporaryDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func makeHandler(
        _ job: StubJob = StubJob(), clock: FakeClock = FakeClock(testDate(2026, 10, 2, 6)),
        ledger: GatewayRequestLedger = GatewayRequestLedger()
    ) -> (GatewayRequestHandler, GatewayEngine) {
        let engine = GatewayEngine(store: GatewayStateStore(directory: directory), job: job, clock: clock)
        return (GatewayRequestHandler(engine: engine, ledger: ledger), engine)
    }

    /// One request through the real handler, encoded and decoded like on the wire.
    private func call(
        _ handler: GatewayRequestHandler, _ request: GatewayRequest, id: UUID = UUID(),
        version: Int = GatewayConstants.protocolVersion, on connection: GatewayConnectionContext
    ) async throws -> GatewayReply {
        let data = try GatewayWire.encoder.encode(GatewayRequestEnvelope(version: version, requestID: id, request: request))
        let reply = await handler.handle(data, connection: connection)
        return try GatewayWire.decoder.decode(GatewayReplyEnvelope.self, from: reply).reply
    }

    /// A connection that already said hello.
    private func greeted(_ handler: GatewayRequestHandler) async throws -> GatewayConnectionContext {
        let connection = GatewayConnectionContext()
        let reply = try await call(handler, .hello(version: GatewayConstants.protocolVersion), on: connection)
        guard case .hello = reply else { throw XCTSkip("hello failed: \(reply)") }
        return connection
    }

    /// The happy path of every request kind on a greeted connection.
    func testStatusUpdateRunAndCancelRoundTrip() async throws {
        let (handler, engine) = makeHandler()
        let connection = try await greeted(handler)
        guard case .status(let initial) = try await call(handler, .status, on: connection) else { return XCTFail() }
        XCTAssertEqual(initial.protocolVersion, GatewayConstants.protocolVersion)
        XCTAssertFalse(initial.config.isEnabled)

        guard case .status(let updated) = try await call(handler, .updateConfig(enabledConfig(hour: 9, minute: 15)), on: connection) else { return XCTFail() }
        XCTAssertEqual(updated.config.hour, 9)
        XCTAssertEqual(updated.nextRun, testDate(2026, 10, 2, 9, 15))

        guard case .status(let running) = try await call(handler, .runNow, on: connection) else { return XCTFail() }
        XCTAssertTrue(running.isRunning || running.lastRun != nil)
        await engine.waitUntilIdle()
        guard case .status(let done) = try await call(handler, .cancelRun, on: connection) else { return XCTFail() }
        XCTAssertEqual(done.lastRun?.trigger, .manual)
        XCTAssertEqual(done.lastRun?.outcome, .succeeded(path: "/tmp/digest.pages", itemCount: 3))
    }

    /// Refusals carry a `kind` the client can branch on, not only a message.
    func testRunNowWhileBusyAndInvalidConfigAreReportedAsTypedFailures() async throws {
        let (handler, engine) = makeHandler(StubJob(hangingBehavior))
        let connection = try await greeted(handler)
        _ = try await call(handler, .updateConfig(enabledConfig()), on: connection)
        _ = try await call(handler, .runNow, on: connection)
        guard case .failure(let busy) = try await call(handler, .runNow, on: connection) else { return XCTFail("expected failure") }
        XCTAssertEqual(busy.kind, .alreadyRunning)
        XCTAssertEqual(busy.message, GatewayError.alreadyRunning.localizedDescription)
        await engine.cancelRun()
        await engine.waitUntilIdle()

        var invalid = enabledConfig()
        invalid.minute = 99
        guard case .failure(let failure) = try await call(handler, .updateConfig(invalid), on: connection) else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.kind, .invalidConfig)
    }

    // MARK: Handshake

    /// A repeated hello is answered the same way but must not subscribe the connection to
    /// pushes a second time.
    func testHelloReportsVersionAndInstanceAndFiresTheGreetedHookOnce() async throws {
        let (base, _) = makeHandler()
        let instance = UUID()
        let handler = GatewayRequestHandler(engine: base.engine, instanceID: instance)
        let greetings = GreetingCounter()
        let connection = GatewayConnectionContext(onGreeted: { greetings.increment() })
        for _ in 0..<2 {
            let reply = try await call(handler, .hello(version: GatewayConstants.protocolVersion), on: connection)
            XCTAssertEqual(reply, .hello(version: GatewayConstants.protocolVersion, instanceID: instance))
        }
        XCTAssertEqual(greetings.count, 1, "subscription must happen once per connection")
    }

    /// Without a handshake no request is served, and the refused ones leave no trace in the
    /// engine: no run, no config change.
    func testRequestsBeforeHelloAreRefusedAndChangeNothing() async throws {
        let job = StubJob()
        let (handler, engine) = makeHandler(job)
        let connection = GatewayConnectionContext()
        for request in [GatewayRequest.status, .runNow, .updateConfig(enabledConfig()), .cancelRun, .ping] {
            guard case .failure(let failure) = try await call(handler, request, on: connection) else {
                return XCTFail("\(request) was served before hello")
            }
            XCTAssertEqual(failure.kind, .handshakeRequired)
        }
        await engine.waitUntilIdle()
        XCTAssertEqual(job.callCount, 0)
        let status = await engine.status()
        XCTAssertFalse(status.isRunning)
        XCTAssertNil(status.lastRun)
        XCTAssertFalse(status.config.isEnabled)
    }

    /// A hello with the wrong version must not open the connection for later requests.
    func testHelloForAnotherVersionIsRejectedAndDoesNotGreet() async throws {
        let (handler, _) = makeHandler()
        let connection = GatewayConnectionContext()
        guard case .failure(let failure) = try await call(handler, .hello(version: 99), on: connection) else { return XCTFail() }
        XCTAssertEqual(failure.kind, .unsupportedProtocol)
        XCTAssertFalse(connection.hasGreeted)
    }

    /// Whatever arrives, the peer gets a typed failure it can decode, never silence.
    func testRejectsUnknownEnvelopeVersionAndMalformedPayloads() async throws {
        let (handler, _) = makeHandler()
        let connection = try await greeted(handler)
        guard case .failure(let failure) = try await call(handler, .status, version: 99, on: connection) else { return XCTFail() }
        XCTAssertEqual(failure.kind, .unsupportedProtocol)
        XCTAssertEqual(failure.message, GatewayError.unsupportedProtocol(99).localizedDescription)

        let reply = await handler.handle(Data("not json".utf8), connection: connection)
        let decoded = try GatewayWire.decoder.decode(GatewayReplyEnvelope.self, from: reply)
        guard case .failure(let malformed) = decoded.reply else { return XCTFail() }
        XCTAssertEqual(malformed.kind, .malformedRequest)
    }

    /// Old app, new agent. The literal bytes are what a protocol 1 build sent and can read;
    /// a round trip of today's types could not catch a break here.
    func testAProtocolOnePeerGetsAReplyInItsOwnShapeAndNothingRuns() async throws {
        // The shapes a protocol 1 build reads: {version, reply: .status(...) | .failure(String)}.
        struct OldStatus: Decodable {}
        enum OldReply: Decodable { case status(OldStatus), failure(String) }
        struct OldEnvelope: Decodable { var version: Int; var reply: OldReply }

        let job = StubJob()
        let (handler, engine) = makeHandler(job)
        // Exactly what a protocol 1 app sent: no requestID, no hello.
        let request = Data(#"{"version":1,"request":{"runNow":{}}}"#.utf8)
        let data = await handler.handle(request, connection: GatewayConnectionContext())
        let old = try JSONDecoder().decode(OldEnvelope.self, from: data)
        XCTAssertEqual(old.version, 1)
        guard case .failure(let message) = old.reply else { return XCTFail("expected a failure it can show") }
        XCTAssertEqual(message, GatewayError.unsupportedProtocol(1).localizedDescription)
        await engine.waitUntilIdle()
        XCTAssertEqual(job.callCount, 0)
    }

    // MARK: Request IDs

    /// At most once per request ID: the second copy gets the first one's reply and no second run.
    func testADuplicateRunNowIsNotExecutedAgainAndGetsTheStoredReply() async throws {
        let job = StubJob()
        let (handler, engine) = makeHandler(job)
        let connection = try await greeted(handler)
        _ = try await call(handler, .updateConfig(enabledConfig()), on: connection)
        let id = UUID()
        let first = try await call(handler, .runNow, id: id, on: connection)
        await engine.waitUntilIdle()   // the run is over, so a re-executed runNow would start a second one
        let second = try await call(handler, .runNow, id: id, on: connection)
        await engine.waitUntilIdle()
        XCTAssertEqual(second, first)
        XCTAssertEqual(job.callCount, 1)
    }

    /// The ledger belongs to the process, not to a connection, which is what makes recovery after a reconnect possible.
    func testRequestStatusReturnsTheStoredReplyOnAnotherConnection() async throws {
        let (handler, engine) = makeHandler()
        let connection = try await greeted(handler)
        let id = UUID()
        let original = try await call(handler, .runNow, id: id, on: connection)
        await engine.waitUntilIdle()

        let reconnected = try await greeted(handler)   // what a client does after a lost connection
        let known = try await call(handler, .requestStatus(id), on: reconnected)
        XCTAssertEqual(known, .requestState(.completed(original)))
        let unknown = try await call(handler, .requestStatus(UUID()), on: reconnected)
        XCTAssertEqual(unknown, .requestState(.unknown))
    }

    /// A duplicate that arrives while the original is still executing must not start a second execution.
    func testARequestStillInProgressIsReportedAsSuchAndNotRunAgain() async throws {
        let job = StubJob()
        let ledger = GatewayRequestLedger()
        let (handler, engine) = makeHandler(job, ledger: ledger)
        let connection = try await greeted(handler)
        let id = UUID()
        _ = await ledger.begin(id)   // the original is mid-flight

        guard case .failure(let failure) = try await call(handler, .runNow, id: id, on: connection) else { return XCTFail() }
        XCTAssertEqual(failure.kind, .requestInProgress)
        let state = try await call(handler, .requestStatus(id), on: connection)
        XCTAssertEqual(state, .requestState(.inProgress))
        await engine.waitUntilIdle()
        XCTAssertEqual(job.callCount, 0)
    }

    /// The ledger cannot grow without limit; what falls out is reported as `unknown`.
    func testLedgerIsBoundedAndForgetsTheOldestFirst() async {
        let ledger = GatewayRequestLedger(capacity: 3)
        let ids = (0..<4).map { _ in UUID() }
        for id in ids {
            let begin = await ledger.begin(id)
            XCTAssertEqual(begin, .fresh)
            await ledger.complete(id, with: .pong)
        }
        let count = await ledger.count
        XCTAssertEqual(count, 3)
        let oldest = await ledger.state(of: ids[0])
        XCTAssertEqual(oldest, .unknown)
        let newest = await ledger.state(of: ids[3])
        XCTAssertEqual(newest, .completed(.pong))
    }

    func testConfigNeverCarriesCredentials() throws {
        let data = try GatewayWire.encoder.encode(enabledConfig())
        let keys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        XCTAssertEqual(keys, ["isEnabled", "sources", "outputDirectory", "hour", "minute", "model"])
    }
}

final class GreetingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
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
