# LocalLLMChat

SwiftUI chat for iPhone and Mac built on [CoreAIKit](https://github.com/john-rocky/coreai-kit). Replies are rendered with [SwiftStreamingMarkdown](https://github.com/microsoft/SwiftStreamingMarkdown), so Markdown is formatted as it streams. The chat model list comes from the [CoreAI Model Zoo](https://github.com/john-rocky/coreai-model-zoo) catalog via `ModelCatalog.load()`. Qwen3 0.6B is selected by default.

The chat stores conversations and the selected model in Application Support. Downloaded weights stay in the CoreAIKit cache; on the next launch the app opens the selected model automatically if it is already on disk. The context indicator shows an approximate number of free tokens: the limit comes from the model's `metadata.json`, usage from the last reply. For models with tool calling, the model picker can also be opened from the chat.

Robustness: a failed reply leaves the model usable (model state and generation state are separate; the transcript is rolled back and the error is shown with a Dismiss button). When the context fills up, the older half of the conversation is dropped from the model's context (the chat still shows it) and the reply is retried. An unreadable `conversations.json` or Gateway `state.json` is moved aside as `*.corrupt-<timestamp>.json` instead of being overwritten.

## Running

Requires Xcode 27, macOS 27 or a physical iPhone with iOS 27. Core AI is not available in the iOS Simulator SDK.

```sh
cd LocalLLMChat
xcodegen generate
open LocalLLMChat.xcodeproj
```

Select `My Mac` or a physical iPhone. For iPhone, set your development team in Signing & Capabilities. Launch the app, tap "Download" and wait for the model to download. Qwen3 0.6B needs about 352 MB on Mac or 456 MB on iPhone and at least 1 GB of free space. The model is kept in the CoreAIKit cache. The first download needs internet; messages are processed locally.

The Xcode scheme runs the Release configuration: generation in Debug is noticeably slower. Choosing another model creates or opens a conversation for it and keeps earlier conversations. "New Chat" starts a separate conversation with the current model.

## Daily news digest (Gateway, Mac only)

A separate background process, `LocalLLMGateway`, collects news from RSS/Atom feeds every day, lets the selected local model pick out only the good news (one GOOD/OTHER verdict per item) and summarize it, creates a Pages document and opens it, so the window stays open on the desktop. There are no notifications. The Gateway keeps working when the app is closed. The executable lives inside the app (`Contents/MacOS/LocalLLMGateway`) and is managed by launchd as the per-user agent `com.example.localllmchat.gateway`.

### Setup

1. Open the chat, choose a model and download it. The digest uses the model currently selected in the chat; the Gateway follows when you switch models.
2. Click "Digest…" → "Install and Start". The app writes `~/Library/LaunchAgents/com.example.localllmchat.gateway.plist` and loads the agent (`launchctl bootstrap`). The agent starts at login and restarts after a crash.
3. Set the sources (one URL per line), the time and the output folder (default `~/Documents/LocalLLMChat Digests`), enable the digest. Changes are saved automatically; the Run section shows "Saved", "Saving…" or "Not saved: <reason>" (for example for an unfinished URL).
4. Click "Run Now" to verify the whole path without waiting. On the first run macOS asks for permission for `LocalLLMGateway` to control Pages (System Settings → Privacy & Security → Automation); it may also ask for access to the Documents folder.

Log: `~/Library/Logs/LocalLLMChat/gateway.log`. State and schedule live in `~/Library/Application Support/LocalLLMChat/Gateway/state.json`. There are no secrets or tokens.

### Behavior

- **Time zone.** The time and day boundaries are evaluated in the time zone currently set in macOS; it is shown in the settings next to the next run. The schedule is recomputed when the zone changes.
- **One digest per day.** A successful scheduled run is remembered per calendar day: repeated checks and Gateway restarts do not duplicate the document. "Run Now" is an explicit action: it always creates a document and neither counts as the day's run nor consumes retry attempts. Exception: if you move the time to a moment that is still ahead today, the day is re-armed and a digest is created at the new time.
- **Sleep and power-off.** Nothing runs while the Mac sleeps or is off. After waking up the same day, a missed digest is created once (the schedule is checked at least every 30 seconds). Missed past days are not made up.
- **Errors.** After a failure (no network, model not downloaded, no Pages access) the attempt is retried after 10 minutes, at most 3 times a day. Changing the settings resets the counter. The reason for the last error is shown in the settings.
- **Restart.** If the Gateway exits during a run, that attempt is marked as interrupted on startup and retried immediately.
- **Timeout and cancel.** A run is limited to 15 minutes; "Cancel" stops it and terminates the automation process. Each feed: 20 s timeout, at most 2 MB; up to 8 items per source and 24 overall.
- **Login session.** The agent loads only in a graphical session (`LimitLoadToSessionType = Aqua`): the Pages window has to open on the desktop.
- **Signing.** For the Automation permission to stick, the Gateway must be signed by the same team as the app; press "Reinstall" after every rebuild.

### Architecture

#### Processes

- **App (`LocalLLMChat`)**: the chat and the "Digest…" settings screen. It does not schedule or run anything itself.
- **`LocalLLMGateway`**: a separate executable embedded in the app (`Contents/MacOS/LocalLLMGateway`).
  - launchd starts it as the per-user agent `com.example.localllmchat.gateway` (`RunAtLoad`, `KeepAlive`, graphical session only).
  - It runs independently of the chat window.
  - `GatewayInstaller` installs and removes it (writes the plist, then `launchctl bootstrap` / `bootout`).

#### IPC

The app and the Gateway talk over XPC (mach service `com.example.localllmchat.gateway`). A single method, `send(Data, reply:)`, carries a JSON envelope with a protocol `version` (currently 1), so the wire format can evolve without changing the Objective-C protocol.

Requests: `status`, `updateConfig`, `runNow`, `cancelRun`. Every reply is either the current `GatewayStatus` or an error message. `runNow` returns immediately; the app polls the status every 2 seconds to follow progress.

#### Layers inside the Gateway

```
GatewayMain                      XPC listener + scheduler loop
 └─ GatewayRequestHandler        decodes the envelope, checks the protocol version
     └─ GatewayEngine (actor)    schedule, state, exactly one active run
         ├─ DigestSchedule       pure policy: when is a run due?
         ├─ GatewayStateStore    state.json (config, daily progress, last run)
         └─ GatewayJob           protocol; the extension point for new job types
             └─ NewsDigestJob    news -> model -> document
                 ├─ NewsFetching         URLSession + RSS/Atom parsing
                 ├─ DigestSummarizing    local CoreAIKit model
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

The clock (`GatewayClock`), news fetching, summarization, document publishing and launchd command execution all sit behind protocols. Scheduling, restart, deduplication and retries can therefore be tested deterministically, without a network, a model or Pages.

#### Limitations

- The Gateway runs in the user session, not as a system daemon, because the Pages window has to open on the desktop. Nothing runs while you are logged out.
- The Automation permission for Pages is tied to the Gateway's code signature. If the signature changes, the permission has to be granted again.
- The XPC listener does not verify the client's code signature. The service is only reachable inside the user's own launchd domain; add a code-signing requirement if stricter checking is needed.

Verification: `xcodebuild test` covers scheduling (including time zones and daylight saving), restart and deduplication, retries, timeout, cancellation, RSS/Atom feeds with a mocked network, the pipeline with mocked model and Pages, IPC and the installer. An opt-in end-to-end test (`TEST_RUNNER_GATEWAY_LIVE_SMOKE=1`) drives the real launchd agent, cached model and Pages.
