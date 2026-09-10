# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Distavo** (v1.11.0) is a **native Swift/SwiftUI macOS menu-bar app** that watches a folder for audio/video
recordings and turns each new one into a structured Markdown meeting note. The pipeline is:
**AVFoundation** (local WAV convert) → transcribe (**built-in WhisperKit (including two Barcelona Supercomputing
Center Catalan/Spanish models) or NVIDIA Parakeet for the "Fast" engine, auto-routed by detected language, or the
user's WhisperX server**, per `transcribe.backend`) → clean → summarise (**Ollama, or Foundation Models if enabled
on macOS 26+**) → validate → write note. All processing is local-first with no cloud path. **macOS 13+** required
(built-in engines need Apple Silicon); Foundation Models engine requires macOS 26+.

> The app ships in three editions from one codebase — **direct download (DMG + Sparkle), Mac App Store (live), and Setapp** — selected by `apple/configs/{Direct,Setapp,AppStore}.xcconfig`. AVFoundation (not ffmpeg, which is GPL) makes App Store distribution possible. See `apple/README.md` and `docs/distribution-checklist.md`.
>
> A Python reference implementation previously lived at the repo root; it was removed once the native app reached parity. Its history (and the `// Port of meeting_pipeline/...` doc-comments in the Swift source) remain the spec — recover it from git if ever needed.

## Commands

Everything lives under `apple/` (requires `brew install xcodegen`):

```sh
cd apple && xcodegen generate            # REQUIRED after adding/removing .swift files
cd apple/DistavoCore && swift test        # fast headless core/parity tests (what CI runs)
cd apple/DistavoCore && swift test --filter PipelineTests   # run one test suite
cd apple && xcodebuild -project Distavo.xcodeproj -scheme Distavo \
  -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
# One scheme/target per edition (Sparkle links into Direct only):
#   Direct    → -scheme Distavo         -configuration Release  -xcconfig configs/Direct.xcconfig
#   App Store → -scheme Distavo-AppStore -configuration Release-AppStore
#   Setapp    → -scheme Distavo-Setapp   -configuration Release
```

`Distavo.xcodeproj` is **generated and gitignored** — regenerate from `apple/project.yml`. There is
**no linter configured**.

## Architecture

The UI-free pipeline logic lives in the **`DistavoCore`** SwiftPM package
(`apple/DistavoCore/Sources/DistavoCore/`), unit-tested without Xcode or servers. The app target
(`apple/Sources/Distavo/`) is the thin SwiftUI/AppKit shell on top. Each core file is a direct port
of the original Python module (noted in its header).

`DistavoCore` module roles:

- **`Pipeline.swift`** — `Pipeline.processOne(path:config:deps:)` orchestrates one recording and
  returns a `ProcessResult(status, base, message, ...)`. Statuses (`ProcessStatus`): `done`,
  `skipped`, `deferredNeedLocal`, `failed`. `Scanner.scanOnce(...)` processes all pending once.
  **Dependency injection:** all external effects (convert/transcribe/summarise/reachability) are
  passed in via `PipelineDeps` (with `.live()` wiring AVFoundation + the HTTP clients), preserving
  the test seam — **do not remove this**.
- **`DistavoState.swift`** — durability model with per-recording marker files (`.processing` /
  `.done` / `.failed`) under `workDir/.state` for idempotency and crash safety. `baseFor()` derives
  a subfolder-aware sanitized base name. `waitUntilStable()` waits for file growth to cease. `iterPending()` lists pending files.
- **`Config.swift`** — JSON config load/save with deep-merge onto defaults; same schema as the original.
  **Path semantics:** `resolvePath()` expands `~`, honors absolute paths, resolves bare-relative values
  under the data base dir (`~/Documents/Distavo`) — never the repo/install dir.
- **`AudioConverter.swift`** — converts input media to WAV with **AVFoundation** (no ffmpeg).
- **`WhisperXClient.swift` / `OllamaClient.swift`** (+ **`HTTPSupport.swift`**) — POST to configured
  WhisperX / Ollama URLs. **`NetworkScope.swift`** classifies endpoints as loopback / private-LAN / public.
- **`EmbeddedSummary.swift`** — dependency-free token budgeting and chunking for Foundation Models.
  Context is 4096 tokens (input + output); long recordings are map-reduced through Prompt.build.
- **`Prompt.swift`** — builds the meeting-notes prompt, kept verbatim in parity with the original.
- **`TranscriptCleaner.swift`** — turns raw WhisperX output into speaker-grouped, timestamp-free transcript.
  **`SummaryValidator.swift`** — post-summary sanity checks (repetition collapse / empty / overlong).
- **`ActivityLog.swift`** — append-only activity log at `~/Library/Logs/Distavo/distavo.log`.
- **`EmbeddedSupport.swift`** — dependency-free pieces: `EmbeddedModelCatalog`, `HardwareProbe`,
  `Config.recommendedForThisMac()`.

The **`DistavoEmbedded`** package (`apple/DistavoEmbedded/`) holds the built-in engines (transcriber + summariser):
- `EmbeddedTranscriber` (WhisperKit + SpeakerKit from `argmax-oss-swift`; per-call lifetime)
- `EmbeddedSummariser` (Apple Foundation Models, macOS 26+, behind `#if canImport(FoundationModels)` + `@available`)
  with `EmbeddedResultMapper` to adapt output to WhisperX `segments` shape — pipeline/cleaner untouched by design
