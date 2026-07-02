# Embedded transcription + meeting capture — design

**Date:** 2026-07-02 · **Status:** approved by Marc (2026-07-02) · **Branch strategy:** two slices, each its own branch/PR.

## Problem

Distavo today requires the user to run a WhisperX server (and an Ollama server) before the app does
anything. WhisperX has been the weak link in practice, and "install two servers first" defeats the
product's promise for non-technical users. Separately, users must record meetings with some other
tool into the watched folder; capturing meeting audio (other participants + own mic) should be
built in — without asking users to install BlackHole or build multi-output devices.

## Decisions (made with Marc)

1. **Scope:** embed transcription now; embedded summarisation is a later slice (Ollama stays for
   summaries; the `SummariseConfig.backend` pattern already accommodates a future `embedded`).
2. **Deployment target:** bump 13.0 → **14.0** (WhisperKit floor). Meeting capture is runtime-gated
   at **14.4** (Core Audio taps TCC floor).
3. **Slices:** slice 1 = embedded transcription; slice 2 = meeting capture. Ship independently.
4. **Default UX:** embedded engine is the default for **new** installs on Apple Silicon; existing
   configs keep their server settings (migration rule below). Servers become "Advanced".
5. **Hardware-fit models (Marc's amendment):** the app detects chip + RAM and recommends a model
   that actually runs comfortably on that Mac; the user confirms the choice (with download size and
   RAM cost shown) before anything downloads.

## Slice 1 — Embedded transcription engine

### Engine choice

**WhisperKit + SpeakerKit** from `argmaxinc/argmax-oss-swift` (MIT, v1.x): Whisper CoreML models
(ANE-accelerated), word/segment timestamps, and pyannote-v4 speaker diarization with
`addSpeakerInfo()`-style merging — the only pure-SwiftPM option that reproduces the WhisperX
contract (segments + timestamps + speaker labels). Requires macOS 14+, Apple Silicon.

Rejected alternatives: Apple SpeechTranscriber (macOS 26 only, no diarization — future optional
"fast" engine); whisper.cpp (C glue, turn-level diarization only); FluidAudio/Parakeet (language
coverage). Documented here so we don't re-litigate.

### Architecture

- New library target **`DistavoEmbedded`** in the `DistavoCore` package, depending on
  `WhisperKit` + `SpeakerKit` and `DistavoCore`. `DistavoCore` itself stays dependency-free so
  `swift test` on the core remains fast and headless.
- `DistavoEmbedded` exposes an `EmbeddedTranscriber` whose output is the **same
  `[String: Any]` WhisperX shape** consumed by `TranscriptCleaner`
  (`["segments": [{speaker, text, start, end}]]`). Pipeline, cleaner, and existing tests unchanged.
- The live `transcribe` closure branches on `config.transcribe.backend`
  (`"embedded"` → `EmbeddedTranscriber`, `"server"` → `WhisperXClient`). The `PipelineDeps` seam is
  preserved; the real WhisperKit calls are wrapped behind a small protocol so unit tests inject a
  fake engine and test only the mapping + branching.

### Config

`TranscribeConfig` gains:

| key (JSON) | default | notes |
|---|---|---|
| `backend` | `"server"` in `Defaults` | **Migration rule:** existing config file lacking the key deep-merges to `"server"` (no behavior change for current users). A **fresh install** writes `"embedded"` on Apple Silicon (`"server"` on Intel). |
| `embedded_model` | `"large-v3-turbo"` | selectable: `large-v3-turbo` (~626 MB download, ~2 GB RAM) or `small` (~466 MB, ~1 GB RAM). |

`diarize`, `num_speakers`, `language` apply to both backends.

### Hardware detection & model recommendation

- Apple Silicon check: `utsname`/`hw.optional.arm64`. RAM: `ProcessInfo.physicalMemory`.
- Recommendation: **≥ 16 GB RAM → `large-v3-turbo`; < 16 GB → `small`.** The non-recommended
  option stays selectable with an honest note (e.g. "may be slow / memory-heavy on this Mac").
- Shown at first-run onboarding and in Settings whenever the engine/model is changed. Nothing
  downloads without the user confirming a screen that states model name, download size, disk
  location, and estimated RAM while transcribing.
- Intel Macs: Embedded option disabled with explanation; server backend remains fully supported.

### Model storage & cleanup (transparency)

- Models download from Hugging Face (`argmaxinc/whisperkit-coreml` + SpeakerKit models) into
  **`~/Library/Application Support/Distavo/models`** (container path under App Store sandbox) by
  overriding the packages' default cache dirs. Uses the existing `network.client` entitlement.
- Settings shows download progress, per-model disk usage, and a **"Remove downloaded models"**
  button. Activity log records downloads and removals. Nothing is installed outside that folder.
- If the embedded backend is selected but the model isn't downloaded yet when a recording arrives,
  the pipeline downloads it lazily (consent was given at selection time), surfacing progress in the
  menu status and activity log.

### Licensing

MIT (WhisperKit/SpeakerKit) + Apache-2.0 (vendored swift-transformers) → `NOTICES.md` in the repo
and an acknowledgements entry in the app's Help/About. No GPL anywhere.

### Slice-1 deliverables

1. Deployment target 14.0 (`project.yml`, `Package.swift` platforms, docs, CI if pinned).
2. `DistavoEmbedded` target + WhisperKit/SpeakerKit SwiftPM dependency.
3. `EmbeddedTranscriber` (protocol-wrapped engine, WhisperX-shape output, model-dir override,
   lazy download with progress callback).
4. Config `backend`/`embedded_model` + migration rule + hardware recommender.
5. Settings UI: engine picker, model picker with size/RAM info, download state, remove-models;
   servers under "Advanced". Onboarding path for fresh installs.
6. Tests: config migration, backend branching, engine-output mapping via fake, recommender logic;
   gated live E2E (`DISTAVO_LIVE_EMBEDDED=1`) with the smallest real model.
7. `NOTICES.md` + Help acknowledgements + README/docs updates.

## Slice 2 — Record Meeting (system audio + mic)

### Mechanism

**Core Audio process taps** (macOS 14.4+): `CATapDescription` global tap excluding Distavo's own
PID → `AudioHardwareCreateProcessTap` → **private** aggregate device
(`kAudioAggregateDeviceIsPrivateKey`, tap + default mic sub-device,
`kAudioAggregateDeviceTapDriftCompensationKey: true`) → one IOProc → **stereo WAV** (mic on one
channel, system audio on the other; diarization/transcription handles the rest downstream).
Implementation adapted from `insidegui/AudioCap` (BSD-2, attributed in NOTICES) **without** its
private-TCC permission probe (App-Store-clean).

Why this works while Zoom/Teams/Meet are running: macOS Core Audio is multi-client (the mic can be
read by several processes at once), and the tap captures other apps' *output* at the OS mixer — the
API exists precisely for live-meeting capture (Granola, MacWhisper, Audio Hijack ARK precedents;
Whisper Transcription is the sandboxed Mac App Store approval precedent).

### Integration

Stop-recording writes `Meeting YYYY-MM-DD HH.mm.wav` into the watched recordings folder; the
existing watcher/pipeline takes over. **Zero pipeline changes.**

### UX & honesty

- Menu: "Start recording meeting" / "Stop recording (12:34)" with elapsed time; hidden below 14.4.
- First-use pre-flight explains: the two permissions (Microphone + System Audio Recording — two
  separate macOS prompts), the purple indicator while recording, that audio never leaves the Mac
  except to the user's own configured engine/servers, the speakers-vs-headphones double-voice
  caveat, and the cleanup story: tap + aggregate destroyed on stop, nothing in Audio MIDI Setup,
  nothing installed, both permissions revocable in Privacy & Security.
- Denied system-audio permission yields silence, not an error → detect sustained all-zero tap input
  and deep-link to `x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture`.
- Notification on stop: "Recording saved — processing…". Known caveats documented: Bluetooth
  headsets in call (HFP) degrade capture quality; exclusive-mode (hog) pro-audio apps can't be
  tapped. BlackHole: one docs paragraph for pre-14.4 DIYers; never bundled (GPL-3).

### Entitlements / Info.plist

- App Store entitlements: add `com.apple.security.device.audio-input`.
- All editions: `NSMicrophoneUsageDescription` + `NSAudioCaptureUsageDescription` (manual key).

### Slice-2 deliverables

1. `MeetingRecorder` (tap + aggregate + IOProc + WAV writer) in the app target, state machine
   separated for unit testing; AudioCap attribution in NOTICES.
2. Menu items + pre-flight window + permission-denied detection + notification.
3. Entitlements/Info.plist changes; edition parity (works in all three).
4. Tests: state-machine unit tests; manual verification checklist (real recording on Marc's Mac
   with music/a call playing) — CI cannot exercise TCC/audio hardware.
5. Docs: website/README, distribution-checklist updates, BlackHole footnote.

## Out of scope (follow-ups)

- Embedded summarisation (slice 3 candidate: Apple Foundation Models on macOS 26 and/or llama.cpp;
  `SummariseConfig.backend` already accommodates it).
- Apple SpeechTranscriber as optional fast engine (macOS 26+).
- Echo cancellation (AUVoiceIO is flaky cross-device; stereo separation + diarization suffices).

## Risks

- **WhisperKit API drift:** research summarised the API; exact symbols must be verified against the
  resolved package source during implementation, not assumed.
- **Sandbox + taps fragility:** one developer reported quirks; MAS precedent exists. Budget
  debugging time; verify the App Store build explicitly.
- **CI:** WhisperKit adds SwiftPM resolution to CI builds; core-only `swift test` stays fast. TCC
  prompts require signed builds — capture is verified manually, not in CI.
