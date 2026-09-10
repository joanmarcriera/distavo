# Distavo 1.11 — Catalan models and Parakeet as built-in engines

**Status:** approved design, 2026-09-10 (Vikunja #2086 evaluation outcome).
**Scope:** slice 1 of the "better than the store competition" roadmap. Slices 2–4 (note
quality, capture robustness, listing/Setapp) are separate specs.

## 1. Why

Distavo already transcribes on-device (WhisperKit large-v3 turbo + SpeakerKit). Two things
changed the competitive picture in September 2026:

- **Parakeet-class speed is now table stakes.** Most local meeting-notes apps on the Mac App
  Store (Thoth, Talat, Logue, echo99, Goodmeet, …) ship NVIDIA Parakeet TDT 0.6B v3 through
  FluidAudio. Measured on the M5 Pro: a 21-minute call takes 3.3 s on Parakeet against ~44 s on
  Whisper turbo, with identical text to Desert Ant's Voz (which is the same model).
- **Nobody serves Catalan on-device, and Apple structurally cannot.** Verified on macOS 26.6:
  `SpeechTranscriber.supportedLocales` has 30 locales and no Catalan; `SystemLanguageModel`
  lists 23 languages and no Catalan, and Apple Intelligence cannot be enabled on a Catalan-language
  Mac. Parakeet and Voz have no Catalan either (a 64-minute mixed Catalan/Spanish/English
  meeting came back with 40 % of the words, the Catalan as Spanish nonsense). Barcelona
  Supercomputing Center publishes Apache-2.0 Whisper large-v3 fine-tunes that do:
  `BSC-LT/whisper-large-v3-LoS` (Catalan, Spanish, Galician, Basque; 8,110 h) and
  `BSC-LT/whisper-large-v3-ca-punctuated-3370h` (Catalan; 3,370 h).

Distavo's defensible claim after this release: **"Meeting notes in Catalan, Spanish and their
mix, entirely on your Mac"**, with Parakeet as the fast path for 25 other languages.

**Desert Ant Labs is not adopted.** Its bases are open (Voz = Parakeet, Clear = DeepFilterNet 3,
Ear = whisper-tiny); the SDK requires macOS 15, writes a device ID and per-model usage counters
to user defaults, forbids disabling that telemetry, requires a "Powered by" line, and Clear
produced no measurable change on two real recordings. Everything it offered is available
under MIT/Apache-2.0 without those strings.

## 2. What ships

| Engine (catalog id) | Runtime | Languages | Download | Role |
|---|---|---|---|---|
| `large-v3-turbo` (exists) | WhisperKit | 99 | 632 MB | "Best" fallback |
| `small` (exists) | WhisperKit | 99 | 463 MB | 8 GB Macs |
| `parakeet-tdt-v3` (new) | FluidAudio | 25 European | ~460 MB | "Fast" |
| `bsc-los` (new) | WhisperKit, custom repo | ca, es, gl, eu | ~1.6 GB fp16 | Languages of Spain |
| `bsc-ca-3370h` (new) | WhisperKit, custom repo | ca | ~1.6 GB fp16 | Best Catalan |
| `whisper-tiny` (internal) | WhisperKit | — | 77 MB | language detector only |

Plus two "Automatic" settings (model and language) and a "Download now" button in Settings.

## 3. Architecture

### 3.1 Engine catalog (`DistavoCore/EmbeddedSupport.swift`)

`EmbeddedModel` gains:

- `engine: EmbeddedEngine` — `.whisperKit` or `.parakeet`.
- `whisperKitRepo: String?` — `nil` means Argmax's `argmaxinc/whisperkit-coreml`; the BSC entries
  point at `Joanmarcriera/distavo-whisperkit-coreml` (Marc's Hugging Face account).
- `languages: LanguageCoverage` — `.whisper` (all 99), `.parakeet` (the 25), or `.only(Set<String>)`.
- `downloadMB`, `ramGB`, `displayName`, `detail` as today.

`EmbeddedModelCatalog.models` lists the five user-selectable entries above; `whisper-tiny` is a
separate constant used only by the detector. `model(id:)` keeps its unknown-id fallback.
`transcribe.embedded_model` accepts the new value `"auto"`; `transcribe.language` accepts `"auto"`.
Both remain plain strings in JSON, so old configs decode unchanged (migration rule preserved:
existing users keep their explicit model and language).

A new `transcribe.preferred_catalan_model` (`"bsc-los"` default, or `"bsc-ca-3370h"`) is read only
when the model is `"auto"`.

### 3.2 Routing (`DistavoCore/EngineRouter.swift`, pure)

```
EngineRouter.choose(detectedLanguage: String?, config: TranscribeConfig) -> EmbeddedModel
```

Rules, in order:

1. Model not `"auto"` → the chosen model, regardless of language.
2. Detected `ca`, `gl`, `eu` → `preferred_catalan_model`; `es` → `bsc-los`.
3. Detected language in Parakeet's 25 → `parakeet-tdt-v3`.
4. Anything else, or no detection → `large-v3-turbo` (or `small` on < 16 GB, as today).

When language is fixed (not `"auto"`) but model is `"auto"`, the fixed language is used as the
"detected" value and no detector runs.

### 3.3 Language detector (`DistavoEmbedded/LanguageDetector.swift`)

WhisperKit `openai_whisper-tiny` from Argmax's repo, downloaded into the same models folder.
Runs `detectLanguage` on the first 30 s of the converted WAV; returns the code and probability.
Below a 0.5 probability the router treats the result as "no detection" (rule 4).

### 3.4 Parakeet transcriber (`DistavoEmbedded/ParakeetTranscriber.swift`)

- FluidAudio `AsrModels.downloadAndLoad(to: EmbeddedModelStore.modelsDirectory/"parakeet")`,
  `AsrManager.transcribe(url, language:)` with token timings → `[TimedWord]`.
- Per-call lifetime, like `EmbeddedTranscriber` (menu-bar app must not hold model RAM).
- Diarisation: SpeakerKit, exactly as the Whisper path, producing `[SpeakerTurn]`.
- `WordSpeakerAligner` (DistavoCore, pure) assigns each word to the turn containing its
  midpoint (nearest turn if none), groups consecutive same-speaker words into segments, splits on
  sentence-final punctuation, and emits the WhisperX `["segments": [...]]` dictionary. The
  existing `TranscriptCleaner` and everything downstream stay untouched.
- FluidAudio is added with `traits: []` so the NemoTextProcessing prebuilt xcframework is not
  linked. This requires `DistavoEmbedded/Package.swift` at tools-version 6.2 with
  `swiftLanguageModes: [.v5]` to keep today's concurrency checking level.

### 3.5 Custom WhisperKit models

`EmbeddedTranscriber` passes `modelRepo` from the catalog to `WhisperKitConfig`. WhisperKit
resolves the tokenizer from the variant folder name (must contain `large-v3`), so the published
folders are named `BSC-LT_whisper-large-v3-LoS` and `BSC-LT_whisper-large-v3-ca-punctuated-3370h`.

### 3.6 Conversion tool (`tools/whisperkit-models/`)

- `convert.sh <hf-model-id>`: `uv` venv on Python 3.11, `whisperkittools` (torch 2.5,
  coremltools), runs `generate_model.py --model-version <id> --upload-results` with
  `MODEL_REPO_ID=Joanmarcriera/distavo-whisperkit-coreml`. Token from `~/.tokens` (`HF_TOKEN`),
  never printed.
- Output: fp16 encoder/decoder, the default Argmax recipe. Quantised variants are a follow-up
  only if measurements demand it.
- A `README.md` records the exact commit of whisperkittools and the source model revision used,
  so the published model is reproducible.

### 3.7 Pipeline wiring (`Sources/Distavo/Core/AppPipelineDeps.swift`)

`deps.transcribe` for `backend == "embedded"` becomes: detect (if needed) → route → dispatch to
`EmbeddedTranscriber` (WhisperKit, with repo) or `ParakeetTranscriber`. Progress messages
("Detecting language…", "Downloading Parakeet — 460 MB, one-time…") flow through the existing
progress handler. `Pipeline.swift` and `PipelineDeps` are unchanged.

### 3.8 Settings (`Sources/Distavo/Settings/SettingsView.swift`)

- Model picker, grouped: **Automatic (recommended)** · Fast — Parakeet (25 languages, 460 MB) ·
  Best — Whisper large-v3 turbo (99 languages, 632 MB) · Compact — Whisper small (463 MB) ·
  Català · Castellà · Galego · Euskara — BSC Languages of Spain (1.6 GB) · Català — BSC 3,370 h (1.6 GB).
- "Preferred Catalan model" picker, visible only for Automatic.
- Language picker gains **Automatic (detect)** at the top.
- **Download now** button for the selected model (or, for Automatic, the detector + Parakeet +
  preferred Catalan model) with a progress bar; "Models on disk" and "Remove downloaded models"
  keep covering the single folder.
- `Config.recommendedForThisMac()` sets `embedded_model = "auto"`, `language = "auto"` for fresh
  installs only.

### 3.9 Credits and compliance

- `NOTICES.md` and the About screen: FluidAudio (Apache-2.0), NVIDIA Parakeet TDT 0.6B v3
  (CC-BY-4.0, attribution required), BSC Language Technologies Unit / Projecte AINA (Apache-2.0),
  Argmax (MIT, existing).
- No telemetry, no network beyond the two Hugging Face repos on download. Identical in all three
  editions; App Store build gains no binary framework.

## 4. Error handling

- Detector or model download offline → existing `modelUnavailable(offline:)` path: the recording
  is retried automatically on the next scan, never failed.
- Parakeet load failure on a supported Mac → surfaced with the same wording pattern; the recording
  stays pending. Intel Macs keep the server backend as today (`HardwareProbe`).
- Router never returns a model the Mac cannot run: on < 16 GB the 1.6 GB BSC models are still
  offered (they fit) but the "Best" fallback is `small`.

## 5. Testing

- **DistavoCore unit tests:** catalog decode/fallback including `"auto"`; `EngineRouter` table
  (every rule, low-probability detection, fixed language + auto model); `WordSpeakerAligner`
  with fixture words/turns (overlaps, gaps, punctuation splits, single speaker, no turns).
- **DistavoEmbedded live test** (`DISTAVO_LIVE=1`): Parakeet on the bundled 10-second fixture
  WAV produces non-empty text and word timings; detector on the same file returns `en`.
- **Bake-off before tagging:** the 2026-07-23 Catalan/Spanish/English meeting and the
  2026-09-09 English call through the full app pipeline; compare against today's transcripts and
  note wall-clock. Summary quality on the Catalan meeting is the go/no-go for the release.
- **CI:** existing `swift test` + unsigned Direct build; compliance gates via
  `distavo-native-verify`.

## 6. Out of scope (later slices)

Catalan/Spanish note templates and summariser language (slice 2), capture robustness and
storage (slice 3), store copy in three languages and the Setapp submission (slice 4), quantised
BSC variants, Parakeet streaming, FluidAudio's Sortformer diariser.
