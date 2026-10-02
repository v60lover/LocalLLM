# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->


## Build & Test

The Xcode project is generated from `project.yml` (`*.xcodeproj` is gitignored).

```bash
xcodegen generate
xcodebuild test -scheme LocalLLMChat -destination 'platform=macOS' \
  DEVELOPMENT_TEAM=<your team id> -only-testing:LocalLLMChatTests
```

## Architecture Overview

- `Sources/ChatStore.swift` — chat state (`ModelState` and `GenerationState` are separate); talks to the model layer only through `ChatBackend` / `ChatModelHandle` / `ChatRuntime` (`Sources/ChatBackend.swift`), so tests use fakes.
- `Sources/AgentRuntime.swift` — CoreAIKit/FoundationModels session; `TranscriptTrimmer` drops old turns on context overflow.
- `Sources/ConversationStore.swift` — persistence; unreadable files are quarantined (`Sources/Shared/FileQuarantine.swift`).
- `Sources/Gateway/` + `Gateway/` — macOS background digest process; see README "Architecture".

## Conventions & Patterns

- Everything time- or I/O-dependent sits behind a protocol and is faked in `Tests/`.
- Never overwrite a file that failed to decode; move it aside first.
