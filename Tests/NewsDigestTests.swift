import Foundation
import XCTest
@testable import LocalLLMChat

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) static var failingHosts: Set<String> = []

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        if Self.failingHosts.contains(host) {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let stub = Self.responses[host] ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func rss(_ items: [(String, String, String, String)]) -> Data {
    let body = items.map {
        "<item><title>\($0.0)</title><link>\($0.1)</link><description>\($0.2)</description><pubDate>\($0.3)</pubDate></item>"
    }.joined()
    return Data("<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>Feed</title>\(body)</channel></rss>".utf8)
}

final class FeedParsingTests: XCTestCase {
    func testParsesRSSWithCDATAAndHTMLDescription() {
        let xml = """
        <rss version="2.0"><channel><title>Site</title>
        <item><title><![CDATA[First &amp; foremost]]></title><link>https://a.example/1</link>
        <description><![CDATA[<p>News&nbsp;text <b>important</b></p>]]></description>
        <pubDate>Fri, 02 Oct 2026 06:30:00 +0000</pubDate></item>
        </channel></rss>
        """
        let items = FeedParser.parse(Data(xml.utf8), source: "a.example")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "First & foremost")
        XCTAssertEqual(items[0].summary, "News text important")
        XCTAssertEqual(items[0].link, "https://a.example/1")
        XCTAssertEqual(items[0].published, testDate(2026, 10, 2, 6, 30, zone: "UTC"))
    }

    func testParsesAtomEntries() {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Feed title</title>
        <entry><title>Atom story</title><link rel="alternate" href="https://b.example/s"/>
        <summary>Short</summary><updated>2026-10-02T05:00:00Z</updated></entry>
        </feed>
        """
        let items = FeedParser.parse(Data(xml.utf8), source: "b.example")
        XCTAssertEqual(items.map(\.title), ["Atom story"])
        XCTAssertEqual(items[0].link, "https://b.example/s")
        XCTAssertEqual(items[0].published, testDate(2026, 10, 2, 5, 0, zone: "UTC"))
    }

    func testGarbageYieldsNoItems() {
        XCTAssertTrue(FeedParser.parse(Data("<html><body>nope".utf8), source: "x").isEmpty)
        XCTAssertTrue(FeedParser.parse(Data(), source: "x").isEmpty)
    }
}

final class NewsPreparationTests: XCTestCase {
    private func item(_ title: String, _ link: String, _ source: String, minutesAgo: Int = 0, summary: String = "") -> NewsItem {
        NewsItem(title: title, summary: summary, link: link, source: source,
                 published: testDate(2026, 10, 2, 12).addingTimeInterval(TimeInterval(-minutesAgo * 60)))
    }

    func testDeduplicatesByLinkAndByTitle() {
        let items = [
            item("Same story", "https://a.example/x?utm=1#frag", "a"),
            item("Same story", "https://a.example/x/", "a"),
            item("Same Story!", "https://b.example/other", "b"),
            item("Different", "https://b.example/d", "b"),
        ]
        let result = NewsPreparation.prepare(items)
        XCTAssertEqual(result.map(\.title), ["Same story", "Different"])
    }

    func testBoundsPerSourceAndTotalAndInterleavesSources() {
        var policy = NewsPolicy()
        policy.maxItemsPerSource = 3
        policy.maxTotalItems = 5
        let a = (0..<10).map { item("A\($0)", "https://a.example/\($0)", "a", minutesAgo: $0) }
        let b = (0..<10).map { item("B\($0)", "https://b.example/\($0)", "b", minutesAgo: $0) }
        let result = NewsPreparation.prepare(a + b, policy: policy)
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result.filter { $0.source == "a" }.count, 3)
        XCTAssertEqual(result.prefix(2).map(\.source).sorted(), ["a", "b"])
    }

    func testTruncatesLongTextAndDropsEmptyTitles() {
        var policy = NewsPolicy()
        policy.maxSummaryCharacters = 20
        let long = String(repeating: "word ", count: 50)
        let result = NewsPreparation.prepare([item("T", "https://a.example/1", "a", summary: long), item("", "https://a.example/2", "a")], policy: policy)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].summary.count, 20)
        XCTAssertTrue(result[0].summary.hasSuffix("…"))
    }
}

final class URLSessionNewsFetcherTests: XCTestCase {
    override func setUp() {
        StubURLProtocol.responses = [:]
        StubURLProtocol.failingHosts = []
    }

    private func fetcher(maxBytes: Int = 2_000_000) -> URLSessionNewsFetcher {
        var policy = NewsPolicy()
        policy.maxResponseBytes = maxBytes
        return URLSessionNewsFetcher(session: StubURLProtocol.session(), policy: policy)
    }

    func testFetchesAndParsesMultipleSources() async throws {
        StubURLProtocol.responses["one.example"] = (200, rss([("One", "https://one.example/1", "d", "Fri, 02 Oct 2026 06:30:00 +0000")]))
        StubURLProtocol.responses["two.example"] = (200, rss([("Two", "https://two.example/1", "d", "Fri, 02 Oct 2026 06:00:00 +0000")]))
        let result = try await fetcher().fetch(sources: [URL(string: "https://one.example/rss")!, URL(string: "https://two.example/rss")!])
        XCTAssertEqual(Set(result.items.map(\.title)), ["One", "Two"])
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testPartialFailureKeepsGoodSourcesAndReportsBadOnes() async throws {
        StubURLProtocol.responses["ok.example"] = (200, rss([("Ok", "https://ok.example/1", "d", "")]))
        StubURLProtocol.failingHosts = ["down.example"]
        StubURLProtocol.responses["err.example"] = (500, Data())
        let result = try await fetcher().fetch(sources: ["ok", "down", "err"].map { URL(string: "https://\($0).example/rss")! })
        XCTAssertEqual(result.items.map(\.title), ["Ok"])
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertTrue(result.failures.contains { $0.contains("HTTP 500") })
    }

    func testAllSourcesFailingThrows() async {
        StubURLProtocol.failingHosts = ["down.example"]
        StubURLProtocol.responses["html.example"] = (200, Data("<html>not a feed</html>".utf8))
        do {
            _ = try await fetcher().fetch(sources: [URL(string: "https://down.example/rss")!, URL(string: "https://html.example/rss")!])
            XCTFail("expected failure")
        } catch GatewayError.allSourcesFailed(let details) {
            XCTAssertEqual(details.count, 2)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testOversizedResponseIsRejected() async {
        StubURLProtocol.responses["big.example"] = (200, rss([("Big", "https://big.example/1", "d", "")]))
        do {
            _ = try await fetcher(maxBytes: 50).fetch(sources: [URL(string: "https://big.example/rss")!])
            XCTFail("expected failure")
        } catch GatewayError.allSourcesFailed(let details) {
            XCTAssertTrue(details.joined().contains("too large"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

final class DigestComposerTests: XCTestCase {
    func testComposesTitleFileNameAndPlainTextBody() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let items = [NewsItem(title: "Story", summary: "", link: "https://a.example/1", source: "a.example", published: nil)]
        let document = DigestComposer.compose(
            summary: "## Highlights\n- **First** event\n- Second `code`", items: items,
            failures: ["down.example: no network."], date: testDate(2026, 10, 2, 8, 5), calendar: calendar
        )
        XCTAssertEqual(document.title, "News Digest · October 2, 2026")
        XCTAssertEqual(document.fileName, "Digest-2026-10-02-0805.pages")
        XCTAssertTrue(document.body.hasPrefix("Highlights\n• First event\n• Second code"))
        XCTAssertTrue(document.body.contains("• Story (a.example)\n  https://a.example/1"))
        XCTAssertTrue(document.body.contains("Could not read:\n• down.example: no network."))
        XCTAssertFalse(document.body.contains("**"))
    }
}

final class NewsDigestJobTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [String] = []
        func add(_ event: String) { lock.withLock { events.append(event) } }
    }

    private struct StubFetcher: NewsFetching {
        let recorder: Recorder
        var result: Result<NewsFetchResult, GatewayError>
        func fetch(sources: [URL]) async throws -> NewsFetchResult {
            recorder.add("fetch:\(sources.count)")
            return try result.get()
        }
    }

    private struct StubSummarizer: DigestSummarizing {
        let recorder: Recorder
        var result: Result<String, GatewayError> = .success("Short summary")
        func summarize(items: [NewsItem], model: ModelReference, date: Date) async throws -> String {
            recorder.add("summarize:\(items.count):\(model.catalogID)")
            return try result.get()
        }
    }

    private struct StubPublisher: DocumentPublishing {
        let recorder: Recorder
        var failure: GatewayError?
        func publish(_ document: DigestDocument, into directory: URL) async throws -> URL {
            recorder.add("publish:\(document.fileName)")
            if let failure { throw failure }
            return directory.appendingPathComponent(document.fileName)
        }
    }

    private let feed = NewsFetchResult(
        items: [
            NewsItem(title: "One", summary: "", link: "https://a.example/1", source: "a", published: nil),
            NewsItem(title: "One", summary: "", link: "https://a.example/1", source: "a", published: nil),
            NewsItem(title: "Two", summary: "", link: "https://a.example/2", source: "a", published: nil),
        ],
        failures: []
    )

    private func job(
        _ recorder: Recorder, fetch: Result<NewsFetchResult, GatewayError>? = nil,
        summary: Result<String, GatewayError> = .success("Short summary"), publishFailure: GatewayError? = nil
    ) -> NewsDigestJob {
        NewsDigestJob(
            fetcher: StubFetcher(recorder: recorder, result: fetch ?? .success(feed)),
            summarizer: StubSummarizer(recorder: recorder, result: summary),
            publisher: StubPublisher(recorder: recorder, failure: publishFailure),
            clock: FakeClock(testDate(2026, 10, 2, 8))
        )
    }

    func testRunsFetchSummarizePublishInOrderWithDedupedItems() async throws {
        let recorder = Recorder()
        var config = enabledConfig()
        config.outputDirectory = "/tmp/digests"
        let output = try await job(recorder).run(config: config, now: testDate(2026, 10, 2, 8))
        XCTAssertEqual(recorder.events, ["fetch:1", "summarize:2:qwen3-0.6b", "publish:Digest-2026-10-02-0800.pages"])
        XCTAssertEqual(output, JobOutput(artifactPath: "/tmp/digests/Digest-2026-10-02-0800.pages", itemCount: 2))
    }

    func testMissingConfigurationFailsBeforeAnyWork() async {
        let recorder = Recorder()
        var noSources = enabledConfig()
        noSources.sources = []
        var noModel = enabledConfig()
        noModel.model = nil
        var noFolder = enabledConfig()
        noFolder.outputDirectory = "  "
        for (config, expected) in [(noSources, GatewayError.noSources), (noModel, .noModelSelected), (noFolder, .outputDirectoryUnavailable("no folder specified."))] {
            do {
                _ = try await job(recorder).run(config: config, now: Date())
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? GatewayError, expected)
            }
        }
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testPropagatesNetworkModelAndDeliveryFailuresWithoutLaterSteps() async {
        let network = Recorder()
        await assertFailure(job(network, fetch: .failure(.allSourcesFailed(["x"]))), expected: .allSourcesFailed(["x"]))
        XCTAssertEqual(network.events, ["fetch:1"])

        let model = Recorder()
        await assertFailure(job(model, summary: .failure(.modelNotDownloaded("qwen3-0.6b"))), expected: .modelNotDownloaded("qwen3-0.6b"))
        XCTAssertEqual(model.events.count, 2)

        let delivery = Recorder()
        await assertFailure(job(delivery, publishFailure: .pagesFailed("access denied")), expected: .pagesFailed("access denied"))
        XCTAssertEqual(delivery.events.count, 3)
    }

    func testNoFreshNewsIsAClearFailure() async {
        let recorder = Recorder()
        await assertFailure(job(recorder, fetch: .success(NewsFetchResult(items: [], failures: []))), expected: .noNews)
        XCTAssertEqual(recorder.events, ["fetch:1"])
    }

    private func assertFailure(_ job: NewsDigestJob, expected: GatewayError, line: UInt = #line) async {
        do {
            _ = try await job.run(config: enabledConfig(), now: Date())
            XCTFail("expected \(expected)", line: line)
        } catch {
            XCTAssertEqual(error as? GatewayError, expected, line: line)
        }
    }
}

final class PagesPublisherTests: XCTestCase {
    func testUniqueURLAvoidsOverwritingExistingDocuments() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = PagesPublisher.uniqueURL(for: "Digest.pages", in: directory)
        XCTAssertEqual(first.lastPathComponent, "Digest.pages")
        try Data().write(to: first)
        XCTAssertEqual(PagesPublisher.uniqueURL(for: "Digest.pages", in: directory).lastPathComponent, "Digest-2.pages")
    }

    func testAutomationDeniedProducesActionableMessage() {
        let message = PagesPublisher.describe("execution error: Not authorized to send Apple events to Pages. (-1743)")
        XCTAssertTrue(message.contains("Automation"))
        XCTAssertFalse(PagesPublisher.describe("").isEmpty)
    }
}
