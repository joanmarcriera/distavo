# #2198 spike note: macOS 27 `LanguageModel` protocol and the Distavo summariser seam

Status: **docs only, no code** (drive 2026-10-24). Question: does the macOS 27 Foundation Models
`LanguageModel` protocol let Distavo drop its own Gemma/MLX plumbing, and where would it plug in?
Facts below marked **[SDK]** were read from the installed `MacOSX27.0.sdk`
(`FoundationModels.framework` `arm64e-apple-macos.swiftinterface`); marked **[unverified]** come from the task
text / WWDC26 session 241 and were not checked against code. Read with
`docs/embedded-summarisation-decision.md` (why Apple's 4096-token model is opt-in) and the 2198 branch notes
(Gemma already ships, Direct only, opt-in, via `MLXGemmaGenerator`).

## What the SDK exposes [SDK]

* `public protocol LanguageModel : Sendable` (macOS/iOS 27+): `associatedtype Executor: LanguageModelExecutor`,
  `var capabilities: LanguageModelCapabilities`, `var executorConfiguration: Executor.Configuration`.
* `public protocol LanguageModelExecutor : Sendable`: `init(configuration:) throws`,
  `prewarm(model:transcript:)`, and `respond(to: LanguageModelExecutorGenerationRequest, model:, streamingInto:
  LanguageModelExecutorGenerationChannel)`. The request carries the `Transcript`, tool definitions, an optional
  `GenerationSchema`, `GenerationOptions` and `ContextOptions`; output goes back through the channel as
  appended/replaced text segments with token counts.
* `LanguageModelSession.init(model: some LanguageModel, tools:, instructions:)` exists, so a session can be backed
  by **any** conforming model, not only `SystemLanguageModel`. Errors include `contextSizeExceeded` carrying
  `contextSize` and `tokenCount`. `SystemLanguageModel` and `PrivateCloudComputeLanguageModel` expose `contextSize`
  and `tokenCount(for:)`.
* `MLXLanguageModel` / `CoreAILanguageModel` are **not** in the framework (zero "MLX" hits in the interface).
  The task says Apple ships them as open-source runners **[unverified]**: they would be a SwiftPM dependency, so
  the package, licence (`NOTICES.md`) and weight format must be checked before any adoption.

## Today's seam in Distavo

| Layer | Piece | Role |
|---|---|---|
| DistavoCore | `PipelineDeps.summarise(transcript, target, options, context) async throws -> String` | the only call the pipeline makes; dependency-free |
| DistavoCore | `chooseSummariser` -> `SummariserChoice` (`.use` / `.deferred` / `.unavailable`), `EmbeddedReadiness`, `EmbeddedSummaryModelCatalog` | defer-never-fail rule for absent dependencies |
| DistavoCore | `EmbeddedSummary.chunkTranscript`, `Prompt.build` | token budgeting, map-reduce, the prompt (identical across backends) |
| DistavoEmbedded | `EmbeddedSummariser.summarise` (Apple model) and `complete(prompt:maxOutputTokens:)` | wraps `LanguageModelSession` behind `#if canImport(FoundationModels)` |
| DistavoEmbedded | `GemmaSummaryModel` (download, manifest check, readiness) + `MLXGemmaGenerator.generate(prompt, maxOutputTokens)` | MLX Gemma on the GPU, recipe: thinking off, temperature 0.3-0.5, loop guard + one retry |

The seam is deliberately **text in, text out**: `Prompt.build` produces one string, a generator returns one string.
That is also what makes it a good fit for the protocol: the protocol is a richer transport (Transcript, tools,
schemas, streaming), and Distavo uses none of that.

## Mapping

1. **Do not replace the seam; add a provider behind it.** `MLXGemmaGenerator` already satisfies "generate a
   string from a prompt". A `LanguageModel`-based provider would be a second implementation of the same
   `generate(prompt, maxOutputTokens)` shape: build a `LanguageModelSession(model: someLanguageModel)`, send the
   prompt, return `response.content`. Everything above it (chunking, facts-first prompt, validators,
   `LedgerVerifier`, footer) is unchanged.
2. **Capabilities replace our hard-coded budgets.** `SystemLanguageModel` reports `contextSize`; for a conforming
   third-party model, `tokenCount(for:)` and `contextSizeExceeded` would drive `EmbeddedSummary` budgeting instead
   of the constant 4096. Our `tokenCount(_:) -> Int? { nil }` stub in `MLXGemmaGenerator` is the existing hook.
3. **Availability stays ours.** The protocol has no "weights downloaded and verified" notion. `GemmaSummaryModel`
   (download, manifest, `.distavo-verified`, exclusive lock) and `SummaryModelReadiness` keep deciding defer
   versus fail. A `LanguageModel` provider is only constructed once readiness says `.ready`.
4. **Edition and OS gating.** Any use is `#if canImport(FoundationModels)` plus `@available(macOS 27.0, *)`; below
   27 the existing mlx-swift-lm path continues to serve macOS 14+ (that is the deployment floor). The App Store
   build is unaffected until the Metal-in-sandbox question from the 2198 spike is answered on a signed build.
5. **Settings and defaults.** No new user-facing key is needed to ship the spike; `summarise.embedded_enabled`
   stays false and nothing flips it. If a second Gemma backend were added it must decode to off for old configs.

## Options

* **A. Stay on mlx-swift-lm (today).** Works on macOS 14+, already verified headless. Cost: we own the tokenizer
  bridge, chat template and loop guard.
* **B. `LanguageModel` conformer around the same MLX runner (own executor).** Gains the session API (streaming,
  `contextSizeExceeded`, tool calling for free) but adds macOS 27-only code beside A for no new capability we use.
* **C. Apple's `MLXLanguageModel` package [unverified].** Removes the bridge code if its model format matches the
  weights we already host (`Joanmarcriera/distavo-whisperkit-coreml` style mirror), at the price of a new
  dependency and macOS 27 as the floor for that path.

**Recommendation:** keep A as the default and do nothing to the pipeline. Re-evaluate C only after macOS 27 is the
majority of installs, and then as an additive provider behind `PipelineDeps.summarise`. B has no benefit by itself.

## Open checks (all need a Mac on macOS 27 with the model weights; none done here)

1. Does `MLXLanguageModel` exist as a public SwiftPM product, under which licence, and which weight format?
2. Does a session over it keep the facts-first quality (score.py rubric) on the Catalan and English reference
   transcripts, with thinking off and temperature 0.3-0.5? Use synthetic or Marc's own recordings only.
3. Peak memory and time on 16 GB and 24 GB Macs versus gemma4:26b on Ollama.
4. Metal under the App Store sandbox on a signed build (carried over from the 2198 spike).

Gate for Marc: items 2-4 need a signed or at least locally run macOS 27 build and Marc's reference transcripts; they
are not doable unattended.
