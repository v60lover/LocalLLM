#if os(macOS)
import Foundation

struct NewsItem: Codable, Equatable, Sendable {
    var title: String
    var summary: String
    var link: String
    var source: String
    var published: Date?
}

struct NewsFetchResult: Equatable, Sendable {
    var items: [NewsItem]
    /// Human-readable notes about sources that could not be read.
    var failures: [String]
}

protocol NewsFetching: Sendable {
    func fetch(sources: [URL]) async throws -> NewsFetchResult
}

protocol DigestSummarizing: Sendable {
    func summarize(items: [NewsItem], model: ModelReference, date: Date) async throws -> String
}

struct DigestDocument: Equatable, Sendable {
    var title: String
    var body: String
    var fileName: String
}

protocol DocumentPublishing: Sendable {
    func publish(_ document: DigestDocument, into directory: URL) async throws -> URL
}

// MARK: - Bounds and de-duplication

struct NewsPolicy: Sendable {
    var maxItemsPerSource = 8
    var maxTotalItems = 24
    var maxTitleCharacters = 160
    var maxSummaryCharacters = 240
    var maxResponseBytes = 2_000_000
    var requestTimeout: TimeInterval = 20
}

enum NewsPreparation {
    /// De-duplicates by link or normalized title, keeps the newest items per source, then
    /// interleaves sources so one noisy feed cannot crowd out the others.
    static func prepare(_ items: [NewsItem], policy: NewsPolicy = NewsPolicy()) -> [NewsItem] {
        var seen = Set<String>()
        var perSource: [String: [NewsItem]] = [:]
        var sourceOrder: [String] = []
        let sorted = items.enumerated().sorted { lhs, rhs in
            switch (lhs.element.published, rhs.element.published) {
            case let (a?, b?) where a != b: return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }
        for (_, original) in sorted {
            var item = original
            item.title = truncate(item.title, policy.maxTitleCharacters)
            item.summary = truncate(item.summary, policy.maxSummaryCharacters)
            guard !item.title.isEmpty else { continue }
            let keys = [normalizedLink(item.link), "t:" + normalizedTitle(item.title)].compactMap { $0 }
            guard !keys.contains(where: seen.contains) else { continue }
            guard (perSource[item.source]?.count ?? 0) < policy.maxItemsPerSource else { continue }
            seen.formUnion(keys)
            if perSource[item.source] == nil { sourceOrder.append(item.source) }
            perSource[item.source, default: []].append(item)
        }
        var result: [NewsItem] = []
        var round = 0
        while result.count < policy.maxTotalItems {
            var added = false
            for source in sourceOrder {
                guard let list = perSource[source], round < list.count,
                      result.count < policy.maxTotalItems else { continue }
                result.append(list[round])
                added = true
            }
            if !added { break }
            round += 1
        }
        return result
    }

    static func truncate(_ text: String, _ limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func normalizedLink(_ link: String) -> String? {
        guard var components = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.host != nil else { return nil }
        components.fragment = nil
        components.query = nil
        components.scheme = nil
        let value = (components.host ?? "") + components.path
        return "l:" + value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

// MARK: - Feed parsing (RSS 2.0 and Atom)

enum FeedParser {
    static func parse(_ data: Data, source: String) -> [NewsItem] {
        let delegate = Delegate(source: source)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let source: String
        var items: [NewsItem] = []
        private var inEntry = false
        private var element = ""
        private var text = ""
        private var title = "", summary = "", content = "", link = "", dateText = ""

        init(source: String) { self.source = source }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            let name = elementName.lowercased()
            if name == "item" || name == "entry" {
                inEntry = true
                title = ""; summary = ""; content = ""; link = ""; dateText = ""
            }
            guard inEntry else { return }
            element = name
            text = ""
            if name == "link", let href = attributes["href"], link.isEmpty,
               attributes["rel"] == nil || attributes["rel"] == "alternate" {
                link = href
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inEntry { text += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if inEntry { text += String(decoding: CDATABlock, as: UTF8.self) }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
            qualifiedName: String?
        ) {
            let name = elementName.lowercased()
            guard inEntry else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "title": if title.isEmpty { title = value }
            case "description", "summary": if summary.isEmpty { summary = value }
            case "content", "content:encoded": if content.isEmpty { content = value }
            case "link": if link.isEmpty { link = value }
            case "pubdate", "published", "updated", "dc:date":
                if dateText.isEmpty || name != "updated" { dateText = value }
            case "item", "entry":
                inEntry = false
                let body = summary.isEmpty ? content : summary
                items.append(NewsItem(
                    title: HTMLText.plain(title), summary: HTMLText.plain(body),
                    link: link, source: source, published: FeedDate.parse(dateText)
                ))
            default: break
            }
            text = ""
        }
    }
}

enum FeedDate {
    static func parse(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

enum HTMLText {
    static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#39;": "'", "&apos;": "'", "&#8217;": "’", "&#8211;": "–", "&#8212;": "—"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - Fetching

struct URLSessionNewsFetcher: NewsFetching {
    var session: URLSession = .shared
    var policy = NewsPolicy()

    func fetch(sources: [URL]) async throws -> NewsFetchResult {
        var items: [NewsItem] = []
        var failures: [String] = []
        try await withThrowingTaskGroup(of: (URL, Result<[NewsItem], any Error>).self) { group in
            for url in sources {
                group.addTask { (url, await load(url)) }
            }
            for try await (url, result) in group {
                switch result {
                case .success(let found): items += found
                case .failure(let error): failures.append("\(url.host ?? url.absoluteString): \(error.localizedDescription).")
                }
            }
        }
        try Task.checkCancellation()
        if items.isEmpty && failures.count == sources.count {
            throw GatewayError.allSourcesFailed(failures.sorted())
        }
        return NewsFetchResult(items: items, failures: failures.sorted())
    }

    private func load(_ url: URL) async -> Result<[NewsItem], any Error> {
        var request = URLRequest(url: url, timeoutInterval: policy.requestTimeout)
        request.setValue("application/rss+xml, application/atom+xml, application/xml;q=0.9, */*;q=0.5",
                         forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw FetchError.status(http.statusCode)
            }
            guard data.count <= policy.maxResponseBytes else { throw FetchError.tooLarge }
            let parsed = FeedParser.parse(data, source: url.host ?? url.absoluteString)
            guard !parsed.isEmpty else { throw FetchError.notAFeed }
            return .success(parsed)
        } catch is CancellationError {
            return .failure(CancellationError())
        } catch {
            return .failure(error)
        }
    }

    enum FetchError: LocalizedError {
        case status(Int), tooLarge, notAFeed
        var errorDescription: String? {
            switch self {
            case .status(let code): "HTTP \(code) response"
            case .tooLarge: "response too large"
            case .notAFeed: "not an RSS/Atom feed"
            }
        }
    }
}

// MARK: - Document composition

enum DigestComposer {
    static func compose(
        summary: String, items: [NewsItem], failures: [String], date: Date, calendar: Calendar
    ) -> DigestDocument {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMMM d, yyyy"
        var body = PlainText.fromMarkdown(summary)
        body += "\n\nSources\n"
        for item in items {
            body += "• \(item.title) (\(item.source))"
            if !item.link.isEmpty { body += "\n  \(item.link)" }
            body += "\n"
        }
        if !failures.isEmpty {
            body += "\nCould not read:\n" + failures.map { "• \($0)" }.joined(separator: "\n") + "\n"
        }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let name = String(
            format: "Digest-%@-%02d%02d.pages",
            DigestSchedule.dayKey(date, calendar: calendar), parts.hour ?? 0, parts.minute ?? 0
        )
        return DigestDocument(
            title: "News Digest · \(formatter.string(from: date))", body: body, fileName: name
        )
    }
}

enum PlainText {
    /// Pages receives plain text, so strip the Markdown a small model likes to emit.
    static func fromMarkdown(_ text: String) -> String {
        var lines: [String] = []
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            line = line.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^[-*]\s+"#, with: "• ", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
            lines.append(line)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - The job

struct NewsDigestJob: GatewayJob {
    let id = GatewayConstants.newsDigestJobID
    let fetcher: any NewsFetching
    let summarizer: any DigestSummarizing
    let publisher: any DocumentPublishing
    var policy = NewsPolicy()
    var clock: any GatewayClock = SystemGatewayClock()

    func run(config: DigestConfig, now: Date) async throws -> JobOutput {
        let sources = config.sourceURLs
        guard !sources.isEmpty else { throw GatewayError.noSources }
        guard let model = config.model else { throw GatewayError.noModelSelected }
        let directory = config.outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else {
            throw GatewayError.outputDirectoryUnavailable("no folder specified.")
        }

        try Task.checkCancellation()
        let fetched = try await fetcher.fetch(sources: sources)
        let items = NewsPreparation.prepare(fetched.items, policy: policy)
        guard !items.isEmpty else { throw GatewayError.noNews }

        try Task.checkCancellation()
        let summary = try await summarizer.summarize(items: items, model: model, date: now)
        let document = DigestComposer.compose(
            summary: summary, items: items, failures: fetched.failures, date: now,
            calendar: clock.calendar
        )

        try Task.checkCancellation()
        let url = try await publisher.publish(
            document, into: URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
        )
        return JobOutput(artifactPath: url.path, itemCount: items.count)
    }
}
#endif
