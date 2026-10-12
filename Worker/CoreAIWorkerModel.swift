import CoreAIKit
import Foundation
import FoundationModels

/// Production model access: loads a KitLanguageModel from a local bundle. No network access.
struct CoreAIModelLoader: WorkerModelLoading {
    func load(_ location: WorkerModelLocation) async throws -> any WorkerLoadedModel {
        switch location {
        case .path(let path):
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw WorkerFailure(kind: .modelLoadFailed, message: "Model bundle not found.")
            }
            let model = try await KitLanguageModel(bundleAt: url)
            return CoreAILoadedModel(model: model, contextSize: Self.readContextSize(from: url))
        }
    }

    private static func readContextSize(from url: URL) -> Int? {
        struct Metadata: Decodable {
            struct Language: Decodable {
                let maxContextLength: Int
                enum CodingKeys: String, CodingKey { case maxContextLength = "max_context_length" }
            }
            let language: Language
        }
        guard let data = try? Data(contentsOf: url.appendingPathComponent("metadata.json")),
              let size = try? JSONDecoder().decode(Metadata.self, from: data).language.maxContextLength,
              size > 0 else { return nil }
        return size
    }
}

private struct CoreAILoadedModel: WorkerLoadedModel {
    let model: KitLanguageModel
    let contextSize: Int?

    func makeSession(instructions: String?, transcript: Data?) throws -> any WorkerLanguageSession {
        // Tool calls across processes are not wired yet (ac3.13), so sessions carry no tools.
        let session: LanguageModelSession
        if let transcript {
            let decoded = try WorkerWire.decoder.decode(Transcript.self, from: transcript)
            session = LanguageModelSession(model: model, tools: [], transcript: decoded)
        } else {
            session = LanguageModelSession(model: model, tools: [], instructions: instructions ?? "")
        }
        return CoreAISession(session: session)
    }
}

private final class CoreAISession: WorkerLanguageSession, @unchecked Sendable {
    // The engine runs at most one generation per session, so access is serialized.
    private let session: LanguageModelSession

    init(session: LanguageModelSession) { self.session = session }

    func respond(
        to prompt: String, options: WorkerGenerationOptions,
        onSnapshot: @Sendable (String, Int) -> Void
    ) async throws -> WorkerSessionResult {
        var generation = GenerationOptions(maximumResponseTokens: options.maximumResponseTokens)
        if let temperature = options.temperature { generation.temperature = temperature }
        do {
            for try await snapshot in session.streamResponse(to: prompt, options: generation) {
                try Task.checkCancellation()
                onSnapshot(
                    snapshot.content,
                    snapshot.usage.input.totalTokenCount + snapshot.usage.output.totalTokenCount
                )
            }
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            throw WorkerFailure(kind: .contextOverflow, message: "The context window is full.")
        }
        let usage = session.usage
        return WorkerSessionResult(
            transcript: try WorkerWire.encoder.encode(session.transcript),
            usedTokens: usage.input.totalTokenCount + usage.output.totalTokenCount
        )
    }
}
