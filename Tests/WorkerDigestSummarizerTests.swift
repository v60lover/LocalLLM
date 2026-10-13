import XCTest
@testable import LocalLLMChat

#if os(macOS)
/// Records every job and answers through a scripted behavior; stands in for `WorkerSupervisor`.
private final class StubWorker: DigestWorkerRunning, @unchecked Sendable {
    typealias Behavior = @Sendable (WorkerJob, Int) async throws -> String

    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var issued: [WorkerJob] = []
    private let behavior: Behavior

    init(_ behavior: @escaping Behavior = StubWorker.goodNews) { self.behavior = behavior }

    /// Every verdict is GOOD, every digest is "Digest text".
    static let goodNews: Behavior = { job, _ in
        job.instructions == GoodNewsFilter.instructions ? "GOOD" : "Digest text"
    }

    var events: [String] { lock.withLock { recordedEvents } }
    var jobs: [WorkerJob] { lock.withLock { issued } }
    var verdictJobs: [WorkerJob] { jobs.filter { $0.instructions == GoodNewsFilter.instructions } }
    var digestJobs: [WorkerJob] { jobs.filter { $0.instructions != GoodNewsFilter.instructions } }

    func generate(
        _ job: WorkerJob, onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> WorkerJobResult {
        let index = lock.withLock { () -> Int in
            issued.append(job)
            recordedEvents.append("generate")
            return issued.count - 1
        }
        let text = try await behavior(job, index)
        return WorkerJobResult(text: text, transcript: Data(), usedTokens: 0)
    }

    func leaveSafeMode() async {
        lock.withLock { recordedEvents.append("leaveSafeMode") }
    }
}

private struct StubLocator: ModelLocating {
    var path: String? = "/models/qwen"
    func localPath(for model: ModelReference) -> String? { path }
}

private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let passes = lock.withLock { () -> Bool in
                if !opened { waiters.append(continuation) }
                return opened
            }
            if passes { continuation.resume() }
        }
    }

    func open() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in released { waiter.resume() }
    }
}

private func newsItems(_ count: Int) -> [NewsItem] {
    (1...count).map {
        NewsItem(title: "Title \($0)", summary: $0 == 1 ? "" : "Summary \($0)", link: "https://a.example/\($0)",
                 source: "src", published: nil)
    }
}

private func failure(_ kind: WorkerFailureKind, _ message: String = "boom") -> WorkerSupervisorError {
    .worker(WorkerFailure(kind: kind, message: message))
}

