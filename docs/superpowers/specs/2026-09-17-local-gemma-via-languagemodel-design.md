# Local Gemma-class summaries via macOS 27's `LanguageModel` protocol

**Status:** research spec, not started — Vikunja #2198. **Date:** 2026-09-17.
**Task:** can Distavo get Gemma-class (8B+) summary quality on-device, without Ollama, once
customers are on macOS 27? This is a feasibility/design doc, not a build plan — nothing here ships
until macOS 27 has real install share.

**Machine this was verified on:** Marc's Mac is macOS 26.7. **Xcode 27.0 (build 27A266a) is
installed**, which ships the **macOS 27.0 SDK** (`xcrun --sdk macosx --show-sdk-path` →
`.../MacOSX27.0.sdk`), so the SDK's `.swiftinterface` could be inspected directly even though the
runtime cannot be exercised on this Mac yet. Where marketing/session summaries and the SDK
disagree, the SDK wins and is called out below.

## 1. The API surface, as verified from the SDK

Read directly from
`MacOSX27.0.sdk/System/Library/Frameworks/FoundationModels.framework/Versions/A/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`
(3,648 lines; no public headers, only this text interface — `FoundationModels.tbd` is a symbol
stub with no signatures).

### `LanguageModel` — the model side (macOS 27+ only)

```swift
public protocol LanguageModel : Swift.Sendable {
    associatedtype Executor: LanguageModelExecutor where Self == Self.Executor.Model
    var capabilities: LanguageModelCapabilities { get }
    var executorConfiguration: Self.Executor.Configuration { get }
}
```

`SystemLanguageModel` (the on-device 3B Apple already uses) and the new
`PrivateCloudComputeLanguageModel` both gained conformance to this protocol **only under
`@available(macOS 27.0, *)`** — on macOS 26 they exist but do not conform to `LanguageModel`, so
a 26-only build cannot even reference the protocol against them.

### `LanguageModelExecutor` — the runner side (what a "provider" implements)

```swift
public protocol LanguageModelExecutor : Swift.Sendable {
    associatedtype Configuration: Hashable, Sendable
    associatedtype Model: LanguageModel
    init(configuration: Configuration) throws
    func prewarm(model: Model, transcript: Transcript)
    func respond(to request: LanguageModelExecutorGenerationRequest, model: Model,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws
}
```

`prewarm` loads weights ahead of the first request; `respond` converts `Transcript` entries to the
model's native format, applies `GenerationOptions`/`ContextOptions`, and streams
`LanguageModelExecutorGenerationChannel.Event`s (metadata → usage → text deltas) rather than
returning a single value — this is the actual streaming mechanism, one level below the
`streamResponse(to:)` AsyncSequence API apps normally call.

### Creating a session with a custom model

```swift
@available(macOS 27.0, *)
convenience public init(model: some LanguageModel, tools: [any Tool] = [],
                         instructions: Instructions? = nil)
// + overloads taking a transcript, a string, or an @InstructionsBuilder closure
```

This is a **generic entry point on the existing `LanguageModelSession` class** — not a new session
type. Any type conforming to `LanguageModel` can be passed where `SystemLanguageModel` used to be
hardcoded. **This constructor and everything else `some LanguageModel`-generic is `@available(macOS
27, *)` — the macOS 26 overloads only accept `SystemLanguageModel` by name.** This is the load-bearing
fact for gating (§6).

### Streaming, context, tokens

