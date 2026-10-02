import CoreAIKit
import XCTest
@testable import LocalLLMChat

/// End-to-end check against the real launchd agent, XPC, cached model, network and Pages.
/// Opt in with `TEST_RUNNER_GATEWAY_LIVE_SMOKE=1 xcodebuild test ...`; it opens a Pages window.
final class GatewayLiveSmokeTests: XCTestCase {
    func testInstalledGatewayBuildsAndOpensADigestEndToEnd() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GATEWAY_LIVE_SMOKE"] == "1")
        let catalog = await ModelCatalog.load()
        let entry = try XCTUnwrap(catalog.available(.chat).first(where: { $0.id == "qwen3-4b" }))
        let id = try XCTUnwrap(entry.modelID)
        try XCTSkipIf(ModelStore.default.localURL(for: id) == nil, "qwen3-4b is not cached")

        let installer = GatewayInstaller.bundled()
        try await installer.install()
        let client = GatewayXPCClient()
        var restored = false
        defer {
            if !restored { Task { try? await installer.uninstall() } }
        }

        var status: GatewayStatus?
        for _ in 0..<20 where status == nil {
            status = try? await client.send(.status)
            if status == nil { try await Task.sleep(for: .milliseconds(500)) }
        }
        XCTAssertNotNil(status, "Gateway did not answer over XPC")

        let output = makeTemporaryDirectory()
        var config = DigestConfig()
        config.isEnabled = false
        config.outputDirectory = output.path
        config.model = ModelReference(catalogID: entry.id, repo: id.repo, path: id.path, revision: id.revision)
        _ = try await client.send(.updateConfig(config))
        _ = try await client.send(.runNow)

        var finished: RunRecord?
        for _ in 0..<300 {
            try await Task.sleep(for: .seconds(2))
            let current = try await client.send(.status)
            if !current.isRunning, let run = current.lastRun, run.outcome != .running {
                finished = run
                break
            }
        }
        let run = try XCTUnwrap(finished, "digest did not finish in time")
        guard case .succeeded(let path, let count) = run.outcome else {
            return XCTFail("digest failed: \(run.outcome)")
        }
        XCTAssertGreaterThan(count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(path.hasPrefix(output.path))

        _ = try await client.send(.updateConfig(DigestConfig()))
        try await installer.uninstall()
        restored = true
    }
}
