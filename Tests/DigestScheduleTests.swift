import Foundation
import XCTest
@testable import LocalLLMChat

final class DigestScheduleTests: XCTestCase {
    private var moscow: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return calendar
    }

    private func decide(_ now: Date, _ config: DigestConfig = enabledConfig(), _ progress: DailyProgress = DailyProgress()) -> DigestSchedule.Decision {
        DigestSchedule.decide(now: now, config: config, progress: progress, calendar: moscow)
    }

    func testDisabledNeverRuns() {
        var config = enabledConfig()
        config.isEnabled = false
        XCTAssertEqual(decide(testDate(2026, 10, 2, 9), config), .disabled)
        XCTAssertNil(DigestSchedule.nextRun(now: testDate(2026, 10, 2, 9), config: config, progress: DailyProgress(), calendar: moscow))
    }

    func testWaitsForTodaysSlotThenRunsOnTime() {
        XCTAssertEqual(decide(testDate(2026, 10, 2, 7, 59)), .wait(until: testDate(2026, 10, 2, 8)))
        XCTAssertEqual(decide(testDate(2026, 10, 2, 8, 0)), .due(.scheduled))
        XCTAssertEqual(decide(testDate(2026, 10, 2, 8, 4)), .due(.scheduled))
    }

    func testMissedRunIsMadeUpTheSameDay() {
        XCTAssertEqual(decide(testDate(2026, 10, 2, 8, 6)), .due(.catchUp))
        XCTAssertEqual(decide(testDate(2026, 10, 2, 23, 59)), .due(.catchUp))
    }

    func testSuccessSuppressesRestOfDayAndResumesTomorrow() {
        let progress = DailyProgress(lastSuccessDay: "2026-10-02")
        XCTAssertEqual(decide(testDate(2026, 10, 2, 8, 1), enabledConfig(), progress), .wait(until: testDate(2026, 10, 3, 8)))
        XCTAssertEqual(decide(testDate(2026, 10, 2, 22), enabledConfig(), progress), .wait(until: testDate(2026, 10, 3, 8)))
        XCTAssertEqual(decide(testDate(2026, 10, 3, 8), enabledConfig(), progress), .due(.scheduled))
    }

    func testYesterdaysMissedRunIsNotBackfilled() {
        // Mac was off all of Oct 1; nothing is recorded. Waking up at 07:00 on Oct 2 must not run.
        XCTAssertEqual(decide(testDate(2026, 10, 2, 7)), .wait(until: testDate(2026, 10, 2, 8)))
    }

    func testFailedAttemptsRetryWithDelayAndAreBounded() {
        let day = "2026-10-02"
        let failed = DailyProgress(
            lastSuccessDay: nil, attemptDay: day, attempts: 1, retryAt: testDate(2026, 10, 2, 8, 10)
        )
        XCTAssertEqual(decide(testDate(2026, 10, 2, 8, 5), enabledConfig(), failed), .wait(until: testDate(2026, 10, 2, 8, 10)))
        XCTAssertEqual(decide(testDate(2026, 10, 2, 8, 10), enabledConfig(), failed), .due(.retry))

        let exhausted = DailyProgress(
            lastSuccessDay: nil, attemptDay: day, attempts: DigestSchedule.maxAttemptsPerDay,
            retryAt: testDate(2026, 10, 2, 8, 30)
        )
        XCTAssertEqual(decide(testDate(2026, 10, 2, 12), enabledConfig(), exhausted), .wait(until: testDate(2026, 10, 3, 8)))
    }

    func testStaleAttemptsFromYesterdayDoNotBlockToday() {
        let old = DailyProgress(lastSuccessDay: nil, attemptDay: "2026-10-01", attempts: 3, retryAt: nil)
        XCTAssertEqual(decide(testDate(2026, 10, 2, 8), enabledConfig(), old), .due(.scheduled))
    }

    func testDayBoundaryFollowsTheCurrentTimeZone() {
        let instant = testDate(2026, 10, 2, 23, 30, zone: "UTC")
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(DigestSchedule.dayKey(instant, calendar: utc), "2026-10-02")
        XCTAssertEqual(DigestSchedule.dayKey(instant, calendar: tokyo), "2026-10-03")
    }

    func testNonexistentLocalTimeOnDSTGapStillProducesASlot() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let config = enabledConfig(hour: 2, minute: 30)
        let day = testDate(2026, 3, 8, 12, zone: "America/New_York")
        let slot = DigestSchedule.slot(onDayOf: day, config: config, calendar: newYork)
        XCTAssertEqual(newYork.component(.day, from: slot), 8)
        XCTAssertGreaterThanOrEqual(newYork.component(.hour, from: slot), 3)
    }

    func testNextRunIsNowWhenDue() {
        let now = testDate(2026, 10, 2, 8, 30)
        XCTAssertEqual(DigestSchedule.nextRun(now: now, config: enabledConfig(), progress: DailyProgress(), calendar: moscow), now)
    }
}
