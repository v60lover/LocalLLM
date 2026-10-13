import CoreAIKit
import Foundation
import FoundationModels

/// A chat model the user can pick. Independent of CoreAIKit so the store can be tested with fakes.
struct ChatModelOption: Identifiable, Equatable, Sendable {
    struct Source: Equatable, Sendable {
        var repo: String
        var path: String?
        var revision: String
    }

    let id: String
    let name: String
    let source: Source?
}

struct GenerationOutcome {
    let text: String
    let transcript: Transcript
    let usedTokens: Int
}

enum ChatRuntimeError: LocalizedError, Equatable {
    case contextOverflow
    /// The model service went away mid-reply. Nothing of the reply is kept; sending again
    /// reconnects.
    case interrupted

    var errorDescription: String? {
        switch self {
        case .interrupted:
            "The reply was interrupted because the connection to the Gateway was lost. Send your message again."
        case .contextOverflow:
            "The conversation no longer fits in the model's context window. Start a new chat."
        }
    }
}

/// One conversation's session with a loaded model.
@MainActor
protocol ChatRuntime: AnyObject {
    var supportsTools: Bool { get }
    /// Upper bound on tokens one reply may use; context below this is considered exhausted.
    var responseTokenBudget: Int { get }
    var transcript: Transcript { get }
    func generate(
        prompt: String, onSnapshot: @MainActor (String, Int) -> Void
    ) async throws -> GenerationOutcome
}

@MainActor
protocol ChatModelHandle {
    var contextSize: Int? { get }
    func makeRuntime(
        transcript: Transcript?, report: @escaping @Sendable (ToolEvent) async -> Void
    ) -> any ChatRuntime
}

/// Everything the store needs from the model layer: catalog, local cache and loading.
@MainActor
protocol ChatBackend {
    func loadCatalog() async -> [ChatModelOption]
    func cachedModelIDs(among options: [ChatModelOption]) -> Set<String>
    func load(
        _ option: ChatModelOption, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> any ChatModelHandle
}

@MainActor
final class CoreAIBackend: ChatBackend {
    private let executor: any ToolExecutor
    private var entries: [String: CatalogEntry] = [:]

    init(executor: any ToolExecutor = InProcessToolExecutor()) {
        self.executor = executor
    }

    func loadCatalog() async -> [ChatModelOption] {
        let available = await ModelCatalog.load().available(.chat)
        entries = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return available.map { entry in
            ChatModelOption(
                id: entry.id, name: entry.name,
                source: entry.modelID.map {
                    ChatModelOption.Source(repo: $0.repo, path: $0.path, revision: $0.revision)
                }
            )
        }
    }

    func cachedModelIDs(among options: [ChatModelOption]) -> Set<String> {
        Set(options.compactMap { option in
            guard let model = entries[option.id]?.modelID,
                  ModelStore.default.localURL(for: model) != nil else { return nil }
            return option.id
        })
    }

    func load(
        _ option: ChatModelOption, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> any ChatModelHandle {
        guard let modelID = entries[option.id]?.modelID else {
            throw ChatBackendError.modelUnavailable(option.name)
        }
        let url = try await ModelStore.default.download(modelID) { progress($0.fraction) }
        let model = try await KitLanguageModel(bundleAt: url)
        return CoreAIModelHandle(
            model: model, contextSize: Self.readContextSize(from: url), executor: executor
        )
    }

    private static func readContextSize(from url: URL) -> Int? {
        struct Metadata: Decodable {
            struct Language: Decodable {
                let maxContextLength: Int
                enum CodingKeys: String, CodingKey {
                    case maxContextLength = "max_context_length"
                }
            }
            let language: Language
        }
        let metadataURL = url.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let size = try? JSONDecoder().decode(Metadata.self, from: data).language.maxContextLength,
              size > 0 else { return nil }
        return size
    }
}

enum ChatBackendError: LocalizedError {
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let name): "“\(name)” cannot be downloaded."
        }
    }
}

private struct CoreAIModelHandle: ChatModelHandle {
    let model: KitLanguageModel
    let contextSize: Int?
    let executor: any ToolExecutor

    func makeRuntime(
        transcript: Transcript?, report: @escaping @Sendable (ToolEvent) async -> Void
    ) -> any ChatRuntime {
        AgentRuntime(model: model, transcript: transcript, executor: executor, report: report)
    }
}

#if os(macOS)
extension CoreAIBackend {
    /// Makes sure the model is on disk and says where the Gateway finds it, without loading it
    /// into this process: the Gateway's worker is the one that loads and runs it.
    func downloadedModel(
        for option: ChatModelOption, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (reference: ModelReference, contextSize: Int?) {
        guard let modelID = entries[option.id]?.modelID else {
            throw ChatBackendError.modelUnavailable(option.name)
        }
        let url = try await ModelStore.default.download(modelID) { progress($0.fraction) }
        let reference = ModelReference(
            catalogID: option.id, repo: modelID.repo, path: modelID.path, revision: modelID.revision
        )
        return (reference, Self.readContextSize(from: url))
    }
}
#endif
