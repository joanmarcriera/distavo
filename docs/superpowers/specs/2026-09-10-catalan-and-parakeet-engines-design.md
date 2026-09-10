# Distavo 1.11 — Catalan models and Parakeet as built-in engines

**Status:** v2, 2026-09-10 — revised after the Codex design review
(`…design.review-codex.md`, verdict "rework"). Every blocker and high finding there is
addressed below; the review file stays beside this spec as the record.
**Scope:** slice 1 of the "better than the store competition" roadmap (Vikunja epic
https://familia.riera.co.uk/tasks/2130). Slices 2–4 are separate specs.

## 1. Why

Distavo already transcribes on-device (WhisperKit large-v3 turbo + SpeakerKit). Two things
changed the competitive picture in September 2026:

- **Parakeet-class speed is now table stakes.** Most local meeting-notes apps on the Mac App
  Store (Thoth, Talat, Logue, echo99, Goodmeet, …) ship NVIDIA Parakeet TDT 0.6B v3 through
  FluidAudio. Measured on the M5 Pro: a 21-minute call takes 3.3 s on Parakeet against ~44 s on
  Whisper turbo, with identical text to Desert Ant's Voz (which is the same model).
- **Nobody serves Catalan on-device, and Apple structurally cannot.** Verified on macOS 26.6:
  `SpeechTranscriber.supportedLocales` has 30 locales and no Catalan; `SystemLanguageModel`
  lists 23 languages and no Catalan, and Apple Intelligence cannot be enabled on a
  Catalan-language Mac. Parakeet and Voz have no Catalan either (a 64-minute mixed
  Catalan/Spanish/English meeting came back with 40 % of the words). Barcelona Supercomputing
  Center publishes Apache-2.0 Whisper large-v3 fine-tunes that do: `BSC-LT/whisper-large-v3-LoS`
  (Catalan, Spanish, Galician, Basque; 8,110 h) and
  `BSC-LT/whisper-large-v3-ca-punctuated-3370h` (Catalan; 3,370 h).

Distavo's defensible claim after this release: **"Meeting notes in Catalan, Spanish and their
mix, entirely on your Mac"**, with Parakeet as the fast path for 25 other languages.

**Desert Ant Labs is not adopted.** Its bases are open (Voz = Parakeet, Clear = DeepFilterNet 3,
Ear = whisper-tiny); the SDK requires macOS 15, writes a device ID and per-model usage counters
to user defaults, forbids disabling that telemetry, requires a "Powered by" line, and Clear
produced no measurable change on two real recordings.

## 2. What ships

| Engine (catalog id) | Runtime | Languages | Download | Offered by default on |
|---|---|---|---|---|
| `large-v3-turbo` (exists) | WhisperKit | 99 | 632 MB | ≥ 16 GB |
| `small` (exists) | WhisperKit | 99 | 463 MB | all |
| `parakeet-tdt-v3` (new) | FluidAudio | 25 European | ~460 MB (int8) | all Apple Silicon |
| `bsc-los` (new) | WhisperKit, custom repo | ca, es, gl, eu | ~1.6 GB fp16 | ≥ 16 GB (see §6) |
| `bsc-ca-3370h` (new) | WhisperKit, custom repo | ca | ~1.6 GB fp16 | ≥ 16 GB (see §6) |
| `whisper-tiny` (internal) | WhisperKit | — | 77 MB | language detector only |

Plus "Automatic" for model and language, a download coordinator, and "Download now" in Settings.

## 3. Pinned dependencies

- **FluidAudio:** pinned by revision to `41540ea237350afe5117a082b5c28eda642d0612` (main,
  2026-09-10), the first revision whose `Package@swift-6.2.swift` declares the
  `NemoTextProcessing` package trait (commit 6b90a08, 2026-09-09; not in any tag as of today).
  Consumed with `traits: []` so the prebuilt `NemoTextProcessing.xcframework` is not linked.
  Move to the first tag that contains it when released. Verification: `swift package
  show-traits`, clean resolve, and an archive scan (§9).
- **argmax-oss-swift:** the existing 1.0.0 pin. `WhisperKitConfig.modelRepo` exists there.
- **DistavoEmbedded manifest:** tools-version 6.2 with `swiftLanguageModes: [.v5]`. This keeps
  DistavoEmbedded's own targets in Swift 5 mode; dependency packages keep their own modes.
- FluidAudio API at the pin (used verbatim, no pseudocode): `AsrModels.downloadAndLoad(to:…)`,
  `AsrManager.transcribe(_ url: URL, decoderState: inout TdtDecoderState, language: Language?)`,
  `ASRResult.tokenTimings` → `buildWordTimings(from:)` → `[WordTiming]`.

## 4. Deferral contract (replaces "Pipeline unchanged")

Today every transcription error becomes a persistent `.failed` marker: `processOne` writes
`.processing`, and its catch-all calls `markFailed` (Pipeline.swift 206–245). The offline
download error text promises an automatic retry that never happens — a pre-existing bug
(https://familia.riera.co.uk/tasks/2149) that this release fixes for all engines.

- DistavoCore gains `public struct RetryableDependencyError: Error { let message: String }`.
  Any `PipelineDeps.transcribe` implementation throws it for conditions that can resolve on
  their own: offline model or tokenizer download, download interrupted, model directory busy.
- `Pipeline.processOne`: `catch let e as RetryableDependencyError` → `state.clearProcessing(base)`,
  return `ProcessResult(status: .deferred, …)` (new `ProcessStatus.deferred = "deferred"`), no
  `.failed`. All other errors keep today's path. `Scanner`/`WatcherController` treat `.deferred`
  like `.deferredNeedLocal` for status text.
- `EmbeddedTranscriber` maps `modelUnavailable(offline: true)` to the retryable error; the
  detector and `ParakeetTranscriber` do the same for their download/offline failures.
- Test: two scans through the seam — first `transcribe` throws retryable, second succeeds — no
  `.failed` marker after scan 1, note written after scan 2, no manual "Process now".

## 5. Architecture

### 5.1 Engine catalog (`DistavoCore/EmbeddedSupport.swift`)

`EmbeddedModel` gains `engine: EmbeddedEngine` (`.whisperKit` | `.parakeet`),
`whisperKitRepo: String?` (`nil` = Argmax's repo; BSC entries =
`Joanmarcriera/distavo-whisperkit-coreml`), `languages: LanguageCoverage` (`.whisper`,
`.parakeet`, `.only(Set<String>)`), `minimumMemoryGB: Int` (16 for BSC, 0 otherwise).
`whisper-tiny` is a separate constant. `model(id:)` keeps its unknown-id fallback.

Config: `transcribe.embedded_model` and `transcribe.language` accept the literal `"auto"`;
`transcribe.preferred_catalan_model` (`"bsc-los"` default; invalid value → `"bsc-los"`).
**Only** `Config.recommendedForThisMac()` (no config file present) produces `"auto"`. An existing
file with a missing new key gets the historical default; empty or unknown language/model
strings keep today's behaviour (unknown model → `large-v3-turbo`, unknown language shown as-is).

### 5.2 Routing (`DistavoCore/EngineRouter.swift`, pure)

Input: `LanguageEvidence` = up to three detections `(code, probability)` from separate speech
windows, plus `TranscribeConfig` and `HardwareProbe.physicalMemoryBytes`. Output:
`RoutingDecision { model: EmbeddedModel, languageHint: String? }` — the hint is a real Whisper
code or `nil`, never `"auto"`; the Parakeet adapter maps it to FluidAudio's typed `Language?`.

1. Model not `"auto"` → that model; hint = fixed language, or the top detection if `"auto"`.
2. Confident set C = codes with probability ≥ 0.5 across windows (fixed language ⇒ C = {it}).
3. C ∩ {ca, gl, eu} ≠ ∅ and C ⊆ {ca, es, gl, eu} → `bsc-los`, unless C = {ca} → preferred Catalan.
4. C ∩ {ca, gl, eu} ≠ ∅ and C has other languages (e.g. ca + en) → `bsc-los` (hint = ca);
   never Parakeet when any Catalan/Galician/Basque is confident. The bake-off measures LoS on
   Catalan+English mixtures; if it is worse than turbo, this rule switches to turbo.
5. C = {es} → `bsc-los`; C ⊆ Parakeet's 25 → `parakeet-tdt-v3` (hint = dominant).
6. Otherwise, or C empty → `large-v3-turbo` (or `small` below 16 GB), hint = top detection or nil.
7. Memory gate: a BSC model chosen by rules 3–5 on a Mac below `minimumMemoryGB` falls to
   `large-v3-turbo`/`small` with a status message naming the limitation.

### 5.3 Language detector (`DistavoEmbedded/LanguageDetector.swift`)

WhisperKit `openai_whisper-tiny`, downloaded into the models folder. Picks three 30-second
windows at roughly 10 %, 50 % and 90 % of the file, each shifted forward to the next region
whose RMS energy exceeds a silence floor (skips leading silence/music), and calls
`detectLangauge(audioArray:)` per window. Returns the three `(code, probability)` pairs.
Cost: three sub-second passes on a 77 MB model.

### 5.4 Parakeet transcriber (`DistavoEmbedded/ParakeetTranscriber.swift`)

FluidAudio per §3; models under `EmbeddedModelStore.modelsDirectory/parakeet`; per-call
lifetime; word timings via `buildWordTimings(from:)`. Diarisation: SpeakerKit as today. The
model is released before SpeakerKit loads (same order for the WhisperKit path, §6).

### 5.5 Word–speaker alignment (`DistavoCore/WordSpeakerAligner.swift`, pure)

Adapter in DistavoEmbedded converts `DiarizationResult.segments` and `[WordTiming]` into core
structs `SpeakerTurn(speaker: Int, start, end)` and `TimedWord(text, start, end)`. The aligner
ports SpeakerKit's `.subsegment` behaviour so both engines label identically:

- a word takes the turn with the **largest time intersection**; ties → the earlier-starting turn;
- words within 0.15 s of each other share a subsegment (SpeakerKit's default threshold, kept
  for parity); a subsegment that overlaps no turn inherits the previous subsegment's speaker
  when the silence before it is ≤ 1.0 s, otherwise it is `unknown` (rendered `SPEAKER_UNKNOWN`
  by the cleaner) — SpeakerKit carries unconditionally, the spec bounds it;
- consecutive same-speaker words form a segment; segments split at sentence-final punctuation
  (`.?!…` and their Unicode variants) and at speaker change; text joins with single spaces;
- empty, nil or out-of-order timings are sorted/skipped deterministically.

### 5.6 Custom WhisperKit models

`EmbeddedTranscriber` passes `modelRepo` from the catalog to `WhisperKitConfig`. WhisperKit
chooses the tokenizer from the loaded model's tensor signature (vocabulary size and encoder
dimensions → `.largev3` → `openai/whisper-large-v3`), so a correct large-v3 conversion resolves
the right tokenizer regardless of folder name; folder names only need to be unique for the
download glob: `BSC-LT_whisper-large-v3-LoS`, `BSC-LT_whisper-large-v3-ca-punctuated-3370h`.
The tokenizer download is a third Hugging Face repo, as it already is for turbo today.

Immutability: each published folder carries `manifest.json` (source model revision,
whisperkittools commit, per-file sizes and SHA-256). The app verifies the manifest after
download, never replaces files in place (stage → verify → atomic rename), and a new conversion
gets a new folder name (`…-r2`) plus a catalog bump rather than overwriting.

### 5.7 Conversion tool (`tools/whisperkit-models/`)

`convert.sh <hf-model-id>`: `uv` venv on Python 3.11, whisperkittools at a recorded commit
(torch 2.5, coremltools), `generate_model.py --model-version <id> --upload-results`,
`MODEL_REPO_ID=Joanmarcriera/distavo-whisperkit-coreml`, `HF_TOKEN` from `~/.tokens`, never
printed. fp16 (the Argmax recipe). Writes `manifest.json`. **Spike first (task 2141):** convert
LoS, then prove from a clean models folder: download from the custom repo, tokenizer
resolution, cold load, offline warm reload, transcription with word timestamps, relaunch.

### 5.8 Model download coordinator (`DistavoEmbedded/ModelCoordinator.swift`, actor)

One actor owns every model on disk: per-model readiness (`ready`/`downloading(progress)`/
`absent`), sizes, staging directory + atomic promotion, cancellation, free-space check (need
2× download size), and mutual exclusion between downloads, transcription and "Remove downloaded
models" (removal waits for or cancels in-flight work). Settings and the pipeline both go through
it, so "Download now" and a timer scan cannot run the same download twice. Progress is a
structured stream; the existing single transcriber callback is fed from it.

### 5.9 Pipeline wiring (`Sources/Distavo/Core/AppPipelineDeps.swift`)

`deps.transcribe` for `backend == "embedded"`: coordinator ensures the detector → detect (if
either setting is `"auto"`) → `EngineRouter` → coordinator ensures the chosen model → dispatch to
`EmbeddedTranscriber` (with repo) or `ParakeetTranscriber`. Retryable conditions throw
`RetryableDependencyError` (§4). `PipelineDeps` signature unchanged.

### 5.10 Settings

Grouped model picker with human labels and sizes; **Automatic (recommended)** first; entries
whose `minimumMemoryGB` exceeds this Mac are shown disabled with the reason. "Preferred Catalan
model" only under Automatic. Language picker gains **Automatic (detect)**. **Download now**
shows the total before starting (Automatic = detector + Parakeet + preferred Catalan model,
≈ 2.1 GB on a 16 GB Mac, ≈ 0.55 GB below), with progress and Cancel. "Models on disk" lists per
model. Copy distinguishes Distavo's folder from macOS's own Core ML caches.

### 5.11 Credits and compliance

`NOTICES.md` and About: FluidAudio (Apache-2.0), NVIDIA Parakeet TDT 0.6B v3 (CC-BY-4.0),
BSC Language Technologies Unit / Projecte AINA (Apache-2.0), Argmax (MIT). No telemetry.
Network: Hugging Face only (model repos, tokenizer repo, and its CDN redirects). Identical in
all three editions; App Store archive scanned for unexpected frameworks/binaries.

## 6. Memory gate

1.6 GB is on-disk size, not peak RSS. BSC models are offered and auto-routed only on ≥ 16 GB
until measured. Release task: measure peak RSS, memory pressure, swap, cold specialisation and
warm load on a physical 8 GB and a 16 GB Apple Silicon Mac, short file and the 64-minute
meeting, diarisation on/off, with `prewarm` evaluated and the transcription model released
before SpeakerKit loads. `minimumMemoryGB` and catalog `ramGB` are set from those numbers.

## 7. Error handling

- Retryable (offline, interrupted download, busy directory) → §4, recording stays pending.
- Manifest/hash mismatch or corrupt cache → the folder is discarded and re-downloaded once;
  a second failure is retryable with a message naming the model.
- Parakeet or WhisperKit load failure on a supported Mac → permanent, message names the model
  and points at "Compact" or the server backend. Intel Macs keep the server backend.

## 8. Testing

- **Core:** catalog decode incl. `"auto"` and invalid `preferred_catalan_model`; router table for
  rules 1–7 with permutations (en→ca, ca→en, ca+es, es only, low probability, empty, 8 GB);
  aligner fixtures (crosstalk, equal overlap, word straddling a boundary, leading/trailing/long
  gaps, nil/empty/out-of-order timings, Unicode punctuation); deferral two-scan test;
  golden config fixtures (pre-embedded, server, 8 GB embedded, 16 GB embedded, empty language,
  unknown values) asserting decoded values **and** dispatch, before and after save/reload.
- **Embedded live (`DISTAVO_LIVE=1`):** Parakeet on the fixture WAV (text + word timings);
  detector returns `en`; converted BSC model cold download, warm offline reload, manifest
  rejection on a tampered file.
- **Signed App Store build, manual checklist:** download each engine, relaunch offline, remove,
  re-download, cancel mid-download, quit during download, scan vs "Download now" overlap;
  archive scan; network destinations captured.
- **Bake-off before tagging:** the 2026-07-23 mixed meeting and the 2026-09-09 English call
  through the full app; chosen engine recorded per run; Catalan summary quality is the go/no-go.
- **CI:** `swift test`, `swift package show-traits`, and all three edition schemes
  (fixed in commit 0d6bcd8).

## 9. Out of scope (later slices)

Catalan/Spanish note templates (slice 2), capture robustness and storage (slice 3), store copy
and Setapp (slice 4), quantised BSC variants, Parakeet streaming, FluidAudio's Sortformer.
