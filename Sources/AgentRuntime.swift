import CoreAIKit
import Foundation
import FoundationModels

enum ToolCall: Sendable {
    case openModelPicker
}

struct ToolResult: Sendable {
    let message: String
    let opensModelPicker: Bool
}

protocol ToolExecutor: Sendable {
    func execute(_ call: ToolCall) async throws -> ToolResult
}

actor InProcessToolExecutor: ToolExecutor {
    func execute(_ call: ToolCall) async throws -> ToolResult {
        try Task.checkCancellation()
        switch call {
        case .openModelPicker:
            return ToolResult(message: "Model picker opened.", opensModelPicker: true)
        }
    }
}

enum ToolEvent: Sendable {
    case started(id: UUID, title: String)
    case completed(id: UUID, result: ToolResult)
    case failed(id: UUID, message: String)
}

struct OpenModelPickerTool: Tool {
    let name = "open_model_picker"
    let description = "Open the app's model picker when the user asks to choose or change a model."
    let executor: any ToolExecutor
    let report: @Sendable (ToolEvent) async -> Void

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let id = UUID()
        await report(.started(id: id, title: "Opening model picker"))
        do {
            let result = try await executor.execute(.openModelPicker)
            await report(.completed(id: id, result: result))
            return result.message
        } catch let error as CancellationError {
            await report(.failed(id: id, message: "Operation stopped"))
            throw error
        } catch {
            await report(.failed(id: id, message: error.localizedDescription))
            return "Could not open the model picker: \(error.localizedDescription)."
        }
    }
}

@MainActor
final class AgentRuntime: ChatRuntime {
    private let session: LanguageModelSession
    let supportsTools: Bool

    init(
        model: KitLanguageModel,
        transcript: Transcript?,
        executor: any ToolExecutor,
        report: @escaping @Sendable (ToolEvent) async -> Void
    ) {
        supportsTools = model.capabilities.contains(.toolCalling)
        let tools: [any Tool] = supportsTools
            ? [OpenModelPickerTool(executor: executor, report: report)] : []
        if let transcript {
            session = LanguageModelSession(model: model, tools: tools, transcript: transcript)
        } else {
            session = LanguageModelSession(
                model: model,
                tools: tools,
                instructions: "Answer in the user's language. Use tools only when the user requests an action."
            )
        }
    }

    #if os(iOS)
    let responseTokenBudget = 896
    #else
    let responseTokenBudget = 2048
    #endif

    func generate(
        prompt: String,
        onSnapshot: @MainActor (String, Int) -> Void
    ) async throws -> GenerationOutcome {
        var answer = ""
        let options = GenerationOptions(maximumResponseTokens: responseTokenBudget)
        do {
            for try await snapshot in session.streamResponse(to: prompt, options: options) {
                try Task.checkCancellation()
                answer = snapshot.content
                onSnapshot(
                    answer,
                    snapshot.usage.input.totalTokenCount + snapshot.usage.output.totalTokenCount
                )
            }
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            throw ChatRuntimeError.contextOverflow
        }
        let usage = session.usage
        return GenerationOutcome(
            text: answer,
            transcript: session.transcript,
            usedTokens: usage.input.totalTokenCount + usage.output.totalTokenCount
        )
    }

    var transcript: Transcript { session.transcript }
}
