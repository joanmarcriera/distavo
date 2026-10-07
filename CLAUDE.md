# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Distavo** (v1.17.0) is a **native Swift/SwiftUI macOS menu-bar app** that watches a folder for audio/video
recordings and turns each new one into a structured Markdown meeting note. The pipeline is:
**AVFoundation** (local WAV convert) → transcribe (**built-in WhisperKit (including two Barcelona Supercomputing
Center Catalan/Spanish models) or NVIDIA Parakeet for the "Fast" engine, auto-routed by detected language, or the
user's WhisperX server**, per `transcribe.backend`) → clean → summarise (**Ollama, or Foundation Models if enabled
on macOS 26+**) → validate → write note. All processing is local-first with no cloud path. **macOS 14+** required (the
`deploymentTarget` in `apple/project.yml`; built-in engines need Apple Silicon, the Catalan models 16 GB); the
Foundation Models summariser is an opt-in preview behind `summarise.embedded_enabled` and requires macOS 26+.

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
- **`Prompt.swift`** — two templates: `classic` (the original port plus four rules sharpened for the on-device model in 1.13; always used by the Foundation Models
  path) and `factsFirst` (bake-off variant D: speakers with evidence, facts ledger, recording metadata; the
  Ollama default since 1.12 via `summarise.prompt_style`). `NoteContext` carries owner/speaker/participants/date/style.
- **`TranscriptCleaner.swift`** — turns raw WhisperX output into speaker-grouped, timestamp-free transcript.
  **`SummaryValidator.swift`** — post-summary sanity checks (repetition collapse / empty / overlong).
