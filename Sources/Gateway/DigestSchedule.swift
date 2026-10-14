import Foundation

/// Durable per-day bookkeeping used to avoid duplicate sends and bound retries.
struct DailyProgress: Codable, Equatable, Sendable {
    var lastSuccessDay: String?
    var attemptDay: String?
    var attempts = 0
    var retryAt: Date?
}

/// Pure scheduling policy. All inputs are explicit so it can be tested without a clock.
///
/// - One successful scheduled run per local calendar day (`lastSuccessDay`).
/// - If the Mac was asleep/off at the configured time, the run is made up once the Gateway
///   is awake again *the same day*; earlier days are never back-filled.
/// - A failed attempt is retried after `retryDelay`, at most `maxAttemptsPerDay` times a day.
/// - Days are evaluated in the Mac's current time zone.
enum DigestSchedule {
    static let maxAttemptsPerDay = 3
    static let retryDelay: TimeInterval = 600
    static let onTimeWindow: TimeInterval = 300

    enum Decision: Equatable {
        case disabled
        case due(RunTrigger)
        case wait(until: Date)
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func slot(onDayOf date: Date, config: DigestConfig, calendar: Calendar) -> Date {
        calendar.date(
            bySettingHour: config.hour, minute: config.minute, second: 0, of: date,
            matchingPolicy: .nextTime
        ) ?? date
    }

    static func decide(
        now: Date, config: DigestConfig, progress: DailyProgress, calendar: Calendar
    ) -> Decision {
        guard config.isEnabled else { return .disabled }
        let today = dayKey(now, calendar: calendar)
        let todaySlot = slot(onDayOf: now, config: config, calendar: calendar)
        let tomorrowSlot = nextDaySlot(after: now, config: config, calendar: calendar)

        if progress.lastSuccessDay == today { return .wait(until: tomorrowSlot) }
        if now < todaySlot { return .wait(until: todaySlot) }

        let attempts = progress.attemptDay == today ? progress.attempts : 0
        if attempts >= maxAttemptsPerDay { return .wait(until: tomorrowSlot) }
        if attempts > 0, let retryAt = progress.retryAt, now < retryAt {
            return .wait(until: retryAt)
        }
        if attempts > 0 { return .due(.retry) }
        return .due(now.timeIntervalSince(todaySlot) <= onTimeWindow ? .scheduled : .catchUp)
    }

    static func nextRun(
        now: Date, config: DigestConfig, progress: DailyProgress, calendar: Calendar
    ) -> Date? {
        switch decide(now: now, config: config, progress: progress, calendar: calendar) {
        case .disabled: nil
        case .due: now
        case .wait(let date): date
        }
    }

    private static func nextDaySlot(after now: Date, config: DigestConfig, calendar: Calendar) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now.addingTimeInterval(86_400)
        return slot(onDayOf: tomorrow, config: config, calendar: calendar)
    }
}
