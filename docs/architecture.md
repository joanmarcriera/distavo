# Distavo architecture

A condensed map of how Distavo is put together. It adds no new claims: the long form is
[CLAUDE.md](../CLAUDE.md), and each source file's header comment is the spec for that file.

## Pipeline

A native macOS menu-bar app watches a folder and turns each new recording into a Markdown note:
AVFoundation WAV conversion, then transcription (built-in WhisperKit/Parakeet engines, or the user's
WhisperX server), cleaning, summarisation (Ollama, or Foundation Models on macOS 26+ when enabled),
validation, and the note.

- Orchestration: [`Pipeline.swift`](../apple/DistavoCore/Sources/DistavoCore/Pipeline.swift)
  (`Pipeline.processOne`, statuses `done` / `skipped` / `deferredNeedLocal` / `failed`). All external
  effects arrive through `PipelineDeps`, the test seam.
- Conversion: [`AudioConverter.swift`](../apple/DistavoCore/Sources/DistavoCore/AudioConverter.swift) (AVFoundation, no ffmpeg).
- Clients: [`WhisperXClient.swift`](../apple/DistavoCore/Sources/DistavoCore/WhisperXClient.swift),
  [`OllamaClient.swift`](../apple/DistavoCore/Sources/DistavoCore/OllamaClient.swift).
- Prompt and checks: [`Prompt.swift`](../apple/DistavoCore/Sources/DistavoCore/Prompt.swift),
  [`SummaryValidator.swift`](../apple/DistavoCore/Sources/DistavoCore/SummaryValidator.swift),
  [`NoteAssembly.swift`](../apple/DistavoCore/Sources/DistavoCore/NoteAssembly.swift) (fixed section order).
- A temporarily absent dependency defers a recording; it never fails it (see CLAUDE.md, "Key behaviors to preserve").

## Packages

- `DistavoCore`, [`apple/DistavoCore/`](../apple/DistavoCore): UI-free pipeline logic, unit-tested with
  `swift test`, no Xcode or servers needed.
- `DistavoEmbedded`, [`apple/DistavoEmbedded/`](../apple/DistavoEmbedded): the built-in engines
  (WhisperKit transcriber, Foundation Models summariser, model store). Licences: [NOTICES.md](../NOTICES.md).
- App target, [`apple/Sources/Distavo/`](../apple/Sources/Distavo): the thin SwiftUI/AppKit shell
  (menu, Settings panes, Notes window, recorder, automation).
- The Xcode project is generated from [`apple/project.yml`](../apple/project.yml) (`xcodegen generate`) and is gitignored.

## Editions

One codebase, three targets selected by xcconfig files in [`apple/configs/`](../apple/configs):
Direct (`Distavo`, Sparkle links in here only), Mac App Store (`Distavo-AppStore`) and Setapp
(`Distavo-Setapp`). Compile conditions `EDITION_DIRECT`, `EDITION_APPSTORE`, `EDITION_SETAPP` gate
edition-specific UI. The App Store build must contain no Sparkle and no donate link. See
[`apple/README.md`](../apple/README.md) and [`docs/distribution-checklist.md`](distribution-checklist.md).

## Sidecars and durability

State is kept as marker files (`.processing`, `.done`, `.failed`) under the work dir's `.state`, so a
crash leaves files pending and a rerun is idempotent:
[`DistavoState.swift`](../apple/DistavoCore/Sources/DistavoCore/DistavoState.swift). Per-recording
sidecars (clean transcript, timed segments, speakers, language, calendar match and others) live in the
work dir keyed `<base>.*`; their formats are listed in CLAUDE.md, and the timed transcript spec is
[`docs/transcript-sidecar.md`](transcript-sidecar.md). Anything that renames a base must move all of
them, which `CalendarMatch.moveSidecars` does by prefix. Features that rewrite a note keep a `.prev-`
backup and write atomically (see [`docs/notes-window.md`](notes-window.md)).

## Where to add a feature

- Pure logic: a new file in `apple/DistavoCore/Sources/DistavoCore/` with a test file in
  [`apple/DistavoCore/Tests/DistavoCoreTests/`](../apple/DistavoCore/Tests/DistavoCoreTests), one file per feature.
- A per-note command: a `NoteAction` in the Notes window (`apple/Sources/Distavo/NotesWindow/`), not a menu item.
- New controller behaviour: a `WatcherController+Feature.swift` extension, not the main file.
- A Settings option: one file per pane or section under `apple/Sources/Distavo/Settings/Panes/`, plus a case in
  `SettingsPanes.swift` and `SettingsView.detail`. New config keys must decode to off/empty for older configs.
- After adding or removing a `.swift` file run `cd apple && xcodegen generate`; verify with the
  `distavo-native-verify` skill before committing.