- **`SilenceMonitor.swift`** — pure silence policy for the built-in recorder (Vikunja #2665): fed one mic+system RMS sample per second by `MeetingCaptureController`, it emits suggest-stop / auto-stop events (both opt-in via `Config`; auto-stop only after some sound was heard; `keepRecording()` cancels the episode).
- **`ActivityLog.swift`** — append-only activity log at `~/Library/Logs/Distavo/distavo.log`.
- **`EmbeddedSupport.swift`** — dependency-free pieces: `EmbeddedModelCatalog`, `HardwareProbe`,
  `Config.recommendedForThisMac()`.

1.17 feature groups (each file's header comment is the spec; all pure and unit-tested, the app target only renders them):
- **Settings panes** — `SettingsPanes.swift`: which panes exist per edition, sidebar search, remembered selection.
- **Note language** — `NoteLanguage.swift` (`summarise.note_language`: `en` | `auto` | a Whisper code; unknown = `en`).
- **Vocabulary** — `Vocabulary.swift`: `transcribe.vocabulary` (prompt for the engines + summary) and ordered `transcribe.replacements` on the cleaned transcript.
- **Templates + action items** — `SummaryTemplates.swift` swaps only the prompt's section list; `ActionItemsPrompt.swift`
  expresses `summarise.action_items` as a template; `ActionItems.swift` lists/ticks `- [ ]` across notes;
  `RemindersExport.swift` decides what to send (EventKit sink lives in the app target).
- **Regenerate** — `Regenerate.swift` (`Pipeline.regenerate`, `NoteVersions`): re-runs only the summarise step on the cached clean transcript.
- **Timed transcript** — `TranscriptSegments.swift` (`.segments.json`, spec `docs/transcript-sidecar.md`), `TranscriptExport.swift`
  (SRT/VTT/JSON/HTML/DOCX) + `StoredZipWriter.swift` + `TranscriptPDF.swift` (CoreText), `TranscriptTimeline.swift`
  (viewer layout and `TranscriptEditing`; originals kept as `.orig`), `TranscriptMeta.swift`.
- **Speaker rename** — `SpeakerRename.swift`: renames/merges across note, clean transcript and segments.
- **Search and Ask** — `SearchIndex.swift` (system SQLite FTS5 cache, `docs/search.md`); `AskNotes.swift` / `AskPrompt.swift`
  (retrieval, token budget, citations) / `AskEndpoint.swift` (local-only endpoint guard, `docs/ask-local-only.md`).
- **Automation** — `AutomationCommand.swift` (`distavo://` allow-list, Finder Service, App Intents; `docs/automation.md`), `AutomationCopySafety.swift`.
- **Meeting detection** — `MeetingDetector.swift`: offers to record when a listed call app captures the mic (fake-clock policy, like `SilenceMonitor`).
- **Scratchpad, key moments** — `Scratchpad.swift` (typed Quick Notes -> `Prompt.build(scratchpad:)`), `RecordingBookmarks.swift`
  (markers -> deterministic `## Key moments`), `ClipExporter.swift` (AVFoundation m4a clips).
- **Notes window (1.18)** — `NotesLibrary.swift`: one row per note (newest meeting first) with what is on disk for it and, per
  `NoteAction`, whether it can run and the reason when it cannot; title filter, selection retention, `TranscriptBatchExport`
  (several transcripts to a folder). `SettingsDefaults.swift` names what "Default from Settings" resolves to; `OllamaModels.swift`
  lists installed models and compares sizes for the "Bigger model" field. Spec: `docs/notes-window.md`.
- **Queue** — `ProcessingQueue.swift` (view over durable markers, ETAs, `QueueScan`, `QueueRetry`), `QueueCoordinator.swift` (`PausePolicy`, retries).
- **Notes output** — `NotesConfig.swift` (`notes` config section), `NoteFrontmatter.swift`, `NoteMeta.swift` (LLM title/tags),
  `TrackedTerms.swift` (`## Tracked terms`), `VaultExport.swift` (second copy in e.g. an Obsidian vault), `NoteAssembly.swift`.
- **Calendar** — `CalendarMatch.swift` (match, safe titles, attendee cleaning, `moveSidecars`), `CalendarTrust.swift`, `CalendarConfig.swift`;
  EventKit is read-only and opt-in (permission requested from Settings).

The **`DistavoEmbedded`** package (`apple/DistavoEmbedded/`) holds the built-in engines (transcriber + summariser):
- `EmbeddedTranscriber` (WhisperKit + SpeakerKit from `argmax-oss-swift`; per-call lifetime)
- `EmbeddedSummariser` (Apple Foundation Models, macOS 26+, behind `#if canImport(FoundationModels)` + `@available`)
  with `EmbeddedResultMapper` to adapt output to WhisperX `segments` shape — pipeline/cleaner untouched by design
- `EmbeddedModelStore` (WhisperKit models in `~/Library/Application Support/Distavo/models`).
  See `NOTICES.md` for licenses.

App target (`apple/Sources/Distavo/`):
- **`NotesWindow/`** (1.18, `NotesModel`/`NotesView`/`NotesWindowController` + `Core/WatcherController+Notes.swift`) — menu **Notes…**:
  the one place to browse notes and act on the SELECTED one. Regenerate and Rename Speakers are sheets on it (no note chooser of
  their own); Transcript, Compare and Ask stay windows opened for the selection; search is its field (the Search window is gone).
  **A new per-note command goes here as a `NoteAction`, not into the menu.** The folder is not called `Notes/` because
  `.gitignore` ignores `notes/` and the file system is case-insensitive.
- **`Menu/StatusMenu.swift`** + **`Core/WatcherController.swift`** — `MenuBarExtra` menu (one Button per item)
  wired to the GUI-agnostic controller (timers, locks, status, deferred-set tracking, marker cleanup).
  Timer scans on configured interval; scan is single-flight (non-blocking lock prevents double-process).
  Since 1.17 `WatcherController` is split into `WatcherController+{Ask,KeyMoments,Queue,Search,Transcript}.swift`
  extensions (put new controller behaviour in a `+Feature` file, not the main one); the scan loop runs through
  `QueueCoordinator` (`+Queue`), and `isScanning` is the single-flight lock (`runExclusivePass`, and the note-rewriting features, wait on it).
- **`Settings/`** — native Settings window (no localhost web server). Backend selection via radio buttons
  (Ollama vs. embedded for both transcribe and summarise, if available on this Mac). Since 1.17 the window is a
  sidebar of panes: `Settings/Panes/<Name>Pane.swift` (`PaneSupport.swift` shared) with `Panes/Sections/<Name>Section.swift`
  for feature blocks — **one file per pane/section**; a new pane also needs a case in `SettingsPanes.swift` and in `SettingsView.detail`.
- **Feature folders (1.17)** — `Regenerate/`, `Search/`, `Ask/`, `Transcript/` (audio-synced viewer/editor), `Speakers/`
  (rename), `ActionItems/` (+ `EventKitReminderSink`), `Queue/`, `Automation/` (URL scheme, Finder Service, App Intents),
  `Calendar/` (`CalendarEventProvider` = EventKit), plus `Compare/`. New in `Capture/`: `MeetingDetectionController`,
  `QuickNotes`, `KeyMoments` (optional global hotkey).
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

## Per-recording sidecars (work dir)

All live in `workDir` beside the `.state` markers, keyed `<base>.*`, so the (possibly synced) recordings folder stays untouched:
- `.transcript.clean.txt` — cleaned transcript; `Pipeline.processOne` (rewritten by transcript editor / speaker rename). Regenerate and Ask read it.
- `.transcript.meta.json` — detected language for `note_language=auto`; `Pipeline` (`TranscriptMeta`), removed on reprocess when none.
- `.segments.json` — timed transcript; `Pipeline`. `.segments.orig.json`, `.transcript.clean.orig.txt`, `.segments.orig.speakers.json` — pristine copies made before the first transcript-editor save.
- `.speakers.json` — participants/speaker count from the recorder question (`SpeakerHints`).
- `.language.json` — `LanguageOverride`: spoken language `code`, plus `note_language` and `summary_template` for that recording; written by the recorder's confirm controls.
- `.speaker-names.json` — rename mapping (`SpeakerRename`); `.pre-merge-<stamp>` copies of transcript/segments before a merge.
- `.scratchpad.json` (Quick Notes), `.bookmarks.json` (key moments) — recorder.
- `.calendar.json` — the matched event (`CalendarMatch`); `.vault.json` — name + hash of the vault copy (`VaultExport`).
- `reminders-exported.json` — ledger of reminders already sent (one per work dir, not per base; `RemindersLedger`).
- In the **notes** folder: `<note>.prev-<yyyyMMdd-HHmmss>.md` backups (`NoteVersions`, from Regenerate and speaker rename); every scan/listing skips them via `NoteVersions.isBackupName`.
- Search index (not per base): `search-index.sqlite`, created only after "Build the Search Index" is pressed in the Notes window (`search.indexEnabled`).

**Anything that renames a base must move all of them.** `CalendarMatch.moveSidecars` does so by prefix (`<oldBase>.*`, enumerated, copy-then-commit-then-delete) — never add a fixed list.

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
- **Too short is not failed:** a recording under `min_recording_seconds` (default 15) gets a `.tooshort` marker
  (never `.failed`) and is never transcribed; the menu offers to move it to the Bin, "Process now" clears the
  marker. Duration comes through the `audioDurationSeconds` seam in `PipelineDeps`.
- **Speaker hints and compaction after the note:** `<base>.speakers.json` in the work dir (written by the
  recorder's "who was in this meeting?" question, `SpeakerHints`) overrides `num_speakers` for that recording
  and reaches `Prompt.build(participants:)`; without it the prompt is byte-identical to before. Once a note is
  written, a WAV source is atomically replaced by the 16 kHz mono work WAV when `compact_recordings_after_note`
  is on and the copy is under half the size — non-WAV sources are never touched. That key is **off for any
  config predating it** (the original take is gone once compacted) and on only for fresh installs via
  `Config.recommendedForThisMac()` — the same migration rule as `transcribe.backend`.
- **Language packs are opt-in (Vikunja #2124):** `EmbeddedModelCatalog.languagePacks` lists community Whisper
  fine-tunes (Hebrew, Thai, Tamil, Welsh, Norwegian) hosted in Marc's
  `Joanmarcriera/distavo-whisperkit-coreml` repo. `transcribe.language_packs` names the enabled ones; a config
  predating the key decodes to `[]`, so nothing routes differently until the user switches a pack on in Settings.
  The router sends any confident pack language to the pack (never Parakeet) after the unconditional Catalan/
  Spanish rules; pack-only models are hidden from the Model picker until enabled. Every pack source must be
  credited in `NOTICES.md` (`NoticesCoverageTests` enforces it) and converted with `tools/whisperkit-models/convert.sh`.
- **Backend migration rule:** a config file predating `transcribe.backend` decodes to `"server"` (never
  silently switch existing WhisperX users to embedded); only fresh installs get `"embedded"` via `Config.recommendedForThisMac()`.
- **Concurrency:** scan is self-serializing so overlapping timer ticks and "Process now" can't double-process.
- **1.17 options are inert until switched on.** Every new key (`notes.*`, `calendar.*`, vocabulary, templates, `note_language`,
  action items, meeting detection, key-moment hotkey…) decodes to off/empty for a config predating it, and
  `recommendedForThisMac()` leaves them off too unless a comment says otherwise. With them unset `Prompt.build` and the note
  are byte-identical to before (pinned by `PromptTests`/`SummaryTemplateTests`); don't add a prompt line that changes the unset digest.
- **Note section order is fixed** (`NoteAssembly`): frontmatter → model body (incl. Highlights) → `## Key moments` → `## Tracked terms` → provenance footer.
  Key moments and tracked terms are deterministic (no model); the validator runs on the summary before assembly.
- **"Pause watching" holds only automatic work** (`PausePolicy`, `ScanTrigger`): the timer is blocked, explicit user actions
  (Process now, Retry, URL/Shortcuts, Finder Service) run; a pause switched on mid-pass still stops the next file.
- **Ask is local-only by construction.** `AskEndpointGuard.resolve` parses once, resolves once, requires EVERY address to be
  loopback/RFC1918/link-local/ULA, then pins the validated IP (Host header = original); no redirects, no system proxy, no cookies;
  anything unverifiable fails closed. `NetworkScope` now parses hosts strictly (numeric forms via `getaddrinfo`, zone ids, userinfo
  rejected); its classification-only callers use the lenient `hostOf`. https-to-hostname can't be pinned (residual risk in `docs/ask-local-only.md`).
- **Calendar content is untrusted** (`CalendarTrust.isTrusted`: only events the user owns/accepted). Names pass the
  `plausibleName` allow-list and reach the model only in the separate untrusted attendees block, never as authoritative
  participants; the event title is used for the file/note title (sanitised), never put in the prompt. Read-only: nothing writes to a calendar.
- **Features that rewrite the user's note are careful:** speaker rename and regenerate keep a `.prev-` backup and write atomically;
  an action-item tick changes exactly one byte, re-locating the line by content (`.noteChanged` if edited); all run under the scan lock.
- **Automation can't touch files:** `distavo://` commands carry no path and never read/move/delete or change settings; start-recording
  by link always asks (Cancel default). Unknown URLs are ignored and logged.
- **Opt-in by use:** the search index (`search.indexEnabled`, UserDefaults, not Config) and EventKit/Reminders permissions are requested
  only when the user first uses the feature; nothing is indexed or prompted before that. Opening the Notes window is NOT the search
  opt-in (everyone opens it): only the "Build the Search Index" button is.
- **The Notes window never moves the selection.** A refresh (every 3 s, and when a regenerate ends) keeps the selected bases; a new
  note is listed and marked, not selected; the list is ordered by meeting date so a regenerate does not reorder it. Sheets capture
  the note when the button is pressed. This is what stopped regenerates going to the wrong note (manual check 2947.9).
- **A regenerate is visible while it waits:** `regenerateNote` enqueues a `regenerate:<base>` row in `ProcessingQueue` before waiting
  for `isScanning`, and refuses a second one for the same note. A regenerate that cannot run ends "skipped", never "failed".
- **Windows share the activation policy:** close handlers call `AppActivation.windowClosed`, which returns to `.accessory` only when
  no other titled window is open (Notes opens child windows).
- **Tests must not mutate process-global time zone** (`setenv("TZ")`/`NSTimeZone` resets): a cached static `DateFormatter` froze the zone
  and made results depend on test order. Build formatters per call with an injectable `TimeZone`.

## Runtime data locations (not in the repo)

- Config: `~/Library/Application Support/Distavo/watcher-config.json`
- Work/cache + `.state` markers (+ `<base>.speakers.json` sidecars): `~/Library/Application Support/Distavo/work`
- Default recordings/notes: `~/Documents/Distavo/recordings` and `.../notes`
- Logs: `~/Library/Logs/Distavo/distavo.log`
- Search index (a rebuildable FTS5 cache of note + transcript text, #2942, `docs/search.md`): `~/Library/Application Support/Distavo/search-index.sqlite`
- UserDefaults (no Keychain items exist): `search.indexEnabled`, `settings.selectedPane`, the key-moment hotkey error, `summaryModelDownloadOptIn.*`, onboarding/preflight/local-network flags, last detected language, App Store folder bookmarks (`SandboxFolders`). Config-file keys are for behaviour; window state stays here.
- Docs: `docs/notes-window.md`, `automation.md`, `search.md`, `ask-local-only.md`, `transcript-sidecar.md` (sidecar format), `settings-redesign-checklist.md`, `voice-profiles-feasibility.md`, `manual-checks-1.17.md` (what headless tests can't prove: TCC, EventKit, hotkey, detection)
- WhisperKit models: `~/Library/Application Support/Distavo/models`

Recordings, notes, WAVs, and `watcher-config.json` are gitignored — never commit user data.

## Tests

`swift test` in `apple/DistavoCore`, macOS runner in CI (`.github/workflows/ci.yml`). Tests inject
fakes through the pipeline's `PipelineDeps` seam and use a WhisperX fixture / `MockURLProtocol` for
the HTTP clients. `LiveE2ETests` is skipped unless `DISTAVO_LIVE=1` (see `apple/README.md`). CI also
regenerates the Xcode project and builds the Direct edition unsigned to catch app-target breakage.
The suite is ~1100 tests (one file per feature in `Tests/DistavoCoreTests`); anything needing audio, a model, a server or a TCC
permission is gated behind an env var (`DISTAVO_LIVE`, `DISTAVO_EMBEDDED_LIVE`, `DISTAVO_DETECTOR_LIVE`, `DISTAVO_SUMMARY_LIVE`, …) and skips by default,
with the manual remainder listed in `docs/manual-checks-1.17.md`.

## Skills

- **`distavo-native-verify`** — use before committing changes to `apple/DistavoCore`, `apple/DistavoEmbedded`,
  or `apple/Sources/Distavo`. Runs tests, checks compliance gates (Sparkle, donate, sandbox).
- **`distavo-release`** — tagging, version bumps, What's New, and App Store submissions. Complements `mac-appstore-submission-api`.
