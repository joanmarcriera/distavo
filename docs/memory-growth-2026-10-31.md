# Memory growth: 9.6 GB after 3 days (Vikunja #4019)

Findings only, from reading the code (no Instruments run). Status 2026-10-31. Report: 9.6 GB resident, of which
about 8.5 GB `Malloc Small` (many small heap allocations that are never freed or never returned).

## What is ruled out

- **DistavoCore pipeline.** `PipelineFootprintTests` (gated, `DISTAVO_LIVE=1`, commit ce71eb9) runs
  `Pipeline.processOne` 30 times on 4000-segment synthetic transcripts with fake engines: `phys_footprint` stays
  at 17-18 MB. State, cleaner, validator and note assembly do not leak.
- **Loaded model weights.** `MLXGemmaGenerator.unload()` drops weights and calls `MLX.Memory.clearCache()` (cache limit
  256 MB); the Gemma path calls it in a `defer`. Parakeet calls `asr.cleanup()` on both success and error paths.
- **Unbounded app arrays.** `WatcherController.recentActivity` is capped at 12; `ProcessingQueue` keeps one row per file.

## Suspects, most likely first

1. **WhisperKit / SpeakerKit / language detector are created per call and never explicitly unloaded**
   (`EmbeddedTranscriber.transcribe`, `loadDiarization`, `LanguageDetector.detect`). The code relies on ARC when the
   local goes out of scope ("`whisper` goes out of scope here"). WhisperKit holds CoreML models, MLMultiArrays and a
   tokenizer; CoreML keeps compiled-model and ANE/GPU buffers in process-wide caches that outlive the Swift object, and
   reload per call means each meeting adds fresh allocations that the allocator keeps in small-block magazines
   (matches `Malloc Small`, which is not returned to the OS). Over 3 days of repeated scans and detector runs this
   accumulates. WhisperKit has `unloadModels()`; it is not called anywhere (`grep unloadModels` = 0 hits).
2. **Whole-file float arrays.** `AudioProcessor.loadAudioAsFloatArray` is called in `EmbeddedTranscriber`
   (hole recovery) and again in `loadDiarization`: a 1 h recording is about 230 MB of `Float` per copy, plus
   `HoleRecovery` slices and gain-normalised copies. Transient, but the allocator rarely hands the pages back.
3. **Repeated duration probes of unreadable files.** `WatcherController+Queue` calls
   `AudioConverter.durationSeconds` (an `AVAudioFile` open) for every pending file not yet `known`; a file that never
   becomes readable was retried on every scan and launch until the `.unreadable` terminal marker (#5283, 0bda941).
   Each failed AVFoundation open allocates small objects. Fixed in the branch, so re-measure before blaming it.
4. **Notes window refresh every 3 s** (`NotesModel.refresh` -> `NotesLibrary.scan`): 86,000 scans in 3 days if the
   window stays open. `NotesLibraryCache` is keyed per note and should be bounded by the note count; worth checking
   it drops entries for deleted notes.
5. **Detached `Task { await coordinator.noteDownload(...) }` from progress handlers** (Parakeet, Gemma download).
   Only during downloads; low risk.

## Proposed fix (smallest first)

1. After each use, call `whisper.unloadModels()` (and release SpeakerKit) in a `defer` inside
   `EmbeddedTranscriber.transcribe`, `loadDiarization` and `LanguageDetector.detect`; wrap each call in
   `autoreleasepool` so CoreML's Objective-C temporaries are freed per window.
2. Load the audio array once per recording and pass it to hole recovery and diarisation instead of re-reading.
3. Optional last resort for a menu-bar app: after N model runs or when `phys_footprint` after a run exceeds a
   threshold while idle, offer a clean restart between recordings (never during one).
4. Make `NotesLibraryCache` prune to the live note set after every scan, with a test.

## How to confirm (needs a human at the Mac)

- `leaks $(pgrep Distavo)` and `vmmap -summary $(pgrep Distavo)` before and after processing one 30 min fixture
  three times; with `MallocStackLogging=1` run `malloc_history` on a `Malloc Small` growth address.
- Instruments Allocations with "Mark Generation" between runs; growth surviving generations points at suspect 1.
- A gated live test like `PipelineFootprintTests` around `EmbeddedTranscriber.transcribe` with a short fixture,
  asserting footprint after run 5 vs run 30 (needs the models, so `DISTAVO_EMBEDDED_LIVE=1`).