- `EmbeddedModelStore` (WhisperKit models in `~/Library/Application Support/Distavo/models`).
  See `NOTICES.md` for licenses.

App target (`apple/Sources/Distavo/`):
- **`Menu/StatusMenu.swift`** + **`Core/WatcherController.swift`** — `MenuBarExtra` menu (one Button per item)
  wired to the GUI-agnostic controller (timers, locks, status, deferred-set tracking, marker cleanup).
  Timer scans on configured interval; scan is single-flight (non-blocking lock prevents double-process).
- **`Settings/`** — native Settings window (no localhost web server). Backend selection via radio buttons
  (Ollama vs. embedded for both transcribe and summarise, if available on this Mac).
- **`Core/`** — `Links` (outbound URLs including "Send Feedback…" in Direct edition), `LoginItem`,
  `Notifier`, `SandboxFolders` (App Store bookmarks), `AppPipelineDeps` (routes pipeline transcribe/summarise).
- **`Capture/`** — built-in meeting recorder (macOS 14.4+): global Core Audio process tap (excluding Distavo)
  + private aggregate device (L = mic, R = system audio) → stereo WAV. Adapted from insidegui/AudioCap
  (BSD-2, `NOTICES.md`) without its private-TCC probe. App Store safe; TCC needs signed build (CI can't exercise — manual checklist in `docs/meeting-capture-verification.md`).

## Editions

Each edition is its own target (`Distavo` = Direct, `Distavo-AppStore`, `Distavo-Setapp`) sharing the
`DistavoApp` template in `project.yml`; all ship as `Distavo.app` (`PRODUCT_NAME`). **Sparkle links into
Direct only** — the App Store forbids third-party updaters and Setapp ships its own. `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
in each xcconfig selects behavior: `EDITION_DIRECT` (+ `DONATE_ENABLED`), `EDITION_SETAPP`, `EDITION_APPSTORE`.
Keep edition-specific UI gated — the **App Store** build must contain **no Sparkle**, **no Lemon Squeezy donate link**
(Direct-only), **no sandbox-prohibited automation** (the "Run in Terminal" helper is `#if !EDITION_APPSTORE`).

## Key behaviors to preserve

- **A temporarily-absent dependency defers; it never fails.** If Ollama is unreachable and local
  fallback is off, a recording becomes `deferredNeedLocal` (not failed); enabling "Use local Ollama"
  clears deferrals and re-scans. The embedded summariser follows the same rule: `EmbeddedReadiness`
  `.temporarilyUnavailable` (Apple Intelligence still downloading, or switched off) defers, while
  only `.unsupported` (wrong OS / ineligible Mac) fails. `chooseSummariser` returns a
  `SummariserChoice` (`.use`/`.deferred`/`.unavailable`); readiness arrives via the `PipelineDeps`
  seam so DistavoCore stays dependency-free. This matters because `iterPending` skips failed bases
  forever — a wrongly-failed recording is never retried.
- **Foundation Models token budgeting:** the 4096-token context is strict. `EmbeddedSummary.chunkTranscript()`
  partitions input; the reduce step reuses `Prompt.build`, so an on-device note has the same shape as Ollama.
  The feature is a kill switch: with `summarise.embedded_enabled` false, `backend == "embedded"` falls back
  to Ollama (does not fail), and Settings does not offer it.
- **Stale markers at startup:** leftover `.processing` markers mean a prior crash; they're cleared so files
  become pending again. `.failed` markers persist until "Process now" clears them.
- **Backend migration rule:** a config file predating `transcribe.backend` decodes to `"server"` (never
  silently switch existing WhisperX users to embedded); only fresh installs get `"embedded"` via `Config.recommendedForThisMac()`.
- **Concurrency:** scan is self-serializing so overlapping timer ticks and "Process now" can't double-process.

## Runtime data locations (not in the repo)

- Config: `~/Library/Application Support/Distavo/watcher-config.json`
- Work/cache + `.state` markers: `~/Library/Application Support/Distavo/work`
- Default recordings/notes: `~/Documents/Distavo/recordings` and `.../notes`
- Logs: `~/Library/Logs/Distavo/distavo.log`
- WhisperKit models: `~/Library/Application Support/Distavo/models`

Recordings, notes, WAVs, and `watcher-config.json` are gitignored — never commit user data.

## Tests

`swift test` in `apple/DistavoCore`, macOS runner in CI (`.github/workflows/ci.yml`). Tests inject
fakes through the pipeline's `PipelineDeps` seam and use a WhisperX fixture / `MockURLProtocol` for
the HTTP clients. `LiveE2ETests` is skipped unless `DISTAVO_LIVE=1` (see `apple/README.md`). CI also
regenerates the Xcode project and builds the Direct edition unsigned to catch app-target breakage.

## Skills

- **`distavo-native-verify`** — use before committing changes to `apple/DistavoCore`, `apple/DistavoEmbedded`,
  or `apple/Sources/Distavo`. Runs tests, checks compliance gates (Sparkle, donate, sandbox).
- **`distavo-release`** — tagging, version bumps, What's New, and App Store submissions. Complements `mac-appstore-submission-api`.
