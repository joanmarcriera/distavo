# Settings redesign checklist (Vikunja #2957)

Old: one 649-line `Form(.grouped)` in `SettingsView.swift`, fixed 520x640.
New: resizable sidebar window (`NavigationSplitView`), one file per pane in
`apple/Sources/Distavo/Settings/Panes/`, shared `SettingsModel`, pure pane rules
(`SettingsPane`: visibility per edition, search, remembered pane) in
`DistavoCore/SettingsPanes.swift` with tests in `SettingsPanesTests.swift`.

Decisions
- **Save behaviour: explicit Save + Revert kept** (smaller, safer than live-apply: `applyConfig`
  persists, restarts the scan and clears failure markers, so applying on every keystroke would be
  wrong). Closing the window with pending edits still saves them (unchanged); the bar now says
  "Unsaved changes — saved when you close this window" so it is no longer silent.
- **Remembered pane**: `@AppStorage("settings.selectedPane")` (UserDefaults, not a config key).
  Window size/position: AppKit frame autosave `DistavoSettingsWindow`. A stored pane that is not
  visible in this edition falls back to General.
- **Search**: a "Filter settings" field above the sidebar filters panes by title/keywords
  (`SettingsPane.matches`). Keywords must be kept in step with the pane contents.
- **Config keys: none added, renamed or removed.** `Config.swift` is untouched.

## Control map (every control of the old SettingsView)

