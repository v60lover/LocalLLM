# Spike: embedded XPC service lookup from a helper-bundle agent (LocalLLMChat-ac3.1)

Run `./build.sh && build/Host.app/Contents/MacOS/Host register` (then `unregister`);
output lands in `/tmp/spike-gateway.log`. Ad-hoc signed, macOS 27 / Xcode 27.0.

## Layout that works

```
Host.app/
  Contents/MacOS/Host
  Contents/Library/LaunchAgents/<label>.plist      # BundleProgram -> helper executable
  Contents/Library/LoginItems/Gateway.app/         # helper .app (own Info.plist, CFBundlePackageType APPL)
    Contents/MacOS/Gateway
    Contents/XPCServices/Worker.xpc/               # CFBundlePackageType XPC!, XPCService.ServiceType=Application
      Contents/MacOS/Worker                        # NSXPCListener.service()
```

Gateway: `NSXPCConnection(serviceName: "<worker CFBundleIdentifier>")`.

## Results

| Case | Result |
|---|---|
| Gateway.app executable run directly | lookup OK, worker replies |
| Same, started by launchd via `launchctl bootstrap` with ProgramArguments = path inside Gateway.app | OK |
| Registered via `SMAppService.agent(plistName:)` from Host.app (BundleProgram) | status `.enabled` (no approval prompt seen with ad-hoc signing), OK |
| Bare executable (not inside any .app) with the same service name | FAIL: `Connection init failed at lookup with error 3 - No such process` |

## Decision

- **Package the Gateway as a helper `.app`** with `Worker.xpc` in its own `Contents/XPCServices/`.
  XPC service lookup is relative to the calling process's main bundle, so a bare `tool`
  binary cannot see the worker, even if it lives inside the UI app bundle.
- Place it at `LocalLLMChat.app/Contents/Library/LoginItems/Gateway.app`; register with
  `SMAppService.agent` (plist in `Contents/Library/LaunchAgents`, `BundleProgram`). The
  current `launchctl bootstrap` installer also works with the helper's executable path, so
  the migration can be done in two steps.
- The agent plist still needs `MachServices` for the UI -> Gateway connection (not
  exercised here; only the Gateway -> Worker hop was).

## Not verified

- Real Developer ID / team signing (ad-hoc was used; SMAppService may require approval in
  System Settings > Login Items for other signing identities).
- Hardened runtime + library validation, sandboxed worker (ac3.11, ac3.15).
- Xcode/xcodegen wiring: Gateway must change from `type: tool` to `application` (with
  LSUIElement) and Worker be an `xpc-service` target embedded in it; the UI target embeds
  Gateway.app into `Contents/Library/LoginItems`.
