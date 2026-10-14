import Foundation
import OSLog

/// What the summarizer needs from the worker's owner. `WorkerSupervisor` conforms; tests use a stub.
protocol DigestWorkerRunning: Sendable {
    /// One generation in a fresh worker session. Honors cancellation (see `WorkerSupervisor.generate`).
    func generate(
        _ job: WorkerJob, onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> WorkerJobResult
    /// Clears the crash counter and leaves safe mode.
    func leaveSafeMode() async
}

extension WorkerSupervisor: DigestWorkerRunning {}

/// Resolves a configured model to its bundle on disk.
protocol ModelLocating: Sendable {
    /// The local bundle directory, or nil when the model is not downloaded.
    func localPath(for model: ModelReference) -> String?
}

/// Picks the good news and summarizes it on the inference worker. The Gateway keeps the prompts
/// and the verdict parsing (`GoodNewsFilter`); the worker only loads the model and generates.
///
/// - One `WorkerJob` per verdict: the supervisor opens a fresh session per job, so verdicts cannot
///   influence each other or fill the context.
/// - Cancellation is never a failure: it propagates as `CancellationError`, and nothing is issued
///   after it. The run's overall time limit is the engine's; it cancels this task when it elapses.
/// - Every run starts by leaving safe mode: nothing else does, and without it one bad night would
///   fail every digest until the Gateway restarts. The run's own retry budget (3 a day, 10 minutes
///   apart) and the supervisor's crash limit within a run bound the cost.
/// - The model is left warm; the supervisor unloads it after its idle timeout.
struct WorkerDigestSummarizer: DigestSummarizing {
    /// Covers the think block as well as the one-word answer: thinking stays on (see `digestPrompt`).
    static let verdictTokenLimit = 512
    static let digestTokenLimit = 1200

    let worker: any DigestWorkerRunning
    let locator: any ModelLocating
    private let log = Logger(subsystem: GatewayConstants.label, category: "digest")

    func summarize(items: [NewsItem], model: ModelReference) async throws -> DigestSummary {
        guard let path = locator.localPath(for: model) else {
            throw GatewayError.modelNotDownloaded(model.catalogID)
        }
        log.info("digest: summarizing \(items.count, privacy: .public) items, model at \(path, privacy: .public)")
        await worker.leaveSafeMode()
        let location = WorkerModelLocation.path(path)
        do {
            var good: [NewsItem] = []
            for (index, item) in items.enumerated() {
                try Task.checkCancellation()
                let began = ContinuousClock.now
                let verdict = try await isGoodNews(item, location: location)
                if verdict { good.append(item) }
                log.info("""
                    digest: verdict \(index + 1, privacy: .public)/\(items.count, privacy: .public) \
                    good=\(verdict, privacy: .public) \
                    took \(began.duration(to: .now).description, privacy: .public) \
                    [\(item.source, privacy: .public)] \(item.title, privacy: .public)
                    """)
            }
            guard !good.isEmpty else { throw GatewayError.noGoodNews }
            let began = ContinuousClock.now
            let text = try await digest(good, location: location)
            log.info("""
                digest: written from \(good.count, privacy: .public) items, \
                \(text.count, privacy: .public) chars, \
                took \(began.duration(to: .now).description, privacy: .public)
                """)
            return DigestSummary(text: text, items: good)
        } catch {
            if error is CancellationError {
                log.info("digest: cancelled")
            } else {
                log.error("digest: worker stage failed: \(String(describing: error), privacy: .public)")
            }
            throw Self.mapped(error)
        }
    }

    // MARK: Stages

    private func isGoodNews(_ item: NewsItem, location: WorkerModelLocation) async throws -> Bool {
        let result = try await worker.generate(
            WorkerJob(
                model: location, instructions: GoodNewsFilter.instructions, transcript: nil,
                prompt: GoodNewsFilter.prompt(for: item),
                options: WorkerGenerationOptions(maximumResponseTokens: Self.verdictTokenLimit)
            ),
            onDelta: { _ in }
        )
        return GoodNewsFilter.isGood(result.text)
    }

    private func digest(_ items: [NewsItem], location: WorkerModelLocation) async throws -> String {
        do {
            return try await respond(items, location: location)
        } catch let error where Self.isTooMuchForTheModel(error) {
            log.info("digest: retrying with fewer items after \(String(describing: error), privacy: .public)")
            // A thinking-only answer can run out of tokens, or the list can overflow the context;
            // retry once with fewer items.
            return try await respond(Array(items.prefix(max(4, items.count / 2))), location: location)
        }
    }

    private func respond(_ items: [NewsItem], location: WorkerModelLocation) async throws -> String {
        let result = try await worker.generate(
            WorkerJob(
                model: location, instructions: Self.digestInstructions, transcript: nil,
                prompt: Self.digestPrompt(for: items),
                options: WorkerGenerationOptions(maximumResponseTokens: Self.digestTokenLimit)
            ),
            onDelta: { _ in }
        )
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GatewayError.summarizationFailed("empty response") }
        return text
    }

    // MARK: Prompts

    static let digestInstructions =
        "You are a news digest editor. Write in English, concisely, and only from the facts in the list."

    /// No prompt switches thinking off: with "/no_think" qwen3-0.6b generates up to the token limit
    /// without ever answering these prompts (LocalLLMChat-ac3.17). The token limits pay for the
    /// think block instead.
    static func digestPrompt(for items: [NewsItem]) -> String {
        let list = items.enumerated().map { index, item in
            "\(index + 1). [\(item.source)] \(item.title)" + (item.summary.isEmpty ? "" : " — \(item.summary)")
        }.joined(separator: "\n")
        return """
        Here is a list of fresh good news items:
        \(list)

        Write a concise morning good-news digest: at most 8 points, each one or two sentences.
        Group related topics. Do not invent facts and do not add links or Markdown formatting.
        """
    }

    // MARK: Errors

    private static func isTooMuchForTheModel(_ error: any Error) -> Bool {
        guard case WorkerSupervisorError.worker(let failure) = error else { return false }
        return failure.kind == .internalError || failure.kind == .contextOverflow
    }

    /// Cancellation and Gateway errors pass through; worker failures become the user-facing
    /// errors the engine records.
    static func mapped(_ error: any Error) -> any Error {
        switch error {
        case is CancellationError, is GatewayError:
            return error
        case WorkerSupervisorError.worker(let failure):
            switch failure.kind {
            case .modelLoadFailed, .unsupportedProtocol:
                return GatewayError.modelUnavailable(failure.message)
            default:
                return GatewayError.summarizationFailed(failure.message)
            }
        case WorkerSupervisorError.loadTimedOut:
            return GatewayError.modelUnavailable("loading the model timed out.")
        case WorkerSupervisorError.safeMode:
            return GatewayError.modelUnavailable("the model worker was stopped after repeated crashes.")
        case WorkerSupervisorError.memoryPressure:
            return GatewayError.summarizationFailed("the Mac is low on memory, so the model was unloaded.")
        case WorkerSupervisorError.interrupted(let reason, _):
            let what = reason == .crashed ? "stopped unexpectedly" : "stopped responding"
            return GatewayError.summarizationFailed("the model worker \(what).")
        default:
            return GatewayError.summarizationFailed(error.localizedDescription)
        }
    }
}
