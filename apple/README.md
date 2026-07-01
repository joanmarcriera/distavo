# Distavo — native macOS app (`apple/`)

The native Swift/SwiftUI rewrite of Distavo, targeting **direct download, Setapp,
and the Mac App Store** from one codebase. This is the only implementation; a
Python reference app previously lived at the repo root (recoverable from git
history) and its behaviour is preserved here, noted in `// Port of …` comments.

## Layout

- `DistavoCore/` — UI-free SwiftPM package (Config, state, transcript cleaning,
  validation, prompt, WhisperX/Ollama clients, AudioConverter, Pipeline). Fully
  unit-tested with `swift test` (no Xcode host, no servers). Dependency-free by
  design — keep it that way.
- `DistavoEmbedded/` — separate SwiftPM package for the **built-in on-device
  transcription engine**: WhisperKit (Whisper CoreML) + SpeakerKit (pyannote
  diarization) from MIT-licensed `argmax-oss-swift` (see `../NOTICES.md`),
  adapted to the WhisperX response shape via `EmbeddedResultMapper`. Apple
  Silicon; models download on first use into
  `~/Library/Application Support/Distavo/models`.
- `Sources/Distavo/` — the app target: `MenuBarExtra` menu, `WatcherController`,
  native Settings window, `Notifier`, `LoginItem`. `AppPipelineDeps.swift`
  routes the pipeline's transcribe step to the embedded engine or the WhisperX
  client per `transcribe.backend`. `Capture/` is the built-in meeting recorder
  (Core Audio process tap + mic, macOS 14.4+, no BlackHole/drivers) — manual
  verification: `../docs/meeting-capture-verification.md`.
- `project.yml` — XcodeGen spec. **`Distavo.xcodeproj` is generated and gitignored.**
- `configs/{Direct,Setapp,AppStore}.xcconfig` — per-edition build settings.
- `Distavo.entitlements` (Direct/Setapp, no sandbox) and
  `Distavo-AppStore.entitlements` (sandbox + security-scoped bookmarks).

## Build & test

```sh
# Generate the Xcode project (REQUIRED after adding/removing source files).
cd apple && xcodegen generate

# Build the app (unsigned, for local dev).
xcodebuild -project Distavo.xcodeproj -scheme Distavo -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

# Run the core unit tests (fast, headless).
cd DistavoCore && swift test

# Run the embedded-engine tests (slower first run: builds WhisperKit).
cd ../DistavoEmbedded && swift test
```

> Source files are referenced explicitly in the generated project, so **re-run
> `xcodegen generate` whenever you add or remove a `.swift` file.**

## Live end-to-end test (LAN only)

`DistavoCore`'s `LiveE2ETests` is skipped unless `DISTAVO_LIVE=1`. It reads
endpoints from the environment (never hardcoded) and exercises the real
convert → transcribe → summarise → validate chain against your own servers:

```sh
DISTAVO_LIVE=1 \
WHISPERX_URL=http://192.168.0.5:9000 \
OLLAMA_URL=http://192.168.0.5:30068 \
OLLAMA_MODEL=qwen2.5:7b-instruct \
DISTAVO_LIVE_AUDIO=/absolute/path/to/sample.m4a \
swift test --filter LiveE2ETests
```

Real transcript content is only ever sent to the WhisperX/Ollama URLs you
configure — there is **no cloud path** in the code by design.

`DistavoEmbedded` has its own gated live test that downloads the real Whisper
`small` model (~460 MB) and transcribes a local file fully on-device:

```sh
cd apple/DistavoEmbedded
DISTAVO_EMBEDDED_LIVE=1 \
DISTAVO_EMBEDDED_LIVE_AUDIO=/absolute/path/to/speech.wav \
DISTAVO_EMBEDDED_LIVE_DIARIZE=1 \
swift test --filter EmbeddedLiveTests
```

## Editions

| Edition | Bundle ID | Sandbox | Donate item | Signing |
|---|---|---|---|---|
| Direct | `uk.co.riera.distavo` | no | yes | Developer ID + notarize |
| Setapp | `uk.co.riera.distavo-setapp` | no | omitted | Developer ID + notarize |
| App Store | `uk.co.riera.distavo` | yes (+ bookmarks) | US-only | Apple Distribution |

Signing/notarization/submission steps: see `../docs/distribution-checklist.md`.
