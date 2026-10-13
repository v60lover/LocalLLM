import Foundation
import XCTest
@testable import LocalLLMChat

final class GatewayEngineTests: XCTestCase {
    private var directory: URL!
    private var store: GatewayStateStore!

    override func setUp() {
        directory = makeTemporaryDirectory()
        store = GatewayStateStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeEngine(
        _ job: StubJob, clock: FakeClock, config: DigestConfig? = enabledConfig(), timeout: Duration = .seconds(60)
    ) async throws -> GatewayEngine {
        let engine = GatewayEngine(store: store, job: job, clock: clock, timeout: timeout)
        if let config { try await engine.updateConfig(config) }
        return engine
    }

    // MARK: Change reports

    /// Counts the engine's change reports.
    private final class ChangeCounter: GatewayChangeObserver, @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func gatewayDidChange() { lock.withLock { value += 1 } }
    }

    /// Nothing polls the status, so a change caused by the clock alone has to be reported by
    /// the engine itself, once, and without starting a run.
    func testAStatusFieldThatMovesWithTheClockAloneIsReportedOnTheNextTick() async throws {
        let clock = FakeClock(testDate(2026, 10, 2, 6))
        let changes = ChangeCounter()
        let engine = GatewayEngine(store: store, job: StubJob(), clock: clock, observer: changes)
        try await engine.updateConfig(enabledConfig(hour: 9))
        await engine.tick()
        XCTAssertEqual(changes.count, 1, "nothing moved since the config was saved")

        // 06:00 in Moscow is 04:00 in London: the 09:00 slot is still ahead, so no run starts,
        // but the time zone and the next run shown to the user are different now.
        clock.setZone("Europe/London")
        await engine.tick()
        XCTAssertEqual(changes.count, 2)
        let moved = await engine.status()
        XCTAssertEqual(moved.timeZoneID, "Europe/London")
        XCTAssertEqual(moved.revision, 2)

        await engine.tick()
        XCTAssertEqual(changes.count, 2, "reported once, not on every tick")
        let job = await engine.status()
        XCTAssertFalse(job.isRunning)
    }

    /// The revision is what lets the app order a reply against a push, so every reported
    /// change must raise it by exactly one.
    func testEveryReportedChangeRaisesTheStatusRevision() async throws {
        let changes = ChangeCounter()
        let engine = GatewayEngine(
            store: store, job: StubJob(), clock: FakeClock(testDate(2026, 10, 2, 6)), observer: changes
        )
        let initial = await engine.status()
        XCTAssertEqual(initial.revision, 0)

        try await engine.updateConfig(enabledConfig())
        let saved = await engine.status()
        try await engine.startRun(.manual)
        let started = await engine.status()
        await engine.waitUntilIdle()
        let finished = await engine.status()

        XCTAssertEqual([saved.revision, started.revision, finished.revision], [1, 2, 3])
        XCTAssertEqual(changes.count, 3)
    }

