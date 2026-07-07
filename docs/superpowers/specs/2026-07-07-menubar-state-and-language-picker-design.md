# Spec A — Menu-bar state indicator + language dropdown

Date: 2026-07-07
Status: approved (design), ready to implement
Slice: A of 2 (self-contained in-app UI; ships first, own version bump)

## Goal

Two user-requested improvements to the Distavo menu-bar app:

1. **Menu-bar icon reflects state** — the glyph shows which of five states the app is in:
   `idle`, `recording`, `loading`, `transcribing`, `done` (a note is ready but not yet opened).
2. **Language is a dropdown**, not free text — eliminating typos like `esp` for `es`, and offering
   Auto-detect plus the full Whisper language set.

No pipeline behaviour changes, no servers, no secrets, no CI/release-pipeline impact. Everything here
is locally testable (`swift test`) and buildable unsigned.

## Feature 1 — Menu-bar state indicator

### State model

Replace `WatcherController.Activity` (`idle`/`processing`/`done`) with a five-case icon state:

```swift
enum IconState { case idle, recording, loading, transcribing, done }
```

Computed in `refreshActivity()` with this **precedence** (highest first):

1. `recording` — `capture.isRecording == true`. A live recording is the most important signal, even
   if a previously-dropped file is still being processed.
2. `loading` / `transcribing` — while a scan is processing, from the current pipeline phase.
3. `done` — `unseenDone == true` (note ready, not yet opened; cleared by `acknowledgeNote()`).
4. `idle`.

### How the phase is known (works for BOTH backends)

The WhisperX **server** path is one opaque HTTP call with no internal progress, so the loading↔
transcribing distinction must come from the pipeline orchestration, not from inside the transcriber.
Two layers:

**Layer 1 — pipeline phase callback (both backends).** Add an optional, `@Sendable` phase callback to
`PipelineDeps` and fire it at the existing stage boundaries in `Pipeline.processOne`:

```swift
public enum ProcessingPhase: String, Equatable, Sendable {
    case converting     // before deps.convertToWav
    case transcribing   // before deps.transcribe
    case summarising    // before deps.summarise
}

// added to PipelineDeps:
public var onPhase: (@Sendable (ProcessingPhase) -> Void)?
```

- `onPhase` defaults to `nil` → **existing tests and the DI seam are untouched.** Wiring it is
  additive.
- `Pipeline.processOne` calls `deps.onPhase?(.converting)` immediately before `convertToWav`,
  `.transcribing` before `transcribe`, `.summarising` before `summarise`.
- Mapping in the app: `converting → .loading`; `transcribing`/`summarising → .transcribing`
  (summarising folded into the transcribing icon, per approved design).

**Layer 2 — embedded refinement (embedded backend only).** The existing `wireEmbeddedProgress`
handler already receives `"Downloading …"`, `"Loading …"`, `"Transcribing …"`, `"Identifying …"`.
Extend it to ALSO set the icon phase: messages containing `Download`/`Loading` → `.loading`;
`Transcribing`/`Identifying` → `.transcribing`. This gives the on-device path a genuine "loading the
model" phase that the server path structurally cannot have.

### Observing the recorder

`MeetingCaptureController.isRecording` is `@Published` on a **separate** `ObservableObject`.
`WatcherController` owns `capture` (lazy). Subscribe to `capture.$isRecording` (Combine sink, held in
a cancellable) and call `refreshActivity()` on change so the icon flips immediately when recording
starts/stops. `DistavoApp` passes `controller.iconState` (renamed from `controller.activity`) to
`MenuBarLabel`.

### Rendering (`MenuBarLabel`)

Distinct SF Symbol **plus** accent colour per state (distinct symbols, not colour alone, fix the
current colour-only accessibility gap). Final symbol names verified against macOS 14 availability
during implementation; defaults:

| State        | Symbol (default)                         | Tint             |
|--------------|------------------------------------------|------------------|
| idle         | `waveform`                               | template (none)  |
| recording    | `record.circle`                          | red              |
| loading      | `waveform.badge.ellipsis` → else `hourglass` | secondary/blue |
| transcribing | `waveform`                               | amber            |
| done         | `waveform.badge.checkmark` → else `checkmark.circle.fill` | green |

