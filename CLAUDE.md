# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Distavo** is a **native Swift/SwiftUI macOS menu-bar app** that watches a folder for audio/video
recordings and turns each new one into a structured Markdown meeting note. The pipeline is:
**AVFoundation** (local WAV convert) → transcribe (**built-in on-device engine** or the user's
**WhisperX** server, per `transcribe.backend`) → clean → **Ollama** server (summarise) → validate →
write note. The built-in engine (WhisperKit + SpeakerKit, Apple Silicon, macOS 14+) is the default
for fresh installs; there is no cloud path either way. macOS 14+ only.

> The app ships in three editions from one codebase — **direct download, Setapp, and the Mac App
> Store** — selected by `apple/configs/{Direct,Setapp,AppStore}.xcconfig`. AVFoundation (not ffmpeg,
> which is GPL) is what makes App Store distribution possible. There is **no cloud path**: real
> transcript content only goes to the user's own WhisperX/Ollama. See `apple/README.md` and
> `docs/distribution-checklist.md`.
>
> A Python reference implementation previously lived at the repo root; it was removed once the
> native app reached parity. Its history (and the `// Port of meeting_pipeline/...` doc-comments in
> the Swift source) remain the spec — recover it from git if ever needed.

## Commands

Everything lives under `apple/` (requires `brew install xcodegen`):

```sh
cd apple && xcodegen generate            # REQUIRED after adding/removing .swift files
cd apple/DistavoCore && swift test        # fast headless core/parity tests (what CI runs)
cd apple/DistavoCore && swift test --filter PipelineTests   # run one test suite
cd apple/DistavoEmbedded && swift test    # embedded-engine tests (slow first run: builds WhisperKit)
cd apple && xcodebuild -project Distavo.xcodeproj -scheme Distavo \
  -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
# build a specific edition: add  -xcconfig configs/{Direct,Setapp,AppStore}.xcconfig
```

`Distavo.xcodeproj` is **generated and gitignored** — regenerate from `apple/project.yml`. There is
**no linter configured**.

## Architecture

The UI-free pipeline logic lives in the **`DistavoCore`** SwiftPM package
(`apple/DistavoCore/Sources/DistavoCore/`), unit-tested without Xcode or servers. The app target
(`apple/Sources/Distavo/`) is the thin SwiftUI/AppKit shell on top. Each core file is a direct port
of the original Python module (noted in its header), so the design notes below still hold.

`DistavoCore` module roles:

- **`Pipeline.swift`** — `Pipeline.processOne(path:config:deps:)` orchestrates one recording and
  returns a `ProcessResult(status, base, message, ...)`. Statuses (`ProcessStatus`): `done`,
  `skipped`, `deferredNeedLocal`, `failed`. `Scanner.scanOnce(...)` processes all pending once.
  **Dependency injection:** all external effects (convert/transcribe/summarise/reachability) are
  passed in via `PipelineDeps` (with `.live()` wiring AVFoundation + the HTTP clients), which is how
  tests run the pipeline without real servers — **preserve this seam when editing.**
- **`DistavoState.swift`** — the durability model. Per-recording **marker files** (`.processing` /
  `.done` / `.failed`) under `workDir/.state` make processing idempotent and crash-safe. `baseFor()`
  derives a subfolder-aware sanitized base name so same-named files in different subfolders don't
  collide. `waitUntilStable()` waits for a file to stop growing before processing. `iterPending()`
  lists files needing work.
- **`Config.swift`** — JSON config load/save with deep-merge onto defaults (so new default keys
  appear for old configs); the same `watcher-config.json` schema as the original. **Path semantics
  matter:** `resolvePath()` expands `~`, honors absolute paths as-is, and resolves *bare-relative*
  values under the data base dir (`~/Documents/Distavo`) — never the repo/install dir.
- **`AudioConverter.swift`** — converts input media to WAV with **AVFoundation** (no ffmpeg).
- **`WhisperXClient.swift` / `OllamaClient.swift`** (+ **`HTTPSupport.swift`**) — POST to the
  configured WhisperX / Ollama URLs.
- **`Prompt.swift`** — builds the meeting-notes prompt, kept verbatim in parity with the original.
- **`TranscriptCleaner.swift`** — turns a raw WhisperX result into a speaker-grouped, timestamp-free
  transcript. **`SummaryValidator.swift`** — post-summary sanity checks (repetition collapse / empty
  / overlong) that flag a note as `failed`.