/// Numbered list lines of a digest prompt.
private func listedItems(in prompt: String) -> Int {
    prompt.split(separator: "\n").filter { $0.range(of: #"^\d+\. \["#, options: .regularExpression) != nil }.count
}

final class WorkerDigestSummarizerTests: XCTestCase {
    private func summarizer(
        _ worker: StubWorker, locator: StubLocator = StubLocator()
    ) -> WorkerDigestSummarizer {
        WorkerDigestSummarizer(worker: worker, locator: locator)
    }

    // MARK: Prompts and sessions

    func testEachVerdictIsItsOwnJobWithTheGatewaysPrompts() async throws {
        let items = newsItems(3)
        let worker = StubWorker { job, index in
            if job.instructions != GoodNewsFilter.instructions { return "Digest text" }
            return index == 1 ? "OTHER" : "GOOD"
        }
        let summary = try await summarizer(worker).summarize(items: items, model: testModel)

        XCTAssertEqual(worker.verdictJobs.count, 3, "one job, hence one fresh session, per item")
        for (job, item) in zip(worker.verdictJobs, items) {
            XCTAssertNil(job.transcript, "a verdict must not continue another session")
            XCTAssertEqual(job.model, .path("/models/qwen"))
            XCTAssertEqual(job.prompt, GoodNewsFilter.prompt(for: item))
            XCTAssertEqual(job.options.maximumResponseTokens, WorkerDigestSummarizer.verdictTokenLimit)
        }
        XCTAssertEqual(summary.items, [items[0], items[2]], "only GOOD items, in the original order")
        XCTAssertEqual(summary.text, "Digest text")

        let digest = try XCTUnwrap(worker.digestJobs.first)
        XCTAssertEqual(worker.digestJobs.count, 1)
        XCTAssertEqual(digest.options.maximumResponseTokens, WorkerDigestSummarizer.digestTokenLimit)
        XCTAssertEqual(listedItems(in: digest.prompt), 2)
        XCTAssertTrue(digest.prompt.contains("Title 1"))
        XCTAssertFalse(digest.prompt.contains("Title 2"), "a rejected item must not reach the digest prompt")
        XCTAssertTrue(digest.prompt.contains("Title 3"))
    }

    func testNoPromptDisablesThinkingAndTheVerdictBudgetCoversIt() async throws {
        // "/no_think" makes qwen3-0.6b generate to the limit without answering (LocalLLMChat-ac3.17).
        let worker = StubWorker()
        XCTAssertTrue(testModel.catalogID.hasPrefix("qwen3"))
        _ = try await summarizer(worker).summarize(items: newsItems(2), model: testModel)

        XCTAssertEqual(worker.jobs.count, 3)
        for job in worker.jobs {
            XCTAssertFalse(job.prompt.contains("/no_think"), job.prompt)
        }
        XCTAssertGreaterThanOrEqual(
            WorkerDigestSummarizer.verdictTokenLimit, 512, "a verdict must fit the think block and the answer"
        )
    }

    // MARK: Outcomes

    func testWhenNothingIsGoodNoDigestIsRequested() async {
        let worker = StubWorker { _, _ in "OTHER" }
        do {
            _ = try await summarizer(worker).summarize(items: newsItems(3), model: testModel)
            XCTFail("expected noGoodNews")
        } catch {
            XCTAssertEqual(error as? GatewayError, .noGoodNews)
        }
        XCTAssertEqual(worker.jobs.count, 3, "three verdicts and no digest")
    }

    func testAModelThatIsNotDownloadedNeverTouchesTheWorker() async {
        let worker = StubWorker()
        do {
            _ = try await summarizer(worker, locator: StubLocator(path: nil))
                .summarize(items: newsItems(2), model: testModel)
            XCTFail("expected modelNotDownloaded")
        } catch {
            XCTAssertEqual(error as? GatewayError, .modelNotDownloaded(testModel.catalogID))
        }
        XCTAssertEqual(worker.events, [])
    }

    func testEveryRunLeavesSafeModeBeforeTheFirstJob() async throws {
        let worker = StubWorker()
        _ = try await summarizer(worker).summarize(items: newsItems(1), model: testModel)

        XCTAssertEqual(worker.events.first, "leaveSafeMode")
        XCTAssertEqual(worker.events.filter { $0 == "leaveSafeMode" }.count, 1)
    }

    // MARK: Cancellation

    func testCancellingDuringAVerdictIsNotAFailureAndIssuesNothingMore() async {
        let started = Latch()
        let worker = StubWorker { _, _ in
            started.open()
            // A worker that never answers; the sleep ends when the caller is cancelled.
            try await Task.sleep(for: .seconds(3600))
            return "GOOD"
        }
        let summarizer = summarizer(worker)
        let task = Task { try await summarizer.summarize(items: newsItems(3), model: testModel) }
        await started.wait()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "cancellation must not become a failure: \(error)")
        }
        XCTAssertEqual(worker.jobs.count, 1)
    }

    func testCancellationFromTheSupervisorIsNotMappedToAFailure() async {
        let worker = StubWorker { _, _ in throw CancellationError() }
        do {
            _ = try await summarizer(worker).summarize(items: newsItems(2), model: testModel)
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    // MARK: Error mapping

    func testWorkerFailuresBecomeTheErrorsTheEngineRecords() async {
        let cases: [(WorkerSupervisorError, GatewayError)] = [
            (failure(.modelLoadFailed, "Model bundle not found."), .modelUnavailable("Model bundle not found.")),
            (failure(.unsupportedProtocol, "old"), .modelUnavailable("old")),
            (.loadTimedOut, .modelUnavailable("loading the model timed out.")),
            (.safeMode, .modelUnavailable("the model worker was stopped after repeated crashes.")),
            (failure(.internalError, "Failed to parse generated content"),
             .summarizationFailed("Failed to parse generated content")),
            (.memoryPressure, .summarizationFailed("the Mac is low on memory, so the model was unloaded.")),
            (.interrupted(.crashed, deliveredOutput: false),
             .summarizationFailed("the model worker stopped unexpectedly.")),
            (.interrupted(.unresponsive, deliveredOutput: true),
             .summarizationFailed("the model worker stopped responding.")),
        ]
        for (thrown, expected) in cases {
            let worker = StubWorker { _, _ in throw thrown }
            do {
                _ = try await summarizer(worker).summarize(items: newsItems(2), model: testModel)
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? GatewayError, expected, "for \(thrown)")
            }
            XCTAssertEqual(worker.jobs.count, 1, "a failed verdict ends the run: \(thrown)")
        }
    }

    // MARK: Digest retry

    private func digestBehavior(failures: [WorkerSupervisorError], verdicts: Int) -> StubWorker.Behavior {
        { job, index in
            if job.instructions == GoodNewsFilter.instructions { return "GOOD" }
            let attempt = index - verdicts
            if attempt < failures.count { throw failures[attempt] }
            return "Digest text"
        }
    }

    func testAnOverlongDigestIsRetriedOnceWithFewerItems() async throws {
        for kind in [WorkerFailureKind.internalError, .contextOverflow] {
            let worker = StubWorker(digestBehavior(failures: [failure(kind)], verdicts: 8))
            let summary = try await summarizer(worker).summarize(items: newsItems(8), model: testModel)

            XCTAssertEqual(summary.text, "Digest text")
            XCTAssertEqual(summary.items.count, 8, "the list shown under the digest is not shortened")
            XCTAssertEqual(worker.digestJobs.map { listedItems(in: $0.prompt) }, [8, 4], "\(kind)")
        }
    }

    func testASecondDigestFailureFailsTheRun() async {
        let worker = StubWorker(digestBehavior(
            failures: [failure(.internalError, "first"), failure(.internalError, "second")], verdicts: 2
        ))
        do {
            _ = try await summarizer(worker).summarize(items: newsItems(2), model: testModel)
            XCTFail("expected summarizationFailed")
        } catch {
            XCTAssertEqual(error as? GatewayError, .summarizationFailed("second"))
        }
        XCTAssertEqual(worker.digestJobs.count, 2)
    }

    func testACrashDuringTheDigestIsNotRetriedHere() async {
        // The supervisor already re-issues a job that died before producing output.
        let worker = StubWorker(digestBehavior(
            failures: [.interrupted(.crashed, deliveredOutput: false)], verdicts: 4
        ))
        do {
            _ = try await summarizer(worker).summarize(items: newsItems(4), model: testModel)
            XCTFail("expected summarizationFailed")
        } catch {
            XCTAssertEqual(error as? GatewayError, .summarizationFailed("the model worker stopped unexpectedly."))
        }
        XCTAssertEqual(worker.digestJobs.count, 1)
    }

    func testAnEmptyDigestIsAFailureWithoutRetry() async {
        let worker = StubWorker { job, _ in job.instructions == GoodNewsFilter.instructions ? "GOOD" : "  \n" }
        do {
            _ = try await summarizer(worker).summarize(items: newsItems(2), model: testModel)
            XCTFail("expected summarizationFailed")
        } catch {
            XCTAssertEqual(error as? GatewayError, .summarizationFailed("empty response"))
        }
        XCTAssertEqual(worker.digestJobs.count, 1)
    }
}

// MARK: - Status exposure

final class WorkerStatusTests: XCTestCase {
    private var directory: URL!

    override func setUp() { directory = makeTemporaryDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testStatesMapToStableStrings() {
        let states: [(WorkerSupervisorState, String)] = [
            (.idle, "idle"), (.starting, "starting"), (.ready, "ready"),
            (.restarting, "restarting"), (.safeMode, "safeMode"),
        ]
        for (state, name) in states {
            XCTAssertEqual(WorkerStatus(state).state, name)
            XCTAssertEqual(WorkerStatus(state).isSafeMode, state == .safeMode)
        }
    }

    func testStatusWrittenByAnOlderGatewayHasNoWorker() throws {
        // The shape a build without the `worker` field wrote.
        let old = """
        {"protocolVersion":1,"config":{"isEnabled":false,"sources":[],"outputDirectory":"/tmp","hour":8,"minute":0},\
        "isRunning":false,"timeZoneID":"UTC","attemptsToday":0,"startedAt":"2026-10-12T08:00:00Z"}
        """
        let status = try GatewayWire.decoder.decode(GatewayStatus.self, from: Data(old.utf8))
        XCTAssertNil(status.worker)
        XCTAssertEqual(status.timeZoneID, "UTC")
    }

    func testAnOlderAppIgnoresTheWorkerField() throws {
        struct OldStatus: Decodable { var protocolVersion: Int; var isRunning: Bool }
        var status = GatewayStatus(
            config: DigestConfig(), isRunning: true, nextRun: nil, timeZoneID: "UTC", lastRun: nil,
            attemptsToday: 0, lastSuccessDay: nil, startedAt: Date()
        )
        status.worker = WorkerStatus(.ready)
        let data = try GatewayWire.encoder.encode(status)
        let old = try JSONDecoder().decode(OldStatus.self, from: data)
        XCTAssertTrue(old.isRunning)
        XCTAssertEqual(try GatewayWire.decoder.decode(GatewayStatus.self, from: data).worker, WorkerStatus(.ready))
    }

    func testTheStatusReplyCarriesTheSuppliedWorkerState() async throws {
        let engine = GatewayEngine(
            store: GatewayStateStore(directory: directory), job: StubJob(), clock: FakeClock(testDate(2026, 10, 2, 6))
        )
        let withWorker = GatewayRequestHandler(engine: engine, workerStatus: { WorkerStatus(.safeMode) })
        let without = GatewayRequestHandler(engine: engine)
        let hello = try GatewayWire.encoder.encode(GatewayRequestEnvelope(request: .hello(version: GatewayConstants.protocolVersion)))
        let request = try GatewayWire.encoder.encode(GatewayRequestEnvelope(request: .status))

        let cases: [(GatewayRequestHandler, WorkerStatus?)] = [(withWorker, WorkerStatus(.safeMode)), (without, nil)]
        for (handler, expected) in cases {
            let connection = GatewayConnectionContext()
            _ = await handler.handle(hello, connection: connection)
            let data = await handler.handle(request, connection: connection)
            let reply = try GatewayWire.decoder.decode(GatewayReplyEnvelope.self, from: data).reply
            guard case .status(let status) = reply else { return XCTFail("expected a status reply") }
            XCTAssertEqual(status.worker, expected)
        }
    }
}
#endif
