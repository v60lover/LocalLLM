#if os(macOS)
import Foundation
import XCTest
@testable import LocalLLMChat

private actor FakeGateway: GatewayControlling {
    private(set) var config = DigestConfig()
    private(set) var updates = 0
    private let rejection: GatewayError?

    init(rejection: GatewayError? = nil) { self.rejection = rejection }

    func send(_ request: GatewayRequest) async throws -> GatewayStatus {
        if case .updateConfig(let new) = request {
            if let rejection { throw rejection }
            config = new
            updates += 1
        }
        return GatewayStatus(
            config: config, isRunning: false, nextRun: nil, timeZoneID: "UTC",
            lastRun: nil, attemptsToday: 0, lastSuccessDay: nil, startedAt: Date()
        )
    }
}

@MainActor
final class GatewaySettingsModelTests: XCTestCase {
    func testEditsAreSavedAutomaticallyWithChatModel() async throws {
        let gateway = FakeGateway()
        let model = GatewaySettingsModel(client: gateway)
        let reference = ModelReference(catalogID: "m", repo: "r", path: "p", revision: "main")
        model.currentModel = reference
        await model.refresh()

        model.draft.isEnabled = true
        model.draft.hour = 23
        model.draft.minute = 5
        try await Task.sleep(for: .seconds(1.2))

        let saved = await gateway.config
        XCTAssertTrue(saved.isEnabled)
        XCTAssertEqual(saved.hour, 23)
        XCTAssertEqual(saved.minute, 5)
        XCTAssertEqual(saved.model, reference)
    }

    func testUnfinishedSourceIsNotSentAndReportsReason() async throws {
        let gateway = FakeGateway()
        let model = GatewaySettingsModel(client: gateway)
        await model.refresh()

        model.draft.sources = ["https://"]
        try await Task.sleep(for: .seconds(1.2))

        let updates = await gateway.updates
        XCTAssertEqual(updates, 0)
        guard case .notSaved(let reason) = model.syncState else {
            return XCTFail("expected notSaved, got \(model.syncState)")
        }
        XCTAssertTrue(reason.contains("https://"))

        model.draft.sources = ["https://example.com/feed.xml"]
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertEqual(model.syncState, .saved)
    }

    func testGatewayRejectionStaysVisibleAcrossPolling() async throws {
        let gateway = FakeGateway(rejection: .invalidConfig("nope"))
        let model = GatewaySettingsModel(client: gateway)
        await model.refresh()

        model.draft.hour = 9
        try await Task.sleep(for: .seconds(1.2))
        await model.refresh()
        await model.refresh()

        XCTAssertEqual(model.syncState, .notSaved("nope"))
    }
}
#endif
