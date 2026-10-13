# Harness: WorkerSupervisor against the real worker XPC service (LocalLLMChat-ac3.6)

Drives `WorkerSupervisor` + `XPCWorkerConnector` end to end (cold load, warm reuse, idle unload,
reload, a long generation, a job straight after an unload) with short timeouts, then runs the Gateway's
real digest path (`WorkerDigestSummarizer`: one 16-token verdict job per item, then the digest job) on four
sample headlines. Not part of the Xcode project.

## Build and run

```
xcodebuild build -scheme LocalLLMChat -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=     # once, builds LocalLLMGateway.app + Worker
./build.sh                                                          # or ./build.sh /path/to/LocalLLMGateway.app
MODEL=/path/to/model build/Harness.app/Contents/MacOS/LocalLLMGateway
```

`build.sh` copies the built `LocalLLMGateway.app` (it already embeds `Contents/XPCServices/LocalLLMWorker.xpc`),
compiles `main.swift` with the supervisor, the connector, the summarizer and the Gateway sources they need
(see the file list in `build.sh`) over the app's executable, and re-signs ad-hoc. The helper must stay inside an `.app`,
because XPC service lookup is relative to the main bundle (see `Spikes/EmbeddedXPC/NOTES.md`).

## Verified

- `build.sh` builds with Swift 6 language mode; the executable runs directly (no launchd) and reaches the worker.
- With `MODEL=/nonexistent` (2026-10-13): connect, hello and a refused load (`modelLoadFailed`) work. The
  worker is retired after each refusal, so every job reconnects to a fresh process; five refusals in a
  row leave `state = idle`, not safe mode.
- With a real model (qwen3-0.6b, 4-bit, from the CoreAIKit cache; 2026-10-13, ad-hoc signed Debug build):
  cold job 1.6 s, warm job 0.1 s, tokens streamed as deltas in both; the idle unload leaves `state = idle`;
  the job after it reloads on a fresh worker in 4.6 s (this includes the launchd respawn wait below).
- Pings during inference: a 24.7 s generation (2480 tokens) completes with `pingInterval` 1 s and
  `pingTimeout` 3 s, so the worker answers pings while it generates.
- A job issued straight after `unloadNow()` (no pause after the kill) runs on a fresh worker without an
  interruption; it took 1.5 s to 10.5 s depending on the launchd respawn wait below.
- When the harness exits, no `LocalLLMWorker` process is left one second later (the worker's
  `_exit(0)` on connection invalidation).

- Digest path (LocalLLMChat-ac3.10 and ac3.17, 2026-10-13, qwen3-0.6b): `WorkerDigestSummarizer` runs four
  verdict jobs and the digest job on the real worker in 8.8 s and returns the digest text; `state = ready`
  afterwards and no worker is left after exit. Single verdicts took 1.2 s to 2.7 s and 262 to 380 tokens in
  total (prompt included), the digest job 3.0 s to 3.5 s and 508 to 725 tokens.
- Before ac3.17 the same run failed, and the failure came back as the mapped `GatewayError`
  (`summarizationFailed("Failed to parse generated content.")`).

## Observed

- launchd does not respawn a service within about 10 s of its previous spawn. A reconnect right after an
  unload or kill therefore waits for that interval before the first `hello` is answered. With the harness's
  3 s `pingTimeout` this showed up as `interrupted(unresponsive)` until the supervisor got a separate,
  longer `connectTimeout` (default 30 s) for the handshake.
- `/no_think` breaks the digest prompts on qwen3-0.6b (LocalLLMChat-ac3.17): with it a verdict job generates
  up to the token limit without ever producing response text (16 tokens 0.3 s, 512 tokens 4.7 s, 3000 tokens
  34.2 s, all failing), in-process as well as through the worker. The summarizer therefore leaves thinking
  on and gives a verdict 512 tokens.
- qwen3-0.6b is a weak judge: it called "Bank fraud scandal wipes out pensioners' savings" good news and
  padded a three-item digest to eight points. That is the model, not the pipeline.

## Not verified

- Critical memory pressure, hung-worker kill, the cancel timeout and sleep/wake against the real worker:
  these are covered only by `Tests/WorkerSupervisorTests.swift` with fakes. Owned by LocalLLMChat-ac3.14.
- Verdict time and token use with a larger model (qwen3-4b, which the live smoke test uses, is not cached on
  this machine), and a full Gateway run that ends in a Pages document. Owned by LocalLLMChat-ac3.14.
- The wake notification reaching the Gateway (`NSWorkspace.didWakeNotification` on its main run loop) and
  `SystemMemoryPressureMonitor` inside the Gateway process. Owned by LocalLLMChat-ac3.14.
