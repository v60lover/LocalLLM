#if os(macOS)
import Foundation

/// Creates a `.pages` document through Pages' scripting interface and leaves it open.
struct PagesPublisher: DocumentPublishing {
    func publish(_ document: DigestDocument, into directory: URL) async throws -> URL {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw GatewayError.outputDirectoryUnavailable(error.localizedDescription)
        }
        let destination = Self.uniqueURL(for: document.fileName, in: directory)
        try Task.checkCancellation()
        let result = try await ProcessRunner.run(
            "/usr/bin/osascript",
            ["-e", Self.script, "--", document.title, document.body, destination.path]
        )
        try Task.checkCancellation()
        guard result.status == 0, FileManager.default.fileExists(atPath: destination.path) else {
            throw GatewayError.pagesFailed(Self.describe(result.stderr))
        }
        return destination
    }

    static func uniqueURL(for fileName: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(fileName)
        let base = candidate.deletingPathExtension().lastPathComponent
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(counter).pages")
            counter += 1
        }
        return candidate
    }

    static func describe(_ stderr: String) -> String {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.contains("-1743") {
            return "Not allowed to control Pages. Open System Settings → Privacy & Security → Automation and allow LocalLLMGateway to control Pages."
        }
        if detail.contains("-600") || detail.contains("-10810") {
            return "Could not launch Pages. Log in to a macOS session and make sure Pages is installed."
        }
        return detail.isEmpty ? "Could not create the document in Pages." : "Pages: \(detail)"
    }

    private static let script = """
    on run argv
        set documentTitle to item 1 of argv
        set documentBody to item 2 of argv
        set destinationPath to item 3 of argv
        tell application "Pages"
            activate
            set newDocument to make new document
            tell newDocument
                set body text to documentTitle & return & return & documentBody
                set size of paragraph 1 of body text to 26
                set font of paragraph 1 of body text to "Helvetica Neue Bold"
            end tell
            save newDocument in POSIX file destinationPath
        end tell
        return documentTitle
    end run
    """
}

enum ProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let stderr: String
    }

    private final class Box: @unchecked Sendable {
        let process = Process()
    }

    /// Runs a process, terminating it if the surrounding task is cancelled.
    static func run(_ executable: String, _ arguments: [String]) async throws -> Output {
        let box = Box()
        box.process.executableURL = URL(fileURLWithPath: executable)
        box.process.arguments = arguments
        let errors = Pipe()
        box.process.standardError = errors
        box.process.standardOutput = FileHandle.nullDevice
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.process.terminationHandler = { process in
                    let data = errors.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: Output(
                        status: process.terminationStatus, stderr: String(decoding: data, as: UTF8.self)
                    ))
                }
                do { try box.process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
    }
}
#endif
