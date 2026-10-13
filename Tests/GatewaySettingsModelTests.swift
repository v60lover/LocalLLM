#if os(macOS)
import Foundation
import XCTest
@testable import LocalLLMChat

/// Stands in for `GatewayClient`: answers requests from memory, counts them, and lets a test
/// push events through the same stream the model reads in production.
private actor FakeGateway: GatewayControlling {
    private(set) var config = DigestConfig()
    private(set) var updates = 0
    /// How often `.status` was asked for; shows whether anything polls.
    private(set) var statusRequests = 0
    private(set) var isStarted = false
    private(set) var isStopped = false
    /// When set, every `updateConfig` is refused with it.
    private let rejection: GatewayError?
    private var scripted: GatewayStatus?

    nonisolated let events: AsyncStream<GatewayClientEvent>
    private nonisolated let continuation: AsyncStream<GatewayClientEvent>.Continuation

    init(rejection: GatewayError? = nil) {
        self.rejection = rejection
        (events, continuation) = AsyncStream.makeStream(of: GatewayClientEvent.self)
    }

    func start() { isStarted = true }

    /// Final, like the real client: the events end and later requests fail.
    func stop() {
        isStopped = true
        continuation.finish()
    }

    /// What the Gateway pushes.
    nonisolated func emit(_ event: GatewayClientEvent) { continuation.yield(event) }
    /// Every later request is answered with exactly this status.
    func script(reply: GatewayStatus) { scripted = reply }

    func send(_ request: GatewayRequest) async throws -> GatewayStatus {
        if isStopped { throw GatewayError.gatewayUnavailable("stopped") }
        if case .status = request { statusRequests += 1 }
        if case .updateConfig(let new) = request {
            if let rejection { throw rejection }
            config = new
            updates += 1
        }
        if let scripted { return scripted }
        return GatewayStatus(
            config: config, isRunning: false, nextRun: nil, timeZoneID: "UTC",
            lastRun: nil, attemptsToday: 0, lastSuccessDay: nil, startedAt: Date()
        )
    }
}

@MainActor
final class GatewaySettingsModelTests: XCTestCase {
    /// Polls until the condition holds (or fails after ~5 s).
    private func settle(_ message: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let holds = await condition()
        XCTAssertTrue(holds, message)
    }

    /// `startedAt` identifies the Gateway process and `revision` orders statuses within it.
    private func makeStatus(
        revision: Int? = nil, isRunning: Bool = false, startedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> GatewayStatus {
        GatewayStatus(
            config: DigestConfig(), isRunning: isRunning, nextRun: nil, timeZoneID: "UTC",
            lastRun: nil, attemptsToday: 0, lastSuccessDay: nil, startedAt: startedAt, revision: revision
        )
    }

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

    /// A refused save must stay on screen: neither a refresh, nor a pushed status, nor a
    /// reconnect may quietly turn "not saved" back into "saved".
    func testGatewayRejectionStaysVisibleAcrossStatusUpdates() async throws {
        let gateway = FakeGateway(rejection: .invalidConfig("nope"))
        let model = GatewaySettingsModel(client: gateway)
        await model.refresh()

        model.draft.hour = 9
        try await Task.sleep(for: .seconds(1.2))
        await model.refresh()
        await model.handle(.status(makeStatus()))
        await model.handle(.connected(instanceID: UUID()))

        XCTAssertEqual(model.syncState, .notSaved("nope"))
    }

    /// The whole event path through `start()`: pushes update the window, a disconnect shows
    /// its reason, a later push clears it, and the status is asked for once.
    func testStatusIsFollowedThroughPushedEventsWithoutPolling() async throws {
        let gateway = FakeGateway()
        let model = GatewaySettingsModel(client: gateway)
        model.start()
        try await settle("initial status") { model.isReachable }
        let started = await gateway.isStarted
        XCTAssertTrue(started, "the model starts the client's heartbeat")

        var pushed = makeStatus(isRunning: true)
        pushed.timeZoneID = "Pacific/Auckland"
        gateway.emit(.status(pushed))
        try await settle("pushed status shown") { model.status?.timeZoneID == "Pacific/Auckland" }
        XCTAssertEqual(model.status?.isRunning, true)

        gateway.emit(.disconnected(reason: "The connection to the Gateway was interrupted."))
        try await settle("unreachable") { !model.isReachable }
        XCTAssertEqual(model.errorMessage, "The connection to the Gateway was interrupted.")

        gateway.emit(.status(pushed))
        try await settle("a later push makes the Gateway reachable again") { model.isReachable }
        XCTAssertNil(model.errorMessage)

        let requests = await gateway.statusRequests
        XCTAssertEqual(requests, 1, "only the first refresh asks; nothing polls afterwards")

        model.stop()
        try await settle("the client is stopped with the window") { await gateway.isStopped }
    }

    /// After a reconnect the Gateway may be a new process, so the status is read again: once
    /// per `connected`, not in a loop.
    func testReconnectingAsksForTheStatusOnce() async throws {
        let gateway = FakeGateway()
        let model = GatewaySettingsModel(client: gateway)
        model.start()
        try await settle("initial status") { model.isReachable }

        gateway.emit(.disconnected(reason: "gone"))
        try await settle("unreachable") { !model.isReachable }
        gateway.emit(.connected(instanceID: UUID()))
        try await settle("reachable again") { model.isReachable }

        let requests = await gateway.statusRequests
        XCTAssertEqual(requests, 2)
        model.stop()
    }

    /// Replies and pushes are unordered. An older reply must not overwrite a newer push from
    /// the same Gateway process, while a restarted Gateway (revision back at 0) must still be shown.
    func testAReplyOlderThanAPushedStatusDoesNotReplaceIt() async throws {
        let gateway = FakeGateway()
        let model = GatewaySettingsModel(client: gateway)
        // The push "run finished" overtook the reply to runNow, which was computed earlier.
        await gateway.script(reply: makeStatus(revision: 4, isRunning: true))
        await model.handle(.status(makeStatus(revision: 5, isRunning: false)))

        await model.runNow(model: nil)

        XCTAssertEqual(model.status?.revision, 5)
        XCTAssertEqual(model.status?.isRunning, false, "the run must not be shown as still running")

        // A restarted Gateway counts from zero again and is not mistaken for an old status.
        let restarted = makeStatus(revision: 0, isRunning: true, startedAt: Date(timeIntervalSince1970: 2_000))
        await model.handle(.status(restarted))
        XCTAssertEqual(model.status, restarted)
    }

    /// Stopping the client is final, so an edit still inside the auto-save delay has to be
    /// sent before it, or closing the window would lose it.
    func testClosingSendsAPendingEditBeforeTheClientIsStopped() async throws {
        let gateway = FakeGateway()
        let model = GatewaySettingsModel(client: gateway)
        await model.refresh()

        model.draft.hour = 21   // the automatic save is still waiting out its delay
        model.stop()

        try await settle("client stopped") { await gateway.isStopped }
        let saved = await gateway.config
        XCTAssertEqual(saved.hour, 21, "the edit reached the Gateway before the connection was closed")
    }
}
#endif