- **`ActivityLog.swift`** — append-only activity log at `~/Library/Logs/Distavo/distavo.log`, with
  `recent(_:)` to read back recent lines.
- **`NetworkScope.swift`** — classifies a configured endpoint as loopback / private-LAN / public.
  The WhisperX URL is ignored when `transcribe.backend == "embedded"`.
- **`EmbeddedSupport.swift`** — dependency-free pieces of the built-in engine:
  `EmbeddedModelCatalog` (selectable models + download/RAM costs), `HardwareProbe`
  (Apple Silicon / RAM detection), `Config.recommendedForThisMac()` (fresh-install defaults).

The **`DistavoEmbedded`** package (`apple/DistavoEmbedded/`) holds the built-in engine itself so
`DistavoCore` stays dependency-free: `EmbeddedTranscriber` (WhisperKit + SpeakerKit from
MIT-licensed `argmax-oss-swift`; per-call engine lifetime so the menu-bar app holds no model RAM
between meetings), `EmbeddedResultMapper` (adapts output to the WhisperX `segments` shape —
**pipeline/cleaner and their tests are untouched by design**), and `EmbeddedModelStore` (models in
`~/Library/Application Support/Distavo/models`; usage + full cleanup). Licenses: `NOTICES.md`.

App target (`apple/Sources/Distavo/`):

- **`Menu/StatusMenu.swift`** + **`Core/WatcherController.swift`** — the `MenuBarExtra` menu (one
  Button per item) wired to the GUI-agnostic controller (timers, locks, status, deferred-set
  tracking, marker cleanup). A timer scans on the configured interval; the scan is single-flight.
- **`Settings/`** — a **native Settings window** (no localhost web server; that was the Python app).
- **`Core/`** — `Links` (outbound URLs), `LoginItem` (run-at-login via SMAppService), `Notifier`,
  `SandboxFolders` (App Store security-scoped bookmarks), `AppPipelineDeps` (routes the pipeline's
  transcribe step to `EmbeddedTranscriber` or `WhisperXClient` per `transcribe.backend`).

### Editions
`SWIFT_ACTIVE_COMPILATION_CONDITIONS` in each xcconfig selects edition behavior via `#if`:
`EDITION_DIRECT` (+ `DONATE_ENABLED`), `EDITION_SETAPP`, `EDITION_APPSTORE`. Keep edition-specific
UI gated — the **App Store** build must contain **no external-payment link** (the Lemon Squeezy
donate item is `DONATE_ENABLED`/Direct-only) and **no sandbox-prohibited automation** (the "Run in
Terminal" helper is `#if !EDITION_APPSTORE`).

## Key behaviors to preserve

- **Server-offline → local fallback flow:** if the configured Ollama server is unreachable and
  local fallback is off, a recording becomes `deferredNeedLocal` (not failed). Enabling "Use local
  Ollama" clears the deferred set and re-scans. Don't turn deferrals into failures.
- **Concurrency:** the scan is self-serializing (non-blocking lock) so overlapping timer ticks and
  "Process now" can't double-process. Keep scans single-flight.
- **Stale markers:** leftover `.processing` markers at startup mean a prior crash mid-process;
  they're cleared on init so those files become pending again. `.failed` markers persist until
  "Process now" clears them.
- **Backend migration rule:** a config file that predates `transcribe.backend` decodes to
  `"server"` (never silently switch an existing WhisperX user to embedded); only **fresh installs**
  get `"embedded"` via `Config.recommendedForThisMac()`. Don't change either side of this.

## Runtime data locations (not in the repo)

- Config: `~/Library/Application Support/Distavo/watcher-config.json`
- Work/cache + `.state` markers: `~/Library/Application Support/Distavo/work`
- Default recordings/notes: `~/Documents/Distavo/recordings` and `.../notes`
- Logs: `~/Library/Logs/Distavo/distavo.log`

Recordings, notes, WAVs, and `watcher-config.json` are gitignored — never commit user data.

## Tests

`swift test` in `apple/DistavoCore`, macOS runner in CI (`.github/workflows/ci.yml`). Tests inject
fakes through the pipeline's `PipelineDeps` seam and use a WhisperX fixture / `MockURLProtocol` for
the HTTP clients. `LiveE2ETests` is skipped unless `DISTAVO_LIVE=1` (see `apple/README.md`). CI also
regenerates the Xcode project and builds the Direct edition unsigned to catch app-target breakage.
