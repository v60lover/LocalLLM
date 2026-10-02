import Foundation
import XCTest
@testable import LocalLLMChat

final class FakeClock: GatewayClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var zone: TimeZone

    init(_ date: Date, zone: String = "Europe/Moscow") {
        current = date
        self.zone = TimeZone(identifier: zone)!
    }

    var now: Date { lock.withLock { current } }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = lock.withLock { zone }
        return calendar
    }

    func set(_ date: Date) { lock.withLock { current = date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    func setZone(_ identifier: String) { lock.withLock { zone = TimeZone(identifier: identifier)! } }
}

func testDate(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
    zone: String = "Europe/Moscow"
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute
    ))!
}

func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gateway-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let testModel = ModelReference(catalogID: "qwen3-0.6b", repo: "org/model", path: nil, revision: "main")

func enabledConfig(hour: Int = 8, minute: Int = 0) -> DigestConfig {
    var config = DigestConfig()
    config.isEnabled = true
    config.hour = hour
    config.minute = minute
    config.model = testModel
    return config
}

final class StubJob: GatewayJob, @unchecked Sendable {
    typealias Behavior = @Sendable (DigestConfig, Date) async throws -> JobOutput
    private let lock = NSLock()
    private var calls = 0
    private var behavior: Behavior

    init(_ behavior: @escaping Behavior = { _, _ in JobOutput(artifactPath: "/tmp/digest.pages", itemCount: 3) }) {
        self.behavior = behavior
    }

    var callCount: Int { lock.withLock { calls } }
    func setBehavior(_ behavior: @escaping Behavior) { lock.withLock { self.behavior = behavior } }

    func run(config: DigestConfig, now: Date) async throws -> JobOutput {
        let current = lock.withLock { () -> Behavior in
            calls += 1
            return behavior
        }
        return try await current(config, now)
    }
}

/// Never finishes until cancelled.
let hangingBehavior: StubJob.Behavior = { _, _ in
    try await Task.sleep(for: .seconds(3600))
    return JobOutput(artifactPath: "", itemCount: 0)
}

func failingBehavior(_ error: GatewayError = .noNews) -> StubJob.Behavior {
    { _, _ in throw error }
}
