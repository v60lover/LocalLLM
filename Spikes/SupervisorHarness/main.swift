import Foundation
import os

// Live check of WorkerSupervisor + XPCWorkerConnector against the real worker XPC service.
// Built by hand into a copy of LocalLLMGateway.app: see build.sh and NOTES.md in this directory.
// Not part of the Xcode project.
let model = ProcessInfo.processInfo.environment["MODEL"] ?? ""
var policy = WorkerSupervisorPolicy()
policy.idleTimeout = .seconds(4)
policy.pingInterval = .seconds(1)
policy.pingTimeout = .seconds(3)
let supervisor = WorkerSupervisor(connector: XPCWorkerConnector(), policy: policy)

func run(
    _ label: String, _ prompt: String, instructions: String = "Answer in one short sentence.", maxTokens: Int = 512
) async {
    let started = Date()
    do {
        let streamed = OSAllocatedUnfairLock(initialState: 0)
        let result = try await supervisor.generate(
            WorkerJob(model: .path(model), instructions: instructions, transcript: nil,
                      prompt: prompt, options: WorkerGenerationOptions(temperature: nil, maximumResponseTokens: maxTokens))
        ) { text in streamed.withLock { $0 += text.count } }
        print("\(label): OK in \(String(format: "%.1f", Date().timeIntervalSince(started)))s, streamed \(streamed.withLock { $0 }) chars, tokens \(result.usedTokens): \(result.text.prefix(80))")
    } catch {
        print("\(label): FAILED \(error)")
    }
    print("  state = \(await supervisor.state)")
}

struct FixedLocator: ModelLocating {
    let path: String
    func localPath(for model: ModelReference) -> String? { path }
}

/// The Gateway's real digest path: one verdict job per item, then the digest job.
func digest() async {
    let titles = [
        "Rescuers free all 12 miners trapped underground for three days",
        "Earthquake kills dozens and destroys hundreds of homes",
        "New malaria vaccine cuts child deaths by half in trial",
        "Bank fraud scandal wipes out pensioners' savings",
    ]
    let items = titles.enumerated().map { index, title in
        NewsItem(title: title, summary: "", link: "https://example.com/\(index)", source: "example.com", published: nil)
    }
    let started = Date()
    do {
        let summary = try await WorkerDigestSummarizer(worker: supervisor, locator: FixedLocator(path: model))
            .summarize(items: items, model: ModelReference(catalogID: "harness", repo: "", path: nil, revision: ""))
        print("digest: OK in \(String(format: "%.1f", Date().timeIntervalSince(started)))s, good = \(summary.items.map(\.title))")
        print("  text: \(summary.text)")
    } catch {
        print("digest: FAILED \(error)")
    }
    print("  state = \(await supervisor.state)")
}

Task {
    await run("cold", "What is the capital of France? /no_think")
    await run("warm", "What is 2+2? /no_think")
    print("waiting for idle unload…")
    try? await Task.sleep(for: .seconds(6))
    print("  state = \(await supervisor.state)")
    await run("after-idle", "Name a color. /no_think")
    // Longer than pingInterval + pingTimeout: pings must be answered while inference runs,
    // or the supervisor kills the worker and this fails with interrupted(unresponsive).
    await run("long", "Write a very long, detailed history of the Roman Empire, century by century. /no_think",
              instructions: "You write long, exhaustive texts and never stop early.", maxTokens: 3500)
    // No pause between the kill and the reconnect: the new connection must get a fresh worker.
    await supervisor.unloadNow()
    await run("after-unload", "Name a fruit. /no_think")
    await digest()
    exit(0)
}
dispatchMain()
