# LocalLLMChat

SwiftUI chat for Mac built on [CoreAIKit](https://github.com/john-rocky/coreai-kit). Replies are rendered with [SwiftStreamingMarkdown](https://github.com/microsoft/SwiftStreamingMarkdown), so Markdown is formatted as it streams. The chat model list comes from the [CoreAI Model Zoo](https://github.com/john-rocky/coreai-model-zoo) catalog via `ModelCatalog.load()`. Qwen3 0.6B is selected by default.

The chat stores conversations and the selected model in Application Support. Downloaded weights stay in the CoreAIKit cache; on the next launch the app opens the selected model automatically if it is already on disk. The context indicator shows an approximate number of free tokens: the limit comes from the model's `metadata.json`, usage from the last reply. The model runs in the Gateway's worker, which has no tools yet, so the model cannot open the picker from the chat.

Robustness: a failed reply leaves the model usable (model state and generation state are separate; the transcript is rolled back and the error is shown with a Dismiss button). When the context fills up, the older half of the conversation is dropped from the model's context (the chat still shows it) and the reply is retried. An unreadable `conversations.json` or Gateway `state.json` is moved aside as `*.corrupt-<timestamp>.json` instead of being overwritten.

## Running

Requires Xcode 27 and macOS 27.

```sh
cd LocalLLMChat
xcodegen generate
open LocalLLMChat.xcodeproj
```

Select `My Mac`. Launch the app, tap "Download" and wait for the model to download. Qwen3 0.6B needs about 352 MB and at least 1 GB of free space. The model is kept in the CoreAIKit cache. The first download needs internet; messages are processed locally.

The Xcode scheme runs the Release configuration: generation in Debug is noticeably slower. Choosing another model creates or opens a conversation for it and keeps earlier conversations. "New Chat" starts a separate conversation with the current model.

## Daily news digest (Gateway, Mac only)

A separate background process, `LocalLLMGateway`, collects news from RSS/Atom feeds every day, lets the selected local model pick out only the good news (one GOOD/OTHER verdict per item) and summarize it, creates a Pages document and opens it, so the window stays open on the desktop. There are no notifications. The Gateway keeps working when the app is closed. It is a helper app inside the app (`Contents/Library/LoginItems/LocalLLMGateway.app`) and is managed by launchd as the per-user agent `com.example.localllmchat.gateway`.

### Setup

1. Open the chat, choose a model and download it. The digest uses the model currently selected in the chat; the Gateway follows when you switch models.
2. Click "Digest…" → "Install and Start". The app registers the agent with `SMAppService`; macOS may ask you to allow it in System Settings → General → Login Items & Extensions. The agent starts at login and restarts after a crash.
3. Set the sources (one URL per line), the time and the output folder (default `~/Documents/LocalLLMChat Digests`), enable the digest. Changes are saved automatically; the Run section shows "Saved", "Saving…" or "Not saved: <reason>" (for example for an unfinished URL).
4. Click "Run Now" to verify the whole path without waiting. On the first run macOS asks for permission for `LocalLLMGateway` to control Pages (System Settings → Privacy & Security → Automation); it may also ask for access to the Documents folder.

Log: unified logging, subsystem `com.example.localllmchat.gateway` (`log stream --predicate 'subsystem == "com.example.localllmchat.gateway"'`). State and schedule live in `~/Library/Application Support/LocalLLMChat/Gateway/state.json`. There are no secrets or tokens.

### Behavior

- **Time zone.** The time and day boundaries are evaluated in the time zone currently set in macOS; it is shown in the settings next to the next run. The schedule is recomputed when the zone changes.
- **One digest per day.** A successful scheduled run is remembered per calendar day: repeated checks and Gateway restarts do not duplicate the document. "Run Now" is an explicit action: it always creates a document and neither counts as the day's run nor consumes retry attempts. Exception: if you move the time to a moment that is still ahead today, the day is re-armed and a digest is created at the new time.
- **Sleep and power-off.** Nothing runs while the Mac sleeps or is off. After waking up the same day, a missed digest is created once (the schedule is checked at least every 30 seconds). Missed past days are not made up.
- **Errors.** After a failure (no network, model not downloaded, no Pages access) the attempt is retried after 10 minutes, at most 3 times a day. Changing the settings resets the counter. The reason for the last error is shown in the settings.
- **Restart.** If the Gateway exits during a run, that attempt is marked as interrupted on startup and retried immediately.
- **Timeout and cancel.** A run is limited to 15 minutes; "Cancel" stops it and terminates the automation process. Each feed: 20 s timeout, at most 2 MB; up to 8 items per source and 24 overall.
- **Model residency.** The model lives in the worker process, not in the Gateway. It is loaded on the first verdict of a run and stays warm for 10 minutes after the last job (a "Run Now" within that time reuses it; a retry comes later and loads it again), then the worker is unloaded and killed. Critical memory pressure fails a running digest instead of finishing it; the attempt is then retried like any other failure. A worker crash is retried once on a fresh worker; a second crash on the same step fails the run, which is then retried like any other failure, so a worker that keeps crashing costs at most the day's 3 attempts. Three crashes in a row stop the worker (safe mode) until the next run, which starts with a clean counter.
- **Login session.** The agent loads only in a graphical session (`LimitLoadToSessionType = Aqua`): the Pages window has to open on the desktop.
- **Signing.** For the Automation permission to stick, the Gateway must be signed by the same team as the app; press "Reinstall" after every rebuild.

### Architecture

#### Processes

- **App (`LocalLLMChat`)**: the chat and the "Digest…" settings screen. It does not schedule or run anything itself. On macOS the chat does not load the model either: replies are generated by the worker behind the Gateway (see "Chat over the Gateway"); the app keeps the catalog, downloads and `conversations.json`.
- **`LocalLLMGateway`**: a helper app embedded in the app (`Contents/Library/LoginItems/LocalLLMGateway.app`, `LSUIElement`). It must be an app bundle, not a bare executable, because the inference worker (`LocalLLMWorker.xpc` in its `Contents/XPCServices`) can only be looked up from inside a bundle.
  - launchd starts it as the per-user agent `com.example.localllmchat.gateway` (`RunAtLoad`, `KeepAlive`, graphical session only).
  - It runs independently of the chat window.
  - It owns the worker's lifecycle (`WorkerSupervisor`): start, keep warm, unload when idle or on memory pressure, restart its timers after wake, restart after a crash.
  - `GatewayInstaller` installs and removes it via `SMAppService.agent`; the launchd plist ships in `Contents/Library/LaunchAgents` and points at the helper with `BundleProgram`. A plist written by older builds into `~/Library/LaunchAgents` is removed on install.

- **Worker (`LocalLLMWorker.xpc`)**: an XPC service inside the Gateway bundle. It loads a model from a local path and runs generations. It has no network, no schedule and no state of its own; it exits when the Gateway's connection ends.

#### IPC

The app and the Gateway talk over XPC (mach service `com.example.localllmchat.gateway`), protocol version 3. A single method, `send(Data, reply:)`, carries a JSON envelope `{version, requestID, request}`, so the wire format can evolve without changing the Objective-C protocol. The app also exports a second object, `GatewayEventSinkXPC`, on the same connection, through which the Gateway pushes events.

- **Handshake.** The first request on a connection is `hello(version)`; the reply carries the Gateway's version and an `instanceID` (one per Gateway process). Anything sent before `hello` is answered with `handshakeRequired`. A peer on another protocol version gets a typed `unsupportedProtocol` failure (a protocol 1 app receives it in the shape it reads, so it shows "Reinstall the Gateway from the app"); there is no dual-stack support.
- **Requests:** `hello`, `status`, `updateConfig`, `runNow`, `cancelRun`, `ping`, `requestStatus(id)`. Every reply is a typed value: the status, `pong`, the request's state, or `failure(kind, message)`.
- **Request IDs.** A mutating request (`updateConfig`, `runNow`, `cancelRun`, `chatGenerate`, `chatCancel`) is executed at most once per `requestID`: the Gateway keeps the last 128 outcomes in memory, answers a duplicate with the stored reply and `requestStatus` with `completed`, `inProgress` or `unknown`. After a lost connection the client reconnects and looks the outcome up; it never re-sends a mutating request. If the Gateway process changed in between (or the entry was evicted), the call fails with "connection lost" and the UI shows the fresh status.
- **Push.** The Gateway pushes its full status after every change (config saved, run started, run finished, and a field that moved with the clock alone: time zone, next run, the day's attempt count; that last kind is noticed within 30 s) in batches with a strictly increasing `sequence`. Publishes never overlap, so the last status pushed is the newest. The status carries a `revision` that grows with every change; replies and pushes travel separately, and the app drops a status older than the one it already shows. Only the latest status is kept per subscriber and one batch is in flight until acknowledged; an app that does not acknowledge within 10 s is dropped. A gap in the sequence or an undecodable batch makes the app reconnect (status is a snapshot, so that repairs it). Unknown event types are skipped, so the event set can grow.
- **Liveness.** The app keeps one connection, pings every 5 s (5 s timeout), and on a hung or interrupted Gateway closes the connection and reconnects: the first attempt follows within 5 s, further ones every 2 s. Requests time out after 10 s; cancelling the caller does not interrupt a request already sent. There is no polling of the status. The client lives as long as the settings window: closing it sends a pending edit, then closes the connection for good.

`GatewayStatus.worker` carries the worker's state (`idle`, `starting`, `ready`, `restarting`, `safeMode`); it is optional, so builds on either side that do not know it still talk to each other. It is refreshed with every reply and push, but a change of the worker state alone does not trigger a push.

The Gateway and the worker use a second, separately versioned contract (`WorkerIPC.swift`, protocol version 1): one `send(Data, reply:)` method for requests, and a client-exported event sink through which the worker streams output in coalesced batches, one batch in flight until acknowledged.

#### Chat over the Gateway

Every chat reply is generated by the worker, through the Gateway; there is no in-process fallback. The Gateway must be installed and approved in Login Items before the first message; after every rebuild press "Reinstall" (protocol 3, an older peer is refused with `unsupportedProtocol`).

- **Requests.** `chatGenerate` (model reference, prompt, instructions for a new conversation or the encoded transcript to continue from, token limit) is answered with `accepted` at once; the request's ID is the generation ID. `chatCancel(target)` stops it. A generation is never one request/reply, because requests time out after 10 s.
- **Events.** `chatDelta` (text appended since the previous delta), then exactly one of `chatFinished` (the new transcript and token count) or `chatFailed` (typed kind; `cancelled` is a stop, not an error). They go only to the connection that asked, in order, on a lane next to the status snapshot; consecutive deltas are merged while a batch is in flight.
- **No conversation on the Gateway.** The worker session lives for one reply, so each reply carries the whole transcript and returns the new one. The app stays the owner of conversations.
- **Lost output is not repaired.** A sequence gap or an undecodable batch fails the reply in flight and the client reconnects; the app rolls the conversation back to before that reply and shows an error.
- **A closed connection cancels its generations**, so a vanished app does not leave the model running. The Gateway keeps no chat state across a restart.
- **Limits.** A reply queues behind a running digest verdict (one job at a time, FIFO), with no "queued" indication. Stop keeps the text shown but not the cut-off turn in the model's context. The model cannot call tools. A Gateway that is not installed shows as a model error with the Gateway's own message, not a dedicated state.

#### Layers inside the Gateway

```
GatewayMain                      XPC listener + scheduler loop + main run loop (wake)
 ├─ GatewayEventPublisher (actor) pushes the status to subscribed connections, one batch in flight
 └─ GatewayRequestHandler        handshake, protocol version, request-ID ledger; per-connection state
     └─ GatewayEngine (actor)    schedule, state, exactly one active run
         ├─ DigestSchedule       pure policy: when is a run due?
         ├─ GatewayStateStore    state.json (config, daily progress, last run)
         └─ GatewayJob           protocol; the extension point for new job types
             └─ NewsDigestJob    news -> model -> document
                 ├─ NewsFetching         URLSession + RSS/Atom parsing
                 ├─ DigestSummarizing    WorkerDigestSummarizer: prompts and verdicts here,
                 │                       generation through WorkerSupervisor -> LocalLLMWorker.xpc
                 └─ DocumentPublishing   Pages via osascript
```

- **`GatewayEngine`** is the central actor.
  - It owns the state and the single in-flight run; starting a second run while one is active is rejected.
  - On every scheduler tick (at least every 30 seconds) it asks `DigestSchedule.decide` whether a run is due and starts one if so.
  - Each run is wrapped in a timeout (15 minutes) and can be cancelled with `cancelRun`.
- **`DigestSchedule`** is a pure function of the current time, the config and the daily progress. It has no side effects, which is why it is easy to test. Its policy:
  - one successful scheduled run per calendar day;
  - a missed run is made up once, the same day; past days are never back-filled;
  - after a failure, up to 3 retries per day, 10 minutes apart;
  - day boundaries use the time zone currently set in macOS.
- **State** lives in `~/Library/Application Support/LocalLLMChat/Gateway/state.json`. An `inFlight` record is written before a run starts. If the process dies mid-run, the next start marks that run as interrupted and retries it immediately.
- **`GatewayJob`** is the extension point. There is only one job today (`NewsDigestJob`), but the engine only knows the protocol, so new job types can be added without touching the scheduler.

#### What is injectable in tests

The clock (`GatewayClock`), the app's connection to the Gateway (`GatewayConnecting` / `GatewayLink`), event delivery (`GatewayEventSending`), news fetching, summarization (the worker behind `DigestWorkerRunning`, the model cache behind `ModelLocating`), document publishing and launchd command execution all sit behind protocols. Scheduling, restart, deduplication and retries can therefore be tested deterministically, without a network, a model or Pages.

#### Limitations

- The Gateway runs in the user session, not as a system daemon, because the Pages window has to open on the desktop. Nothing runs while you are logged out.
- The Automation permission for Pages is tied to the Gateway's code signature. If the signature changes, the permission has to be granted again.
- Neither XPC peer is authenticated: the Gateway's listener does not verify the app's code signature, and the worker does not verify the Gateway's. The service is only reachable inside the user's own launchd domain; add a code-signing requirement if stricter checking is needed.

Verification: `xcodebuild test` covers scheduling (including time zones and daylight saving), restart and deduplication, retries, timeout, cancellation, RSS/Atom feeds with a mocked network, the pipeline with mocked model and Pages, the app<->Gateway protocol (handshake, version skew, request IDs, push backpressure, heartbeat, reconnect), chat generation (ordering, cancellation, connection ownership, error mapping, the app-side runtime on a fake Gateway) and the installer. An opt-in end-to-end test (`TEST_RUNNER_GATEWAY_LIVE_SMOKE=1`) drives the real launchd agent, cached model and Pages. Not live-verified: push events and reconnect across a real launchd restart, and a chat reply through the real XPC with a real model (covered with fakes and an in-process loopback Gateway only; the chat path is checked by hand).