| # | Old control (section) | Config key / state | New pane | Edition gate |
|---|---|---|---|---|
| 1 | Getting-started blurb (Getting started) | – | General | – |
| 2 | "Watches" folder row | `recordingsDir` (read-only) | General | – |
| 3 | "Writes notes to" row | `notesDir` (read-only) | General | – |
| 4 | "Working files" row | `workDir` (read-only) | General | – |
| 5 | Folders-created / iCloud tip caption | – | General (caption + popover) | – |
| 6 | Watch interval picker | `watchIntervalSeconds` | General | – |
| 7 | Watch folder field + help | `recordingsDir` | General | – |
| 8 | Notes folder field | `notesDir` | General | – |
| 9 | Work folder field | `workDir` | General | – |
| 10 | Note owner field | `noteOwner` | **Notes** (People) | – |
| 11 | Your speaker label field | `userSpeaker` | **Notes** (People) | – |
| 12 | Open at login toggle | `LoginItem` (applied immediately) | General | – |
| 13 | Ask who was in the meeting toggle | `askSpeakersOnStop` | Recording | `MeetingCaptureController.isSupported` (runtime, unchanged) |
| 14 | Suggest stopping after silence + minutes | `suggestStopOnSilence`, `suggestStopSilenceMinutes` | Recording | same runtime gate |
| 15 | Auto-stop after silence + minutes | `autoStopOnSilence`, `autoStopSilenceMinutes` | Recording | same runtime gate |
| 16 | "stops before suggestion" caption | derived | Recording | same runtime gate |
| 17 | Ignore recordings shorter than N s | `minRecordingSeconds` | Recording | – |
| 18 | Shrink recordings once note is written | `compactRecordingsAfterNote` | Recording | – |
| 19 | When done: Open the note | `whenDone` (.openNote) | Recording | – |
| 20 | When done: Open the transcript | `whenDone` (.openTranscript) | Recording | – |
| 21 | When done: Re-transcribe bigger (+ caption) | `whenDone` (.retryTranscribeBigger) | Recording | enabled only if `canRetryTranscribeBigger` (unchanged) |
| 22 | When done: Re-summarise bigger (+ caption) | `whenDone` (.retrySummariseBigger) | Recording | enabled only if `summarise.biggerModel` set |
| 23 | Transcription Engine picker | `transcribe.backend` | Transcription | shown if `HardwareProbe.supportsEmbeddedTranscription`, else caption |
| 24 | Built-in Model picker | `transcribe.embeddedModel` | Transcription | built-in engine only |
| 25 | Automatic-engine blurb | – | Transcription (caption + popover) | built-in + Automatic |
| 26 | Preferred Catalan model picker | `transcribe.preferredCatalanModel` | Transcription | built-in + Automatic + `bscSelectable` |
| 27 | Language packs toggles | `transcribe.languagePacks` | Transcription | built-in + Automatic |
| 28 | Selected-model detail caption | – | Transcription | built-in + fixed model |
| 29 | Benchmark this Mac (`BenchmarkButton`) | `benchmark` results | Transcription (Models) | built-in only |
| 30 | "Not offered on this Mac" caption | derived | Transcription (Models) | built-in only |
| 31 | Download now (`ModelDownloadButton`) | – | Transcription (Models) | built-in only |
| 32 | Models on disk / Remove downloaded models | disk state | Transcription (Models) | built-in only |
| 33 | WhisperX URL + help | `transcribe.whisperxURL` | Transcription | WhisperX engine |
| 34 | WhisperX Model picker | `transcribe.model` | Transcription | WhisperX engine |
| 35 | Language picker (**renamed "Spoken language"**) | `transcribe.language` | Transcription | – (Automatic row built-in only, unchanged) |
| 36 | "Last recording: detected X" | `lastDetectedLanguages` | Transcription | – |
| 37 | Number of speakers stepper | `transcribe.numSpeakers` | Transcription | – |
| 38 | Diarize toggle | `transcribe.diarize` | Transcription | – |
| 39 | Offer on-device summaries toggle | `summarise.embeddedEnabled` | Summaries | macOS 26+ and Apple Intelligence ready (or already on) |
| 40 | Backend picker (+ Built-in row) | `summarise.backend` | Summaries | Built-in row only if `embeddedEnabled` |
| 41 | Summary model picker + download controls | `summarise.embeddedModel` | Summaries (`SummaryModelSettings`) | `embeddedEnabled`; downloadable models Direct only (`SummaryModelEdition`, unchanged) |
| 42 | Gemma / Apple Intelligence status captions | derived | Summaries | `embeddedEnabled` + backend embedded |
| 43 | Server Ollama URL + help | `summarise.server.url` | Summaries | – |
| 44 | Server model | `summarise.server.model` | Summaries | – |
| 45 | Bigger model (optional) | `summarise.biggerModel` | Summaries | – |
| 46 | Prompt picker | `summarise.promptStyle` | **Notes** (Content) | – |
| 47 | Write notes in picker | `summarise.noteLanguage` | **Notes** (Content) | – |
| 48 | Local Ollama URL + help | `summarise.local.url` | Summaries | – |
| 49 | Local model | `summarise.local.model` | Summaries | – |
| 50 | Allow local Ollama fallback | `summarise.allowLocalFallback` | Summaries | – |
| 51 | Connection dots (WhisperX / Server / Local Ollama) | diagnosis | Connections | WhisperX dot hidden when backend is embedded |
| 52 | Test connection | – | Connections | – |
| 53 | Check permissions… (sheet `PermissionsView`) | – | Connections | – |
| 54 | Local Ollama guidance callout | derived | Connections | – |
| 55 | Remote-down caption | derived | Connections | – |
| 56 | Local-network permission warning + Fix permissions… | derived | Connections | – |
| 57 | Automatically check for updates | Sparkle `automaticallyChecksForUpdates` | Updates | **Direct only** |
| 58 | Check for updates now… | Sparkle | Updates | **Direct only** |
| 59 | Bottom bar: Revert / Save / Unsaved / Saved | – | all panes (window chrome) | – |
| 60 | Save-on-close (`onDisappear`) | – | window (`SettingsModel.saveIfNeededOnClose`) | – |
| new | Version line + privacy sentence | – | About | – |
| new | Sidebar filter, remembered pane | UserDefaults | window | – |

Help-text policy: inline blurbs shortened to one-line captions; the full original text moved into
the "?" popover (`.withHelp`) — nothing deleted. Existing popovers (`HelpButton`, `ServerHelpButton`,
`SummaryModelSettings`) are untouched.

Language settings: "Spoken language" (Transcription) and "Write notes in" (Notes) are now clearly
named and each caption points at the other.