No animation (YAGNI; pulsing can be added later). Keep the tiny-glyph footprint of the current design.

### Files touched

- `apple/DistavoCore/Sources/DistavoCore/Pipeline.swift` — add `ProcessingPhase`, `onPhase` field +
  the three `onPhase?(…)` calls. Keep `PipelineDeps.init` back-compatible (new param defaults `nil`).
- `apple/Sources/Distavo/Core/WatcherController.swift` — `IconState`, `refreshActivity()` precedence,
  `capture.$isRecording` subscription, feed `onPhase` into the app's `PipelineDeps`, extend
  `wireEmbeddedProgress`.
- `apple/Sources/Distavo/Core/AppPipelineDeps.swift` — thread the `onPhase` callback through.
- `apple/Sources/Distavo/Menu/MenuBarLabel.swift` — five-state rendering.
- `apple/Sources/Distavo/DistavoApp.swift` — pass `iconState`.

### Tests (DistavoCore, fast suite)

- `processOne` emits phases in order `converting → transcribing → summarising` for a normal run
  (capture emitted phases via an `onPhase` that appends to an array; assert the sequence).
- A run that fails at convert emits only `.converting`; failure at transcribe emits
  `converting, transcribing` (no `summarising`). Confirms phases track real progress.

## Feature 2 — Language dropdown

### Catalog (DistavoCore, dependency-free)

Add `WhisperLanguageCatalog` alongside `EmbeddedModelCatalog` in DistavoCore:

```swift
public struct WhisperLanguage: Identifiable, Equatable {
    public let code: String      // "" = auto-detect, else ISO code ("en","es","ca",…)
    public let englishName: String
    public var id: String { code }
}

public enum WhisperLanguageCatalog {
    /// Auto-detect first, then languages sorted by English name.
    public static let all: [WhisperLanguage]
}
```

- Mirrors WhisperKit's canonical ~99-language set (`Constants.languages`), aliases de-duped to one
  canonical name per code. Lives in Core so it is shared by both backends and covered by the fast
  test suite. Hardcoded (not imported from WhisperKit) to keep DistavoCore dependency-free.
- First entry is **Auto-detect** with `code == ""` — the embedded engine already treats `""` as
  "detect language" (`options.language = config.language.isEmpty ? nil : …`), and WhisperX treats an
  empty `language=` query as auto-detect.

### UI (`SettingsView.swift`)

Replace line ~103 `TextField("Language", text: $draft.transcribe.language)` with a `Picker` (same
pattern as the existing model picker), Auto-detect at top then languages by English name, `tag` = the
ISO code so the stored value is always valid.

### Backward-compatibility / honesty

An existing config keeps its code (`"en"` selects English). If the stored code is **unrecognised**
(e.g. a past typo `"esp"`), do **not** silently change it: inject a one-off synthetic entry
`"esp — not a standard code"` (tag = the raw value) so the Picker keeps it selected and the user can
consciously switch. Same "never silently switch a user's setting" principle as the backend-migration
rule.

### Files touched

- `apple/DistavoCore/Sources/DistavoCore/EmbeddedSupport.swift` (or a new
  `WhisperLanguageCatalog.swift`) — the catalog.
- `apple/Sources/Distavo/Settings/SettingsView.swift` — the Picker + unrecognised-code handling.

### Tests (DistavoCore, fast suite)

- Catalog contains `ca`, `es`, `en`; Auto-detect exists with `code == ""`.
- All non-empty codes are unique and non-empty; list is sorted by English name after the Auto-detect
  entry.

## Delivery

Branch `feat/menubar-state-and-language`. Verify: `cd apple/DistavoCore && swift test` green;
`cd apple && xcodegen generate` then an unsigned Direct build succeeds; run the app to eyeball the
icon states and the language Picker. Bump `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, merge to
`main`, tag to trigger the release. Spec B follows on its own branch off the updated `main`.

## Out of scope

Auto-update (Spec B), icon animation, per-language model hints, translating language names.
