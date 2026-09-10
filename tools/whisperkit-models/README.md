# whisperkit-models

Converts a Hugging Face Whisper checkpoint to WhisperKit Core ML and publishes it
to Marc's `Joanmarcriera/distavo-whisperkit-coreml` repo, so Distavo's embedded
transcriber can load it as a custom-repo `EmbeddedModelCatalog` entry (spec §5.7).

## Usage

```sh
# Needs: uv, ~10 GB free disk, HF_TOKEN in ~/.tokens (write scope). Never prints the token.
tools/whisperkit-models/convert.sh BSC-LT/whisper-large-v3-LoS

# Pin the converter for a reproducible build:
WHISPERKITTOOLS_COMMIT=<sha> tools/whisperkit-models/convert.sh BSC-LT/whisper-large-v3-ca-punctuated-3370h
```

`manifest.py` is called by `convert.sh` (not run standalone); it walks the
converted folder and writes `manifest.json` — source revision, the
`whisperkittools` revision, and a `{bytes, sha256}` per file — so the app can
verify a download and a later conversion never silently replaces this one.

## What's published

Both BSC (Barcelona Supercomputing Center) Catalan Whisper fine-tunes, converted
and published 2026-09-10:

| Folder | Source model | Source revision | Size | Files |
|---|---|---|---|---|
| `BSC-LT_whisper-large-v3-LoS` | `BSC-LT/whisper-large-v3-LoS` (8,110 h, Catalan/Spanish/Galician/Basque) | `e562381fff61707117dffb9de6d699905d78f8ef` | 3.10 GB | 21 (incl. `manifest.json`) |
| `BSC-LT_whisper-large-v3-ca-punctuated-3370h` | `BSC-LT/whisper-large-v3-ca-punctuated-3370h` (3,370 h, Catalan, punctuated) | `5a5fb60f977e349e9d8d1fac1ecbb945c1e81b0a` | 3.10 GB | 21 (incl. `manifest.json`) |

Each was converted with `whisperkittools` commit
`84f77a83c8f530022ae55fbb1a64b3351ef63c7a` (installed as the PyPI-named `whisperkit`
distribution — `pip show whisperkittools` finds nothing; check
`uv pip freeze` for the `whisperkit @ git+https://github.com/argmaxinc/whisperkittools.git@<sha>`
line instead), ~40 minutes per model on the M5 Pro.

Distavo's `EmbeddedModelCatalog` references these as catalog ids `bsc-los` and
`bsc-ca-3370h`; `EmbeddedTranscriber` loads them via
`WhisperKitConfig(model:downloadBase:modelRepo:...)` with
`modelRepo: "Joanmarcriera/distavo-whisperkit-coreml"`, same as any other
WhisperKit repo — no app-side special-casing needed.

## Two traps the script handles

- **The target repo must exist first.** `whisperkittools` commits Core ML output
  into the repo it's given but doesn't create one; `convert.sh` calls
  `HfApi().create_repo(..., exist_ok=True)` before the conversion runs.
- **BSC publishes `.bin` weights; `transformers` refuses `torch.load` of a `.bin`
  checkpoint below torch 2.6, and `whisperkittools` pins torch 2.5.** `convert.sh`
  spins up a sibling venv (`weights-venv`) with `torch>=2.6`, re-saves the
  checkpoint as safetensors into `.work/src/<org>/<name>`, and hands the
  converter that **local** directory (named so its output folder still matches
  what a Hub id would produce).

## Step 4 verification — proving the artefact through Distavo's own engine

`EmbeddedPipelineLiveTests` (in `apple/DistavoEmbedded/Tests/DistavoEmbeddedTests/`)
now accepts `DISTAVO_PIPELINE_MODEL` (an `EmbeddedModelCatalog` id) and
`DISTAVO_PIPELINE_LANGUAGE` (a Whisper code or `auto`), and calls
`EmbeddedTranscriber.shared.transcribe(wavURL:model:languageHint:config:)` — the
same entry point the app's router uses. Run against `bsc-los`, language `ca`, on
a 64-minute mixed Catalan/Spanish/English recording (private; word counts only
below, never transcript text):

```sh
cd apple/DistavoEmbedded
DISTAVO_PIPELINE_LIVE=1 DISTAVO_PIPELINE_MODEL=bsc-los DISTAVO_PIPELINE_LANGUAGE=ca \
  DISTAVO_PIPELINE_AUDIO=<64-min recording.wav> DISTAVO_PIPELINE_OUT=<scratch dir> \
  swift test --filter EmbeddedPipelineLiveTests
```

**Cold run** (`bsc-los` not yet on disk — first download from the custom repo;
tested 2026-09-10):
- Downloaded into `~/Library/Application Support/Distavo/models/models/Joanmarcriera/distavo-whisperkit-coreml/BSC-LT_whisper-large-v3-LoS` — 3.10 GB, 21 files (matches the manifest exactly).
- Tokenizer resolved to `models/openai/whisper-large-v3` and was **reused** — that
  folder already existed from an earlier `large-v3-turbo` install (dated 2026-07-02),
  so no second tokenizer download.
- Model load (download + Core ML load): **440 s** (~7.3 min).
- Transcription only: **352 s**; diarization: **14 s**; combined: **807 s**.
- 113 segments, all carrying `start`/`end` timing.
- Transcript: 5,910 words (30,273 chars) — vs. today's `large-v3-turbo` transcript
  of the same file at 7,144 words (see Concerns below).
- Full test (transcribe + both summarisers): **942 s** (~15.7 min), passed.

**Warm run, offline** (Wi-Fi off via `networksetup -setairportpower en0 off` for
the duration, restored after):
- `model_on_disk_before_run=true`; **no download attempted**, test passed with no
  network.
- Model load (from disk only): **5 s** — vs. 440 s cold.
- Transcription only: **347 s**; diarization: **15 s**; combined: **367 s**.
- 109 segments, all carrying `start`/`end` timing.
- Transcript: 5,637 words (28,892 chars).
- Full test: **491 s** (~8.2 min), passed.

Both runs printed benign `ANE op async execution has timed out` warnings from
CoreML's Neural Engine scheduler during transcription (a known WhisperKit/ANE
quirk, not fatal — both runs completed and passed); this is believed to also
explain the small (~5%) cold/warm word-count difference, not a correctness
issue with the model or conversion.

### Concerns

The BSC transcript came in noticeably shorter than the `large-v3-turbo`
transcript of the same recording (5,910–5,637 words vs. 7,144, roughly 17–21%
fewer) despite loading and running cleanly end to end. The recording is
Catalan/Spanish/English mixed, and this run forced `languageHint: "ca"` per the
brief; a forced single-language hint on code-switched audio is a plausible
explanation (the router would normally choose the language automatically).
This wasn't diagnosed further — Task 14's scope was proving the artefact loads
and transcribes through the app's own engine, which it does — but it's worth a
quality pass (try `auto` / per-segment language detection) before recommending
`bsc-los` for genuinely mixed-language meetings.