## Edition gates, before and after

Before (`git show main:apple/Sources/Distavo/Settings/SettingsView.swift`):
- `SettingsView.swift:18` `#if EDITION_DIRECT` — `autoUpdates` state
- `SettingsView.swift:499` `#if EDITION_DIRECT` — "Updates" Section
- `SettingsView.swift:518` `#if EDITION_DIRECT` — `autoUpdates` read in `onAppear`
- No `DONATE_ENABLED` in the Settings folder.

After (`grep -rn "EDITION_\|DONATE_ENABLED" apple/Sources/Distavo/Settings`):
- `SettingsModel.swift` `#if EDITION_DIRECT` x3 — `autoUpdates` state, `visiblePanes` (Updates only in
  Direct), `windowAppeared` (`autoUpdates` read)
- `SettingsView.swift` `#if EDITION_DIRECT` x1 — the `.updates` case builds `UpdatesPane`
  (non-Direct: `EmptyView`, unreachable because the pane is not listed)
- `Panes/UpdatesPane.swift` `#if EDITION_DIRECT` — whole file
- `SettingsHelp.swift` `#if !EDITION_APPSTORE` x2 — Run in Terminal (unchanged)
- `SummaryModelSettings.swift` `#if EDITION_DIRECT` — downloaded summary models (unchanged)
- `DONATE_ENABLED`: none (donate stays in `Menu/StatusMenu.swift`, unchanged)
- Pane visibility: Direct = General, Recording, Transcription, Notes, Summaries, Connections,
  Updates, About; App Store / Setapp = same minus Updates (tested in `SettingsPanesTests`).
  No pane is empty in any edition.

## Manual checks (a human, per edition build; light AND dark mode)

Not verifiable by the author: the app was never launched. Check each with the window at default
size, then resized to its minimum (700x460) and large; nothing clips and all content scrolls.

- **Window**: resizes; sidebar width adjusts; size/position remembered after closing and reopening;
  reopening shows the last-selected pane; relaunch too. Esc/Cmd-W closes.
- **Sidebar filter**: typing "owner" leaves Notes; "ollama" leaves Summaries; clearing restores all;
  selected pane stays shown if filtered out. No Updates row in App Store/Setapp even for "update".
- **General**: three folder rows readable, middle-truncated; interval picker; three folder fields;
  Open at login toggles immediately; help popovers open.
- **Recording**: meeting-recorder section visible only when capture is supported; silence steppers
  disable with their toggles; "stops before suggestion" caption; when-done toggles and their disabled
  captions point at the right panes (Transcription / Summaries).
- **Transcription**: engine picker (Apple Silicon) / caption (Intel); built-in Model picker, Automatic
  caption + popover, Catalan picker (16 GB Macs), language packs; WhisperX URL/model when engine =
  server; "Spoken language" picker and the cross-reference caption; Models section only for built-in
  (benchmark, download, disk usage, remove).
- **Notes**: Prompt, Write notes in (captions + popovers), Note owner, Your speaker label.
  Edits here and in other panes all show "Unsaved changes" and Save applies them.
- **Summaries**: on-device toggle (macOS 26 only); Backend picker; Built-in row only when enabled;
  summary-model picker + download controls (**Direct only**); Gemma/Apple status caption; Ollama
  server and local sections.
- **Connections**: Test connection dots (WhisperX dot hidden for built-in); amber guidance and LAN
  warning boxes in both appearances (contrast); Check permissions sheet opens.
- **Updates (Direct only)**: both controls work. **Absent** in App Store and Setapp.
- **About**: version/build correct; no donate/support link in any edition.
- **Save bar**: Save/Revert enable only with changes; Revert restores every pane; closing with pending
  edits saves them (activity log "Settings saved on close"); default button (Return) saves.
- **Accessibility**: VoiceOver reads sidebar rows and filter field; Tab reaches every control;
  increased text size does not truncate captions.
- **Edition screenshots**: do not reuse Direct screenshots for App Store/Setapp (Updates pane).