- `session.streamResponse(to:options:)` returns `ResponseStream<String>` (or `<GeneratedContent>`/
  `<Content: Generable>` for schema'd output) — same shape Distavo would call regardless of which
  `LanguageModel` backs the session.
- `GenerationOptions(temperature:maximumResponseTokens:...)` — unchanged from the macOS 26 API
  Distavo already uses in `EmbeddedSummariser.generate`.
- **Context size, corrected vs. marketing:** the WWDC26-session summary claims "on-device model:
  8,192 tokens", but the SDK itself says otherwise —
  `SystemLanguageModel.contextSize` is `@backDeployed`: on macOS 27+ it returns the real
  `_contextSize`; **the shipped fallback value in the interface itself, used pre-27, is literally
  `4096`** (`docs/embedded-summarisation-decision.md`'s own field measurement). So on macOS 27 the
  built-in model's context probably *does* grow (Apple's own `Variant.core3` /
  `.coreAdvanced3` suggests bigger on-device tiers exist), but the exact number could not be
  measured on this Mac (macOS 26.7) — **treat "8192" as unverified, not the design constant.** A
  custom `LanguageModelExecutor` (Gemma via MLX/Core AI) reports its **own** context via
  `LanguageModelCapabilities`/its executor, independent of `SystemLanguageModel.contextSize`
  entirely — see §4.
- `SystemLanguageModel.tokenCount(for:)` (macOS 26.4+) has no equivalent guaranteed for third-party
  executors; each provider decides whether to expose one.

### Sources
- SDK: `xcrun --sdk macosx --show-sdk-path` → `MacOSX27.0.sdk`, grepped directly (see paths above).
- [What's new in the Foundation Models framework — WWDC26 (session 241)](https://developer.apple.com/videos/play/wwdc2026/241/)
- [Bring an LLM provider to the Foundation Models framework — WWDC26 (session 339)](https://developer.apple.com/videos/play/wwdc2026/339/)
- [Integrate on-device AI models into your app using Core AI — WWDC26 (session 326)](https://developer.apple.com/videos/play/wwdc2026/326/)

## 2. Which runner fits Distavo — MLX vs. Core AI

Apple is **open-sourcing two conforming `LanguageModel` implementations**, not shipping them inside
`FoundationModels.framework` itself (confirmed: no `MLX`/`CoreAI` symbol appears anywhere in the
macOS 27 SDK's `FoundationModels.swiftinterface` — they are separate SwiftPM packages you add).

| | **MLXLanguageModel** | **CoreAILanguageModel** |
|---|---|---|
| Package | `ml-explore/mlx-swift-lm`, target `MLXFoundationModels` (trait `FoundationModelsIntegration`, on by default) | `apple/coreai-models` (BSD-3) + the `CoreAIKit`-style runtime it exports |
| Compute | Mac **GPU** via Metal (MLX) | **Apple Neural Engine** (ANE) |
| Model format | **MLX-quantized safetensors** — anything under `mlx-community/*` on Hugging Face, loaded by `modelID:` string | **`.aimodel`** bundles — PyTorch → Apple's `coreai-torch` export (`coreai.llm.export`) → a resource folder (`.aimodel` + tokenizer), loaded by `CoreAILanguageModel(resourcesAt: folderURL)` |
| Constructor | `MLXLanguageModel(modelID: "mlx-community/gemma-4-e4b-it-4bit")` | `try await CoreAILanguageModel(resourcesAt: modelURL)` |
| Who converts weights | The MLX community (mlx-community org already publishes Gemma 4 in MLX 4-bit) | Apple/the recipe author, via `coreai-models`' export recipes — Distavo would need Gemma exported through that recipe (not yet confirmed present in `apple/coreai-models/models`; the fetch of that repo did not enumerate which models beyond the reference set (SAM3, Qwen, Mistral) already have recipes) |
| Fits Distavo's existing pattern | **Yes** — same shape as `EmbeddedModelStore` (Hugging-Face-hosted repo, downloaded model ID, no separate conversion step Distavo owns) | Requires Distavo to either wait for an official Gemma `.aimodel` recipe or run the export itself, closer to the Catalan WhisperKit conversion work (`distavo-whisperkit-model-conversion` memory) — a similar-shaped but separate ownership burden |

**Recommendation: MLX first.** It reuses the *deployment* pattern Distavo already has for WhisperKit
(download a named Hugging Face repo into `EmbeddedModelStore`'s directory) and needs no export step
Distavo would own — mlx-community already publishes Gemma 4 in MLX quantization. Core AI's ANE
path is worth revisiting once/if Apple (or the community) ships a Gemma `.aimodel` recipe, since ANE
inference is more power-efficient than GPU for a battery-powered Mac laptop doing a long map-reduce
run, but it is not the pragmatic first move.

### Sources
- [ml-explore/mlx-swift-lm — `Libraries/MLXFoundationModels/README.md`](https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXFoundationModels/README.md)
- [apple/coreai-models](https://github.com/apple/coreai-models)
- [Core AI — Apple Developer](https://developer.apple.com/core-ai/)

## 3. Licensing — Gemma vs. an open fallback

**Gemma 4 (released April 2026) is Apache 2.0**, not the older, more restrictive "Gemma Terms of
Use" that governed Gemma 1–3 (source-available, redistribution-restricted). Apache 2.0 permits
commercial use, modification, redistribution, and sublicensing without a separate agreement with
Google, and imposes no usage-reporting or revenue-share obligation. **This clears Marc's rule (no
fees, no licence forbidding commercial use) outright** — a paid Distavo edition bundling or
downloading Gemma 4 weights is licence-clean.

The MLX-quantized re-publications under `mlx-community/gemma-4-*` inherit Apache 2.0 from the base
weights (MLX-community does not relicense; it only requantizes).

**No alternative is needed on licensing grounds** — this reverses the assumption in the task prompt
that Gemma might be a licensing problem. (If Google ever tightens Gemma 5's terms, **Qwen** — used
as Apple's own Core AI reference model at WWDC26 — is Apache 2.0 and already has both MLX and Core
AI recipes, making it the natural fallback with zero new integration work.)

### Sources
- [Gemma Terms of Use — Google AI for Developers](https://ai.google.dev/gemma/terms)
- [Google Releases Gemma 4 in Four Model Sizes Under Apache 2.0 License](https://www.ghacks.net/2026/04/06/google-releases-gemma-4-in-four-model-sizes-under-apache-2-0-license/)

## 4. Where it plugs into the existing seams

Nothing about the pipeline shape changes; only what fills the `.embedded` slot does.

- **`PipelineDeps.summarise`** (`Pipeline.swift`) is already backend-agnostic — it takes a
  `SummariseTarget` (`.ollama(url:model:)` / `.embedded`) and a closure. A Gemma-via-MLX engine
  is a **third case an `AppPipelineDeps`-level engine picker chooses between**, not a new seam:
  either extend `SummariseTarget` with `.embeddedGemma` (explicit engine selection, mirrors how
  `TranscribeConfig.embeddedModel` already picks among WhisperKit/Parakeet entries) or keep
  `.embedded` and add a `summarise.embeddedModel` config key analogous to `transcribe.embeddedModel`
  — the latter fits Distavo's existing naming better.
- **`SummariseConfig.backend`** (`Config.swift`) needs no new value — `"embedded"` already exists;
  what changes is which *model* the embedded path uses. Precedent: `TranscribeConfig` already
  separates `backend` (`"server"`/`"local"`/`"embedded"`) from `embeddedModel` (which catalog entry).
  Summarisation should gain the same split.
- **`chooseSummariser`/`EmbeddedReadiness`** (`Pipeline.swift`): the existing three-case enum
  (`.ready` / `.temporarilyUnavailable` / `.unsupported`) already covers this cleanly — a Gemma
  engine that hasn't finished downloading its weights is `.temporarilyUnavailable("downloading
  model")`; a macOS 26 Mac, or an Intel Mac with no GPU/ANE path, is `.unsupported("needs macOS 27")`
  — **no new enum needed**, only a new source of readiness (download state) feeding it, which is new
  territory: `EmbeddedReadiness` today only distinguishes OS/hardware support and Apple Intelligence
  state, not "weights not yet downloaded". `EmbeddedModelStore` already models exactly this for
  WhisperKit (`isDownloaded`, download progress) — that pattern is what a Gemma model entry reuses.
- **The 4096-token map-reduce in `EmbeddedSummary.swift` vs. a Gemma model's real context:** this is
  the single biggest simplification a Gemma backend buys. `EmbeddedSummaryBudget`/`EmbeddedSummaryPlanner`
  are written generically against a `contextSize: Int` parameter already — they do not hardcode 4096
  anywhere; `EmbeddedSummariser.swift` is what currently always passes
  `SystemLanguageModel.default.contextSize`. A Gemma-4-e4b or Gemma-4-12B MLX model run through
  `MLXLanguageModel` typically ships with **8K–32K native context** (Gemma's family context, not
  Apple's clamp) — pass that number into the *same* `EmbeddedSummaryPlanner.plan(...)` and most
  one-hour meetings become `.single`-pass instead of `.mapReduce`, with the map-reduce path kept only
  as a safety net for very long recordings. **No new chunking logic — only a different `contextSize`
  input and a different `generate()` implementation underneath `EmbeddedSummariser`.**
- `Prompt.build` / `SummaryValidator` are untouched either way — this is the same "prompt/validator
  parity" property the original Foundation Models decision already leaned on.

## 5. Memory/download size and a minimum-Mac rule

Measured MLX 4-bit Gemma 4 quantizations on Hugging Face (`mlx-community`):

| Model | Disk (4-bit) | Notes |
|---|---|---|
| `gemma-4-e4b-it-4bit` | **5.15 GB** | "effective 4B" — Gemma's small/fast MoE-style tier |
| `gemma-4-12B-4bit` | **11 GB** | dense 12B |
| `gemma-4-26b-a4b-it-4bit` | 15.3 GB | MoE, 26B total/4B active |
| `gemma-4-31b-it-4bit` | 18.4 GB | dense 31B, top of the family |

For comparison, Distavo's existing 16 GB-floor BSC Catalan/Spanish WhisperKit packs are 3.1 GB
download / 4 GB RAM each (`EmbeddedSupport.swift`), and Ollama's current default `gemma4:26b` server
model is a similar weight class to the `26b-a4b` row above.

**Proposed rule, mirroring the existing WhisperKit floor exactly:** offer/auto-route only the
`e4b` tier (5.15 GB) below 16 GB physical RAM, if at all, and gate the `12B`+ tiers behind the
**same 16 GB `HardwareProbe.physicalMemoryGB` floor** `EmbeddedModel.minimumMemoryGB` already
enforces for transcription packs — reuse `HardwareProbe`, don't invent a second check. Running an
LLM *and* WhisperKit/Parakeet concurrently (transcribe → summarise pipeline stages don't overlap
today, but both hold model memory during their stage) means the real-world floor for a 12B-class
model is probably 24–32 GB, not 16 GB; that needs an actual RAM-pressure measurement on a 16 GB
Mac before shipping, not just a size table — same caveat the original Foundation Models decision
doc flagged for RAM ("Apple's, not ours").

## 6. What can be built now on 26.7 vs. what needs macOS 27

**Nothing runtime-facing can be built or tested today.** Concretely, on Marc's 26.7 Mac:

- `import FoundationModels` compiles today (framework exists since macOS 26), but every symbol
  this design depends on — `protocol LanguageModel`, `protocol LanguageModelExecutor`,
  `LanguageModelSession.init(model: some LanguageModel, ...)`, `MLXLanguageModel`,
  `CoreAILanguageModel` — is `@available(macOS 27.0, *)` **only**, so even a `#if canImport` guard
  (which only checks the framework, not its symbol availability) is insufficient; every call site
  needs `if #available(macOS 27, *)` at runtime, exactly like the existing `if #available(macOS
  26.4, *)` guard around `tokenCount(for:)` in today's `EmbeddedSummariser.generate`.
- Because the macOS 27 SDK is already installed (Xcode 27 present), **compile-time work can start
  now**: writing the `#if canImport(FoundationModels)` + `@available(macOS 27, *)` scaffolding, the
  `MLXFoundationModels` SwiftPM dependency wiring, and the `EmbeddedReadiness`/config-schema changes
  in §4 — all type-checkable against the SDK headers with zero runtime testing, the same way
  `distavo-test-without-xcode-licence` already runs `swift build`/type-check without a full Xcode
  licence.
- What **cannot** be verified pre-27: actual generation quality/latency, real context size for
  `SystemLanguageModel` (§1's "8192 vs 4096" discrepancy), MLX GPU memory pressure on a real 16 GB
  Mac, and whether `CoreAILanguageModel` needs a Gemma-specific export recipe that doesn't exist yet.
- **CI (`macos-latest` in `.github/workflows/ci.yml`)** runs whatever Xcode GitHub ships as default;
  as of today that is not Xcode 27, so a macOS-27-gated code path will simply not compile/run its
  `@available(macOS 27, *)` branches in CI until the runner image updates — the existing pattern
  (`EmbeddedTranscriber`/`EmbeddedSummariser`'s `#if canImport` + `@available` guards, tested via
  fakes in `DistavoCore` and skipped at the `DistavoEmbedded` layer when unavailable) already handles
  exactly this; no new CI infrastructure is needed, just eventual `macos-latest` image catch-up.

## 7. Task breakdown and estimates

| # | Task | Depends on | Estimate |
|---|---|---|---|
| 1 | Add `MLXFoundationModels` (mlx-swift-lm) as a `DistavoEmbedded` SwiftPM dependency; confirm it builds against the macOS 27 SDK with `#if canImport(FoundationModels)` scaffolding (no runtime use yet) | none — buildable today | 0.5 day |
| 2 | Extend `SummariseConfig` with an `embeddedModel` field (mirrors `TranscribeConfig.embeddedModel`) + a `Gemma`-shaped `EmbeddedModel`-style catalog entry (id, downloadMB, ramGB, minimumMemoryGB) | 1 | 0.5 day |
| 3 | `EmbeddedGemmaSummariser` in `DistavoEmbedded`: `@available(macOS 27, *)` wrapper constructing `MLXLanguageModel(modelID:)`, a `LanguageModelSession(model:)`, wired through the *existing* `EmbeddedSummaryPlanner`/`EmbeddedSummaryBudget` with the model's real context size in place of `SystemLanguageModel.default.contextSize` | 1, 2, §4 | 1.5 days |
| 4 | Download/readiness plumbing: reuse `EmbeddedModelStore`'s download-into-`~/Library/Application Support/Distavo/models` pattern for the MLX weights; feed download state into `EmbeddedReadiness.temporarilyUnavailable` | 2, 3 | 1 day |
| 5 | Settings UI: offer the Gemma engine only when `#available(macOS 27, *)` **and** `HardwareProbe` clears the RAM floor (§5) — same gating `Settings/` already does for WhisperKit packs | 2 | 0.5 day |
| 6 | `DistavoCoreTests`/`DistavoEmbeddedTests`: budget/planner tests already generic over `contextSize` need no changes; add fakes for the new readiness/config paths | 3, 4 | 0.5 day |
| 7 | Real-machine verification once macOS 27 + a 16 GB+ Apple Silicon Mac is available: field-test quality vs. Ollama `gemma4:26b` (repeat the existing A/B methodology from `docs/embedded-summarisation-decision.md`), measure actual RAM pressure during concurrent transcribe+summarise | 3–6, macOS 27 GA | 1 day (blocked until macOS 27 ships) |
| 8 | If Core AI turns out to have an official Gemma `.aimodel` recipe by then: repeat 3 as `EmbeddedGemmaCoreAISummariser` and A/B ANE vs. GPU power/latency | 7 | 1 day (optional, lower priority per §2) |

**Total: ~5.5 engineer-days of buildable-now work (1–6) + ~1–2 days of macOS-27-gated verification
(7–8) once the OS and a suitable test Mac exist.** Nothing here should start before macOS 27 has
meaningful install share among Distavo's users, per the "ship behind a flag, cheap to withdraw"
principle the original Foundation Models decision already established.
