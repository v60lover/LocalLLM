# LocalLLMChat

SwiftUI chat for iPhone and Mac built on [CoreAIKit](https://github.com/john-rocky/coreai-kit). Replies are rendered with [SwiftStreamingMarkdown](https://github.com/microsoft/SwiftStreamingMarkdown), so Markdown is formatted as it streams. The chat model list comes from the [CoreAI Model Zoo](https://github.com/john-rocky/coreai-model-zoo) catalog via `ModelCatalog.load()`. Qwen3 0.6B is selected by default.

The chat stores conversations and the selected model in Application Support. Downloaded weights stay in the CoreAIKit cache; on the next launch the app opens the selected model automatically if it is already on disk. The context indicator shows an approximate number of free tokens: the limit comes from the model's `metadata.json`, usage from the last reply. For models with tool calling, the model picker can also be opened from the chat.

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

A separate background process, `LocalLLMGateway`, collects news from RSS/Atom feeds every day, summarizes it with the selected local model, creates a Pages document and opens it, so the window stays open on the desktop. There are no notifications. The Gateway keeps working when the app is closed. The executable lives inside the app (`Contents/MacOS/LocalLLMGateway`) and is managed by launchd as the per-user agent `com.example.localllmchat.gateway`.

### Setup

1. Open the chat, choose a model and download it. The digest uses the model selected in the chat at the moment you save the settings.
2. Click "Digest…" → "Install and Start". The app writes `~/Library/LaunchAgents/com.example.localllmchat.gateway.plist` and loads the agent (`launchctl bootstrap`). The agent starts at login and restarts after a crash.
3. Set the sources (one URL per line), the time and the output folder (default `~/Documents/LocalLLMChat Digests`), enable the digest and click "Save".
4. Click "Run Now" to verify the whole path without waiting. On the first run macOS asks for permission for `LocalLLMGateway` to control Pages (System Settings → Privacy & Security → Automation); it may also ask for access to the Documents folder.

Log: `~/Library/Logs/LocalLLMChat/gateway.log`. State and schedule live in `~/Library/Application Support/LocalLLMChat/Gateway/state.json`. There are no secrets or tokens.

### Behavior

- **Time zone.** The time and day boundaries are evaluated in the time zone currently set in macOS; it is shown in the settings next to the next run. The schedule is recomputed when the zone changes.
- **One digest per day.** A successful scheduled run is remembered per calendar day: repeated checks and Gateway restarts do not duplicate the document. "Run Now" is an explicit action: it always creates a document and neither counts as the day's run nor consumes retry attempts.
- **Sleep and power-off.** Nothing runs while the Mac sleeps or is off. After waking up the same day, a missed digest is created once (the schedule is checked at least every 30 seconds). Missed past days are not made up.
- **Errors.** After a failure (no network, model not downloaded, no Pages access) the attempt is retried after 10 minutes, at most 3 times a day. Changing the settings resets the counter. The reason for the last error is shown in the settings.
- **Restart.** If the Gateway exits during a run, that attempt is marked as interrupted on startup and retried immediately.
- **Timeout and cancel.** A run is limited to 15 minutes; "Cancel" stops it and terminates the automation process. Each feed: 20 s timeout, at most 2 MB; up to 8 items per source and 24 overall.
- **Login session.** The agent loads only in a graphical session (`LimitLoadToSessionType = Aqua`): the Pages window has to open on the desktop.
- **Signing.** For the Automation permission to stick, the Gateway must be signed by the same team as the app; press "Reinstall" after every rebuild.

### IPC

The app and the Gateway talk over XPC (mach service `com.example.localllmchat.gateway`). A single method carries a JSON envelope with a `version` field (currently 1); requests are `status`, `updateConfig`, `runNow` and `cancelRun`. New job types are added through the `GatewayJob` protocol; scheduling, state and restart handling are provided by `GatewayEngine`.

Verification: `xcodebuild test` covers scheduling (including time zones and daylight saving), restart and deduplication, retries, timeout, cancellation, RSS/Atom feeds with a mocked network, the pipeline with mocked model and Pages, IPC and the installer. An opt-in end-to-end test (`TEST_RUNNER_GATEWAY_LIVE_SMOKE=1`) drives the real launchd agent, cached model and Pages.
