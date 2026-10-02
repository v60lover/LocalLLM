import CoreAIKit
import Foundation
import FoundationModels

/// Summarizes with the model the user selected in the app, straight from the CoreAIKit cache.
/// The model is loaded per run and released afterwards: the Gateway is long-lived and idle
/// almost all day, so it should not pin hundreds of MB of weights.
struct LocalModelSummarizer: DigestSummarizing {
    func summarize(items: [NewsItem], model: ModelReference, date: Date) async throws -> String {
        let id = ModelID(model.repo, path: model.path, revision: model.revision)
        guard let url = ModelStore.default.localURL(for: id) else {
            throw GatewayError.modelNotDownloaded(model.catalogID)
        }
        let languageModel: KitLanguageModel
        do {
            languageModel = try await KitLanguageModel(bundleAt: url)
        } catch {
            throw GatewayError.modelUnavailable(error.localizedDescription)
        }
        do {
            return try await Self.respond(
                model: languageModel, catalogID: model.catalogID, items: items
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GatewayError {
            throw error
        } catch {
            // A thinking-only answer can run out of tokens; retry once with fewer items.
            do {
                return try await Self.respond(
                    model: languageModel, catalogID: model.catalogID,
                    items: Array(items.prefix(max(4, items.count / 2)))
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw GatewayError.summarizationFailed(error.localizedDescription)
            }
        }
    }

    @MainActor
    private static func respond(
        model: KitLanguageModel, catalogID: String, items: [NewsItem]
    ) async throws -> String {
        let session = LanguageModelSession(
            model: model,
            instructions: "You are a news digest editor. Write in English, concisely, and only from the facts in the list."
        )
        let list = items.enumerated().map { index, item in
            "\(index + 1). [\(item.source)] \(item.title)" + (item.summary.isEmpty ? "" : " — \(item.summary)")
        }.joined(separator: "\n")
        let prompt = """
        Here is a list of fresh news items:
        \(list)

        Write a concise morning digest: 5–8 points, each one or two sentences.
        Group related topics. Do not invent facts and do not add links or Markdown formatting.
        \(catalogID.hasPrefix("qwen3") ? "/no_think" : "")
        """
        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(maximumResponseTokens: 1200, toolCallingMode: .disallowed)
        )
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GatewayError.summarizationFailed("empty response") }
        return text
    }
}
