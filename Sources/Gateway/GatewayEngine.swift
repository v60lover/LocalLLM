#if os(macOS)
import Foundation
import OSLog

struct JobOutput: Equatable, Sendable {
    let artifactPath: String
    let itemCount: Int
}

/// A unit of background work. The Gateway owns scheduling; jobs only do the work.
protocol GatewayJob: Sendable {
    func run(config: DigestConfig, now: Date) async throws -> JobOutput
}

/// Owns schedule, persistence and the single in-flight run. All time comes from the injected
/// clock, so every scheduling path is deterministic in tests.
actor GatewayEngine {
    private let store: GatewayStateStore
    private let job: any GatewayJob
    private let clock: any GatewayClock
    private let timeout: Duration
    private let startedAt: Date
    private let log = Logger(subsystem: GatewayConstants.label, category: "engine")
    private var state: GatewayPersistedState
    private var runTask: Task<Void, Never>?

    init(
        store: GatewayStateStore, job: any GatewayJob, clock: any GatewayClock = SystemGatewayClock(),
        timeout: Duration = .seconds(900)
    ) {
        self.store = store
        self.job = job
        self.clock = clock
        self.timeout = timeout
        startedAt = clock.now
        var loaded = store.load()
        Self.recoverInterruptedRun(in: &loaded, clock: clock)
        try? store.save(loaded)
        state = loaded
    }

    func status() -> GatewayStatus {
        let now = clock.now
        let calendar = clock.calendar
        let today = DigestSchedule.dayKey(now, calendar: calendar)
        return GatewayStatus(
            config: state.config,
            isRunning: runTask != nil,
            nextRun: DigestSchedule.nextRun(
                now: now, config: state.config, progress: state.progress, calendar: calendar
            ),
            timeZoneID: calendar.timeZone.identifier,
            lastRun: state.inFlight ?? state.lastRun,
            attemptsToday: state.progress.attemptDay == today ? state.progress.attempts : 0,
            lastSuccessDay: state.progress.lastSuccessDay,
            startedAt: startedAt
        )
    }

    func updateConfig(_ config: DigestConfig) throws {
        try config.validate()
        guard config != state.config else { return }
        let timeChanged = config.hour != state.config.hour || config.minute != state.config.minute
        state.config = config
        // A changed configuration deserves a fresh attempt budget today. Today's delivery is
        // only forgotten when the time itself moved to a slot that is still ahead today:
        // the user is asking for a digest at that time.
        state.progress.attempts = 0
        state.progress.retryAt = nil
        let now = clock.now
        let calendar = clock.calendar
        if timeChanged, state.progress.lastSuccessDay == DigestSchedule.dayKey(now, calendar: calendar),
           DigestSchedule.slot(onDayOf: now, config: config, calendar: calendar) > now {
            state.progress.lastSuccessDay = nil
        }
        try persist()
    }

    /// Starts a run in the background and returns immediately; poll `status()` for the result.
    func startRun(_ trigger: RunTrigger) throws {
        guard runTask == nil else { throw GatewayError.alreadyRunning }
        let now = clock.now
        let record = RunRecord(id: UUID(), trigger: trigger, startedAt: now, outcome: .running)
        state.inFlight = record
        try persist()
        let config = state.config
        log.info("run started trigger=\(trigger.rawValue, privacy: .public)")
        runTask = Task { [self] in
            let outcome = await perform(config: config, now: now)
            finish(record, outcome: outcome)
        }
    }

    func cancelRun() {
        runTask?.cancel()
    }

    /// One scheduler evaluation. Safe to call as often as desired; a run is only started when
    /// the policy says it is due and nothing is already running.
    func tick() {
        guard runTask == nil else { return }
        let decision = DigestSchedule.decide(
            now: clock.now, config: state.config, progress: state.progress, calendar: clock.calendar
        )
        if case .due(let trigger) = decision { try? startRun(trigger) }
    }

    func waitUntilIdle() async {
        while let task = runTask { await task.value }
    }

    /// Wake at most every `maxInterval` so sleep/wake and clock or time-zone changes are noticed.
    func runSchedulerLoop(maxInterval: Duration = .seconds(30)) async {
        while !Task.isCancelled {
            tick()
            let next = status().nextRun
            let delay = next.map { max(1, $0.timeIntervalSince(clock.now)) } ?? 30
            let step = min(Duration.seconds(delay), maxInterval)
            try? await Task.sleep(for: step)
        }
    }

    // MARK: - Private

    private func perform(config: DigestConfig, now: Date) async -> RunRecord.Outcome {
        do {
            let output = try await withThrowingTaskGroup(of: JobOutput?.self) { [job, timeout] group in
                group.addTask { try await job.run(config: config, now: now) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                if let first = try await group.next(), let output = first { return output }
                throw GatewayError.timeout
            }
            return .succeeded(path: output.artifactPath, itemCount: output.itemCount)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    private func finish(_ started: RunRecord, outcome: RunRecord.Outcome) {
        var record = started
        record.finishedAt = clock.now
        record.outcome = outcome
        state.inFlight = nil
        state.lastRun = record
        // Manual runs are explicit user actions: they never consume or satisfy the daily slot.
        if record.trigger != .manual {
            let calendar = clock.calendar
            let day = DigestSchedule.dayKey(record.startedAt, calendar: calendar)
            switch outcome {
            case .succeeded:
                state.progress.lastSuccessDay = day
                state.progress.attemptDay = day
                state.progress.attempts = 0
                state.progress.retryAt = nil
            case .failed:
                registerFailedAttempt(day: day, at: record.finishedAt ?? record.startedAt)
            case .cancelled, .running:
                break
            }
        }
        do { try persist() } catch { log.error("persist failed: \(error.localizedDescription, privacy: .public)") }
        runTask = nil
        log.info("run finished trigger=\(record.trigger.rawValue, privacy: .public)")
    }

    private func registerFailedAttempt(day: String, at date: Date) {
        if state.progress.attemptDay != day {
            state.progress.attemptDay = day
            state.progress.attempts = 0
        }
        state.progress.attempts += 1
        state.progress.retryAt = date.addingTimeInterval(DigestSchedule.retryDelay)
    }

    private static func recoverInterruptedRun(in state: inout GatewayPersistedState, clock: any GatewayClock) {
        guard var record = state.inFlight else { return }
        record.finishedAt = clock.now
        record.outcome = .failed(message: "The run was interrupted by a Gateway restart or Mac shutdown.")
        state.inFlight = nil
        state.lastRun = record
        if record.trigger != .manual {
            let day = DigestSchedule.dayKey(record.startedAt, calendar: clock.calendar)
            if state.progress.attemptDay != day {
                state.progress.attemptDay = day
                state.progress.attempts = 0
            }
            state.progress.attempts += 1
            // The interruption was not the user's or the network's fault: retry right away.
            state.progress.retryAt = nil
        }
    }

    private func persist() throws {
        try store.save(state)
    }
}
#endif
