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
    /// Told after every change a client could see: config, run started, run finished, and a
    /// status field that moved with the clock (see `TimeDerived`).
    private let observer: (any GatewayChangeObserver)?
    private let log = Logger(subsystem: GatewayConstants.label, category: "engine")
    private var state: GatewayPersistedState
    private var runTask: Task<Void, Never>?
    /// Bumped with every reported change; lets a client order statuses it got on different paths.
    /// In memory only: it restarts at 0 with the process, which is why the client compares it
    /// together with `startedAt`.
    private var revision = 0
    /// The clock-driven fields as of the last report; nil until the first `tick()`.
    private var reportedTimeDerived: TimeDerived?

    /// The status fields that change with the clock alone (time zone, midnight), without any
    /// request or run. `tick()` reports a change of these, since nobody polls the status.
    private struct TimeDerived: Equatable {
        var timeZoneID: String
        var nextRun: Date?
        var attemptsToday: Int
    }

    init(
        store: GatewayStateStore, job: any GatewayJob, clock: any GatewayClock = SystemGatewayClock(),
        timeout: Duration = .seconds(900), observer: (any GatewayChangeObserver)? = nil
    ) {
        self.observer = observer
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
            startedAt: startedAt,
            revision: revision
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
        reportChange()
    }

    /// Starts a run in the background and returns immediately; the observer is told when it
    /// starts and when it finishes.
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
        reportChange()
    }

    func cancelRun() {
        runTask?.cancel()
    }

    /// One scheduler evaluation. Safe to call as often as desired; a run is only started when
    /// the policy says it is due and nothing is already running.
    func tick() {
        // Scheduling is skipped while a run is active; the report below is not, because the
        // clock-driven fields can change during a run as well.
        if runTask == nil {
            let decision = DigestSchedule.decide(
                now: clock.now, config: state.config, progress: state.progress, calendar: clock.calendar
            )
            if case .due(let trigger) = decision { try? startRun(trigger) }
        }
        // Nobody polls the status, so a field that moved with the clock alone (new
        // day, new time zone) has to be reported from here. A run started just above has
        // already reported and refreshed the baseline, so it is not reported twice.
        // The first evaluation only records the baseline.
        let current = timeDerived()
        if let reported = reportedTimeDerived, reported != current { reportChange() }
        reportedTimeDerived = current
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
            log.info("run cancelled")
            return .cancelled
        } catch {
            log.error("run failed: \(error.localizedDescription, privacy: .public)")
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
        reportChange()
        let elapsed = Int(record.finishedAt.map { $0.timeIntervalSince(record.startedAt) } ?? 0)
        log.info("run finished trigger=\(record.trigger.rawValue, privacy: .public) after \(elapsed, privacy: .public)s")
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

    /// Taken from `status()` rather than recomputed, so it cannot drift from what clients see.
    private func timeDerived() -> TimeDerived {
        let current = status()
        return TimeDerived(
            timeZoneID: current.timeZoneID, nextRun: current.nextRun, attemptsToday: current.attemptsToday
        )
    }

    /// The single way a change leaves the engine. Every mutation a client could see must end
    /// here: a change that skips it is neither pushed nor counted in `revision`, and the
    /// settings window keeps showing the old status.
    private func reportChange() {
        revision += 1
        // Refresh the baseline, so the next `tick()` does not report this change again.
        reportedTimeDerived = timeDerived()
        // Synchronous and cheap by contract (`GatewayChangeObserver`): it only schedules work.
        observer?.gatewayDidChange()
    }
}