    func testUnreadableStateIsMovedAsideInsteadOfOverwritten() throws {
        try Data("not json".utf8).write(to: store.fileURL)

        let state = store.load()
        try store.save(state)

        XCTAssertEqual(state, GatewayPersistedState())
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("state.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        let kept = try Data(contentsOf: directory.appendingPathComponent(backups[0]))
        XCTAssertEqual(String(decoding: kept, as: UTF8.self), "not json")
    }

    func testMissingStateFileIsNotTreatedAsCorruption() throws {
        XCTAssertEqual(store.load(), GatewayPersistedState())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testTickBeforeSlotDoesNothingAndAtSlotRunsOnce() async throws {
        let clock = FakeClock(testDate(2026, 10, 2, 7, 59))
        let job = StubJob()
        let engine = try await makeEngine(job, clock: clock)

        await engine.tick()
        await engine.waitUntilIdle()
        XCTAssertEqual(job.callCount, 0)

        clock.set(testDate(2026, 10, 2, 8, 0))
        await engine.tick()
        await engine.waitUntilIdle()
        XCTAssertEqual(job.callCount, 1)
        let status = await engine.status()
        XCTAssertEqual(status.lastRun?.outcome, .succeeded(path: "/tmp/digest.pages", itemCount: 3))
        XCTAssertEqual(status.lastRun?.trigger, .scheduled)
        XCTAssertEqual(status.lastSuccessDay, "2026-10-02")
        XCTAssertEqual(status.nextRun, testDate(2026, 10, 3, 8))
        XCTAssertFalse(status.isRunning)
    }

    func testRepeatedTicksNeverDuplicateTheDaysSend() async throws {
        let clock = FakeClock(testDate(2026, 10, 2, 8, 0))
        let job = StubJob()
        let engine = try await makeEngine(job, clock: clock)
        for _ in 0..<5 {
            await engine.tick()
            await engine.waitUntilIdle()
            clock.advance(3600)
        }
        XCTAssertEqual(job.callCount, 1)
    }

    func testRestartAfterSuccessDoesNotDuplicate() async throws {
        let clock = FakeClock(testDate(2026, 10, 2, 8, 0))
        let job = StubJob()
        let first = try await makeEngine(job, clock: clock)
        await first.tick()
        await first.waitUntilIdle()
        XCTAssertEqual(job.callCount, 1)

        clock.advance(7200)
        let restarted = try await makeEngine(job, clock: clock, config: nil)
        await restarted.tick()
        await restarted.waitUntilIdle()
        XCTAssertEqual(job.callCount, 1)
        let status = await restarted.status()
        XCTAssertEqual(status.config, enabledConfig())
        XCTAssertEqual(status.lastRun?.trigger, .scheduled)

        clock.set(testDate(2026, 10, 3, 8, 0))
        await restarted.tick()
        await restarted.waitUntilIdle()
        XCTAssertEqual(job.callCount, 2)
    }

    func testMissedRunIsMadeUpAfterWake() async throws {
        let clock = FakeClock(testDate(2026, 10, 2, 11, 30))
        let job = StubJob()
        let engine = try await makeEngine(job, clock: clock)
        await engine.tick()
        await engine.waitUntilIdle()
        XCTAssertEqual(job.callCount, 1)
        let status = await engine.status()
        XCTAssertEqual(status.lastRun?.trigger, .catchUp)
    }

    func testMovingTheTimeToALaterSlotTodayRunsAgain() async throws {
        let clock = FakeClock(testDate(2026, 10, 2, 8, 0))
        let job = StubJob()
        let engine = try await makeEngine(job, clock: clock)
        await engine.tick()
        await engine.waitUntilIdle()
        XCTAssertEqual(job.callCount, 1)

        clock.set(testDate(2026, 10, 2, 9, 0))
        try await engine.updateConfig(enabledConfig(hour: 10))
        var status = await engine.status()
        XCTAssertEqual(status.nextRun, testDate(2026, 10, 2, 10))
        await engine.tick()
        await engine.waitUntilIdle()
        XCTAssertEqual(job.callCount, 1, "must wait for the new slot")

        clock.set(testDate(2026, 10, 2, 10, 0))
        await engine.tick()
        await engine.waitUntilIdle()
        XCTAssertEqual(job.callCount, 2)
        status = await engine.status()
        XCTAssertEqual(status.lastRun?.trigger, .scheduled)
        XCTAssertEqual(status.lastSuccessDay, "2026-10-02")
    }

    func testMovingTheTimeToAPastSlotOrChangingOtherSettingsKeepsTheDayDone() async throws {
        let clock = FakeClock(testDate(2026, 10, 2, 8, 0))
        let job = StubJob()
        let engine = try await makeEngine(job, clock: clock)
        await engine.tick()
        await engine.waitUntilIdle()

        clock.set(testDate(2026, 10, 2, 9, 0))
        try await engine.updateConfig(enabledConfig(hour: 7))
        var later = enabledConfig(hour: 7)
        later.sources = ["https://example.com/feed"]
        try await engine.updateConfig(later)
        await engine.tick()
        await engine.waitUntilIdle()
        XCTAssertEqual(job.callCount, 1)
        let status = await engine.status()
        XCTAssertEqual(status.lastSuccessDay, "2026-10-02")
        XCTAssertEqual(status.nextRun, testDate(2026, 10, 3, 7))
    }

    func testFailureIsRetriedAfterDelayAtMostThreeTimes() async throws {
        let clock = FakeClock(testDate(2026, 10, 2, 8, 0))
        let job = StubJob(failingBehavior(.noNews))
        let engine = try await makeEngine(job, clock: clock)

        await engine.tick()
        await engine.waitUntilIdle()
        XCTAssertEqual(job.callCount, 1)
        var status = await engine.status()
        XCTAssertEqual(status.lastRun?.outcome, .failed(message: GatewayError.noNews.localizedDescription))
        XCTAssertEqual(status.attemptsToday, 1)
        XCTAssertEqual(status.nextRun, testDate(2026, 10, 2, 8, 10))

        clock.advance(300)
        await engine.tick()
        await engine.waitUntilIdle()
        XCTAssertEqual(job.callCount, 1, "retry must wait for the delay")

        for expected in 2...3 {
            clock.advance(600)
            await engine.tick()
            await engine.waitUntilIdle()
            XCTAssertEqual(job.callCount, expected)
        }
        clock.advance(3600)
        await engine.tick()
        await engine.waitUntilIdle()
        XCTAssertEqual(job.callCount, 3, "attempts per day are bounded")
        status = await engine.status()
        XCTAssertEqual(status.nextRun, testDate(2026, 10, 3, 8))

        clock.set(testDate(2026, 10, 3, 8, 0))
        job.setBehavior { _, _ in JobOutput(artifactPath: "/tmp/ok.pages", itemCount: 1) }
        await engine.tick()
        await engine.waitUntilIdle()
        XCTAssertEqual(job.callCount, 4)
    }

    func testManualRunNeverConsumesTheScheduledSlot() async throws {
        let clock = FakeClock(testDate(2026, 10, 2, 6, 0))
        let job = StubJob()
        let engine = try await makeEngine(job, clock: clock)
        try await engine.startRun(.manual)
        await engine.waitUntilIdle()
        XCTAssertEqual(job.callCount, 1)
        var status = await engine.status()
        XCTAssertEqual(status.lastRun?.trigger, .manual)
        XCTAssertNil(status.lastSuccessDay)

        clock.set(testDate(2026, 10, 2, 8, 0))
        await engine.tick()
        await engine.waitUntilIdle()
        XCTAssertEqual(job.callCount, 2)
        status = await engine.status()
        XCTAssertEqual(status.lastRun?.trigger, .scheduled)
    }

    func testManualFailureDoesNotCountAsAnAttempt() async throws {
        let clock = FakeClock(testDate(2026, 10, 2, 6, 0))
        let engine = try await makeEngine(StubJob(failingBehavior()), clock: clock)
        try await engine.startRun(.manual)
        await engine.waitUntilIdle()
        let status = await engine.status()
        XCTAssertEqual(status.attemptsToday, 0)
    }

    func testSecondRunWhileRunningIsRejectedAndTickIsIgnored() async throws {
        let clock = FakeClock(testDate(2026, 10, 2, 8, 0))
        let job = StubJob(hangingBehavior)
        let engine = try await makeEngine(job, clock: clock)
        try await engine.startRun(.manual)
        do {
            try await engine.startRun(.manual)
            XCTFail("expected alreadyRunning")
        } catch {
            XCTAssertEqual(error as? GatewayError, .alreadyRunning)
        }
        await engine.tick()
        let running = await engine.status()
        XCTAssertTrue(running.isRunning)
        XCTAssertEqual(running.lastRun?.outcome, .running)
        await engine.cancelRun()
        await engine.waitUntilIdle()
        XCTAssertEqual(job.callCount, 1)
    }

    func testCancellationIsRecordedAndDoesNotBurnAnAttempt() async throws {
        let clock = FakeClock(testDate(2026, 10, 2, 8, 0))
        let engine = try await makeEngine(StubJob(hangingBehavior), clock: clock)
        await engine.tick()
        await engine.cancelRun()
        await engine.waitUntilIdle()
        let status = await engine.status()
        XCTAssertEqual(status.lastRun?.outcome, .cancelled)
        XCTAssertEqual(status.attemptsToday, 0)
        XCTAssertFalse(status.isRunning)
    }

    func testTimeoutFailsTheRun() async throws {
        let clock = FakeClock(testDate(2026, 10, 2, 8, 0))
        let engine = try await makeEngine(StubJob(hangingBehavior), clock: clock, timeout: .milliseconds(50))
        await engine.tick()
        await engine.waitUntilIdle()
        let status = await engine.status()
        XCTAssertEqual(status.lastRun?.outcome, .failed(message: GatewayError.timeout.localizedDescription))
        XCTAssertEqual(status.attemptsToday, 1)
    }

    func testRunInterruptedByRestartIsRecoveredAndRetriedImmediately() async throws {
        let clock = FakeClock(testDate(2026, 10, 2, 8, 20))
        var state = GatewayPersistedState()
        state.config = enabledConfig()
        state.inFlight = RunRecord(
            id: UUID(), trigger: .scheduled, startedAt: testDate(2026, 10, 2, 8, 0), outcome: .running
        )
        try store.save(state)

        let job = StubJob()
        let engine = GatewayEngine(store: store, job: job, clock: clock)
        var status = await engine.status()
        guard case .failed(let message)? = status.lastRun?.outcome else {
            return XCTFail("interrupted run should be recorded as failed")
        }
        XCTAssertTrue(message.contains("interrupted"))
        XCTAssertFalse(status.isRunning)
        XCTAssertEqual(status.attemptsToday, 1)

        await engine.tick()
        await engine.waitUntilIdle()
        XCTAssertEqual(job.callCount, 1)
        status = await engine.status()
        XCTAssertEqual(status.lastRun?.trigger, .retry)
        XCTAssertEqual(status.lastSuccessDay, "2026-10-02")
    }

    func testDisabledConfigNeverRuns() async throws {
        let clock = FakeClock(testDate(2026, 10, 2, 9))
        var config = enabledConfig()
        config.isEnabled = false
        let job = StubJob()
        let engine = try await makeEngine(job, clock: clock, config: config)
        await engine.tick()
        await engine.waitUntilIdle()
        XCTAssertEqual(job.callCount, 0)
        let status = await engine.status()
        XCTAssertNil(status.nextRun)
    }

    func testConfigValidationAndPersistence() async throws {
        let clock = FakeClock(testDate(2026, 10, 2, 9))
        let engine = try await makeEngine(StubJob(), clock: clock, config: nil)

        var invalid = enabledConfig()
        invalid.hour = 25
        await XCTAssertThrowsGatewayError { try await engine.updateConfig(invalid) }
        var badSource = enabledConfig()
        badSource.sources = ["ftp://example.com/feed"]
        await XCTAssertThrowsGatewayError { try await engine.updateConfig(badSource) }

        try await engine.updateConfig(enabledConfig(hour: 6, minute: 45))
        let reloaded = GatewayEngine(store: store, job: StubJob(), clock: clock)
        let status = await reloaded.status()
        XCTAssertEqual(status.config.hour, 6)
        XCTAssertEqual(status.config.minute, 45)
        XCTAssertEqual(status.timeZoneID, "Europe/Moscow")
    }

    func testTimeZoneChangeMovesTheSlot() async throws {
        let clock = FakeClock(testDate(2026, 10, 2, 7, 0, zone: "Europe/Moscow"), zone: "Europe/Moscow")
        let engine = try await makeEngine(StubJob(), clock: clock)
        var status = await engine.status()
        XCTAssertEqual(status.nextRun, testDate(2026, 10, 2, 8, zone: "Europe/Moscow"))
        clock.setZone("Asia/Tokyo")
        status = await engine.status()
        XCTAssertEqual(status.timeZoneID, "Asia/Tokyo")
        // 07:00 in Moscow is already 13:00 in Tokyo, so today's slot there has passed: due now.
        XCTAssertEqual(status.nextRun, clock.now)
    }
}

func XCTAssertThrowsGatewayError(
    file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("expected GatewayError", file: file, line: line)
    } catch {
        XCTAssertTrue(error is GatewayError, "\(error)", file: file, line: line)
    }
}
