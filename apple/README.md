# Seshat — native macOS app (`apple/`)

The native Swift/SwiftUI rewrite of Seshat, targeting **direct download, Setapp,
and the Mac App Store** from one codebase. This is the only implementation; a
Python reference app previously lived at the repo root (recoverable from git
history) and its behaviour is preserved here, noted in `// Port of …` comments.

## Layout

- `SeshatCore/` — UI-free SwiftPM package (Config, state, transcript cleaning,
  validation, prompt, WhisperX/Ollama clients, AudioConverter, Pipeline). Fully
  unit-tested with `swift test` (no Xcode host, no servers).
- `Sources/Seshat/` — the app target: `MenuBarExtra` menu, `WatcherController`,
  native Settings window, `Notifier`, `LoginItem`.
- `project.yml` — XcodeGen spec. **`Seshat.xcodeproj` is generated and gitignored.**
- `configs/{Direct,Setapp,AppStore}.xcconfig` — per-edition build settings.
- `Seshat.entitlements` (Direct/Setapp, no sandbox) and
  `Seshat-AppStore.entitlements` (sandbox + security-scoped bookmarks).

## Build & test

```sh
# Generate the Xcode project (REQUIRED after adding/removing source files).
cd apple && xcodegen generate

# Build the app (unsigned, for local dev).
xcodebuild -project Seshat.xcodeproj -scheme Seshat -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

# Run the core unit tests (fast, headless).
cd SeshatCore && swift test
```

> Source files are referenced explicitly in the generated project, so **re-run
> `xcodegen generate` whenever you add or remove a `.swift` file.**

## Live end-to-end test (LAN only)

`SeshatCore`'s `LiveE2ETests` is skipped unless `SESHAT_LIVE=1`. It reads
endpoints from the environment (never hardcoded) and exercises the real
convert → transcribe → summarise → validate chain against your own servers:

```sh
SESHAT_LIVE=1 \
WHISPERX_URL=http://192.168.0.5:9000 \
OLLAMA_URL=http://192.168.0.5:30068 \
OLLAMA_MODEL=qwen2.5:7b-instruct \
SESHAT_LIVE_AUDIO=/absolute/path/to/sample.m4a \
swift test --filter LiveE2ETests
```

Real transcript content is only ever sent to the WhisperX/Ollama URLs you
configure — there is **no cloud path** in the code by design.

## Editions

| Edition | Bundle ID | Sandbox | Donate item | Signing |
|---|---|---|---|---|
| Direct | `uk.co.riera.seshat` | no | yes | Developer ID + notarize |
| Setapp | `uk.co.riera.seshat-setapp` | no | omitted | Developer ID + notarize |
| App Store | `uk.co.riera.seshat` | yes (+ bookmarks) | US-only | Apple Distribution |

Signing/notarization/submission steps: see `../docs/distribution-checklist.md`.
