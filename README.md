# LocalLLMChat

SwiftUI chat for Mac built on [CoreAIKit](https://github.com/john-rocky/coreai-kit): local models from the [CoreAI Model Zoo](https://github.com/john-rocky/coreai-model-zoo), streaming Markdown replies. A background Gateway process also builds a daily good-news digest into a Pages document.

## Running

Requires Xcode 27 and macOS 27.

```sh
xcodegen generate
open LocalLLMChat.xcodeproj
```

Select `My Mac`, launch, press "Download" (Qwen3 0.6B, ~352 MB). Messages are processed locally; only the first download needs internet.

## Daily digest

"Digest…" → "Install and Start" registers the Gateway agent; then set sources, time and output folder, and press "Run Now" to check. Log: `log stream --predicate 'subsystem == "com.example.localllmchat.gateway"'`.

## Architecture

Processes, IPC protocol, chat over the Gateway, scheduling, tests and limitations: [docs/architecture/index.html](docs/architecture/index.html).
