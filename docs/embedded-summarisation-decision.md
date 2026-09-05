# Embedded summarisation: Apple Foundation Models vs llama.cpp

**Status:** decided — Apple Foundation Models, shipped behind a feature flag, **not** the default.
**Date:** 2026-09-05 · **Task:** Vikunja Distavo #336 (S3 follow-up)

## The problem

Distavo's transcription step no longer needs a server: the built-in WhisperKit engine
(`DistavoEmbedded`) removed the WhisperX install for Apple Silicon users. Summarisation is now the
**last remaining install requirement** — the user must run Ollama somewhere, either on this Mac
(`summarise.backend = "local"`) or on their network (`"server"`).

That is the onboarding cliff. "Download the app, then also install Ollama and pull an 8B model"
loses users who would otherwise have a working product in one step. The goal of this task is to
evaluate whether an in-app summariser can close it.

Hard constraint, unchanged: **there is no cloud path.** Real transcript content only ever goes to
the user's own machine or their own server. This is documented in `Config.swift` and is a product
promise, not a preference.

## Options considered

### A. Apple Foundation Models (on-device `SystemLanguageModel`)

Apple's ~3B on-device model, exposed via the `FoundationModels` framework (macOS 26+).

### B. llama.cpp embedded in-process

Bundle/download a GGUF (e.g. `llama3.1:8b` Q4_K_M) and run it in-process via llama.cpp with Metal.

### C. MLX Swift (noted, not chosen)

Named for completeness because it changes the calculus *if* the long-context route is ever taken:
it is Swift-native with a clean SwiftPM story, Metal-accelerated and MIT-licensed, so it dominates
raw llama.cpp on integration cost while carrying the same model-download and RAM costs. If B is
ever revisited, it should be revisited as MLX, not as llama.cpp.

## Measured evidence

Everything below was measured on this Mac (macOS 26.6.2, Xcode 26.6, SDK 26.5), not taken from
documentation:

| Measurement | Value |
|---|---|
| `SystemLanguageModel.default.availability` | `available` |
| `SystemLanguageModel.default.contextSize` | **4096 tokens** (input **and** output combined) |
| Distavo's existing prompt template, no transcript | **779 tokens** |
| Tokenizer density on that template | **4.10 chars/token** |
| Smoke test: 5-line transcript → full note | 883 input tokens, **10.9 s**, 2 873 chars out |

The smoke test output honoured the exact 16-section format, used British English, and invented no
speaker names — the prompt in `Prompt.swift` transfers to the 3B model essentially as-is.

**The budget, therefore:** 4096 − 779 (instructions) − ~700–1500 (a real note's output) leaves
roughly **1800–2600 tokens of transcript**, i.e. ~7 400–10 600 characters, i.e. **about 10–15
minutes of speech** in a single pass. A one-hour meeting is ~13 000 tokens — roughly **7× over
budget**. Anything longer than a short call needs map-reduce chunking.

For comparison, the current Ollama path runs at `num_ctx: 65536` with `num_predict: 6144` — two
orders of magnitude more headroom.

## Trade-offs

| | A — Foundation Models | B — llama.cpp |
|---|---|---|
| New dependency | none (system framework) | large C++ dep, no clean SwiftPM story |
| Disk / download | **zero** | ~4.7 GB, on top of the 632 MB Whisper model |
| RAM while summarising | Apple's, not ours | ~5–6 GB (tight on 8–16 GB Macs) |
| Context window | 4096 — needs map-reduce | 32k+ — single-shot, current pipeline shape |
| Output quality | 3B; good on the smoke test, weaker on long/complex meetings | 8B — *is* the current baseline |
| Prompt/validator parity | needs care; `SummaryValidator` may trip more often | exact parity (same model family) |
| macOS reach | **26+ only**, Apple Intelligence on, Apple Silicon | macOS 14+, all Apple Silicon |
| Licensing / App Store | clean (Apple's own framework) | MIT; GGUF weights are data — acceptable |
| Implementation cost | ~1 day | multi-week + permanent distribution ownership |
| Failure modes | guardrail refusals on candid transcripts | model/download/RAM support burden |

## Decision and rationale

**Ship A (Apple Foundation Models), behind `summarise.embedded_enabled`, defaulting off. Ollama
stays the default and the quality path.**

Four reasons, in order of weight:

1. **B's main benefit is already shipped.** A user who wants 8B-quality, long-context, fully local
   summarisation can install Ollama and point Distavo at `127.0.0.1` — that is a supported,
   working backend today. Embedding llama.cpp would re-implement an existing feature in-process,
   buying quality parity with what already exists while adding a 4.7 GB download, a C++
   dependency, and a permanent model-support burden. The marginal value is low.

2. **A buys something genuinely new: zero install.** No server, no Ollama, no model download, no
   disk cost. That is precisely the onboarding cliff described above, and nothing else on the
   table removes it. It is the natural completion of what the embedded transcriber started.

3. **The cost asymmetry is extreme.** A is a system framework and roughly a day's work; B is a
   multi-week integration Distavo would own forever. Behind a flag, A is cheap to ship *and cheap
   to withdraw* if the quality proves inadequate in the field.

4. **A's weaknesses are containable.** The 4096-token window is handled by map-reduce chunking;
   the 3B quality gap and guardrail-refusal risk are contained by keeping Ollama the default,
   keeping the feature opt-in, and surfacing clear errors rather than silently writing a bad note.

### What would reverse this

- Map-reduce output quality proving unacceptable on real meetings in field use.
- Guardrail refusals firing on ordinary candid work transcripts at a material rate.
- Apple keeping the on-device context at 4096 while an MLX 8B path becomes cheap to integrate.

In that case the successor is **C (MLX Swift)**, not llama.cpp.

### Explicitly rejected

**Private Cloud Compute.** The WWDC26 PCC model offers a 32 000-token window and would solve the
context problem outright. It is Apple's cloud. Distavo promises no cloud path for transcript
content, so PCC is off the table regardless of how private Apple's implementation is.

## How it is built

- **Feature flag** — `summarise.embedded_enabled` (JSON config, default `false`). It is a real kill
  switch: with the flag off, `backend = "embedded"` falls back to the Ollama path rather than
  failing, and the Settings UI does not offer the engine at all.
- **`DistavoCore` stays dependency-free.** The pure, testable parts live there — the
  `SummariseTarget` seam, token estimation, chunk planning, and the map/reduce prompts. No
  `import FoundationModels`.
- **`DistavoEmbedded` holds the engine**, `#if canImport(FoundationModels)` + `@available(macOS 26)`,
  with a per-call session lifetime so the menu-bar app holds no model state between meetings —
  matching `EmbeddedTranscriber`.
- **Deferral semantics preserved.** Only the Ollama path can produce `deferredNeedLocal`; the
  embedded path needs no network and never defers.

## Sources

- [Deep dive into the Foundation Models framework — WWDC25](https://developer.apple.com/videos/play/wwdc2025/301/)
- [What's new in the Foundation Models framework — WWDC26](https://developer.apple.com/videos/play/wwdc2026/241/)
- [`LanguageModelSession` — Apple Developer Documentation](https://developer.apple.com/documentation/foundationmodels/languagemodelsession)
- [InferenceError — Context Length Exceeded (Apple Developer Forums)](https://developer.apple.com/forums/thread/791026)
