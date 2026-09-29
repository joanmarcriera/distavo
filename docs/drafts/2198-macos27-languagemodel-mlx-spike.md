# DRAFT — #2198 Spike: Gemma-class summaries without Ollama via macOS 27 `LanguageModel` / MLX

**Status:** draft spike plan. No code touched. This note does not repeat the design spec; it turns it into a
time-boxed spike. Full API notes and sizing: `docs/superpowers/specs/2026-09-17-local-gemma-via-languagemodel-design.md`.
**Blocker (Vikunja reconcile 2026-09-24):** macOS 27 is not yet installed on Marc's dev Mac (macOS 26.7; Xcode 27.0 SDK is present).

## Goal
A summarise backend "On this Mac (Gemma)" that downloads weights once into Application Support (like the WhisperKit
models) and needs no Ollama install. Ollama stays for power users and macOS < 27. Private Cloud Compute stays excluded
(not local-first).

## What is known (repo/memory only)
- Today: Foundation Models summariser is macOS 26+, behind `summarise.embedded_enabled` (default false), context 4096
  measured (input + output), map-reduce chunking; Ollama is the quality path (`docs/embedded-summarisation-decision.md`).
- The decision doc already names MLX Swift as the successor if Foundation Models quality fails.
- Design spec, checked against the macOS 27.0 SDK swiftinterface in Xcode 27: `LanguageModel`, `LanguageModelExecutor`
  and `LanguageModelSession.init(model:)` exist but are `@available(macOS 27, *)` only; `SystemLanguageModel` conforms
  only on 27. The runners are separate open-source packages, not in the framework: `ml-explore/mlx-swift-lm`
  (`MLXLanguageModel`, GPU) and `apple/coreai-models` (`CoreAILanguageModel`, Neural Engine). Spec recommends MLX first.
- The "8,192-token on-device context" claim is marketing; the SDK fallback constant is still 4096. Unverified at runtime.
- Gemma 4 is Apache-2.0 (spec sec. 3); MLX 4-bit sizes: e4b 5.15 GB, 12B 11 GB, 26b-a4b 15.3 GB, 31b 18.4 GB.
- Seams that absorb it: `PipelineDeps.summarise`, `EmbeddedReadiness` (`.temporarilyUnavailable` = downloading),
  `EmbeddedModelStore`, and a budgeter already generic over `contextSize`. `Prompt.build`/`SummaryValidator` unchanged.
- Model-behaviour lessons to carry over: gemma4 needs `"think": false` (Vikunja #2666); on the 2026-07-23 Catalan transcript
  `gemma4:26b` collapsed into repetition twice under the classic prompt while `llama3.1:8b` was clean (bake-off run f);
  facts-first breaks llama (1.12 state); Foundation Models 3B was *more* faithful than llama3.1:8b on a 97-min meeting.
- Product constraints: 16 GB floor stays (decision 2026-09-16); no paid fees; `deploymentTarget` macOS 14 (`apple/project.yml`).

## Unknowns
1. `[VERIFY]` Whether `MLXLanguageModel` runs Gemma 4 correctly (chat template, `think` off, system prompt) through
   `LanguageModelSession`, and reports its own context size.
2. `[VERIFY]` Real RAM/time on a 16 GB Mac while nothing else is loaded; spec guesses 24-32 GB for 12B-class with
   WhisperKit resident. Which tier is the smallest that keeps the facts ledger honest (e4b vs 12B)?
3. `[VERIFY]` Catalan quality of Gemma 4 e4b/12B summaries (the differentiator audience). Not measured anywhere in the repo.
4. `[VERIFY]` mlx-swift-lm's Metal shader bundle and GPU use inside the App Store sandbox; App Review stance on
   downloaded model weights (WhisperKit precedent suggests fine; weights are data, not code).
5. `[VERIFY]` Any macOS 27 minimum-hardware/GPU rules for MLX; Intel Macs are already `.unsupported`.
6. `[VERIFY]` Whether `apple/coreai-models` has a Gemma recipe (spec could not enumerate); only matters for a later ANE pass.
7. `[VERIFY]` mlx-swift-lm licence (MIT per the MLX ecosystem, per decision doc) and NOTICES.md entry (`NoticesCoverageTests`).

## Spike plan — time-box: 2 working days, hard stop
**Day 0 (now, macOS 26.7 + Xcode 27 SDK, ~0.5 day, can start immediately):**
- Branch `spike/2198-mlx-gemma`. Add `MLXFoundationModels` to `DistavoEmbedded` only; scaffold
  `#if canImport(FoundationModels)` + `if #available(macOS 27, *)` so macOS 14 and 26 targets still build.
- Verify all editions still compile (`distavo-native-verify`), and that App Store/Setapp/Direct gates hold.
**Day 1 (macOS 27 Mac needed, ~1 day):**
- Run e4b and 12B through `MLXLanguageModel` with the facts-first prompt on the Catalan and English reference transcripts
  via `EmbeddedPipelineLiveTests`; baseline = `gemma4:26b` on Ollama with `think:false`.
- Measure peak RAM, tokens/s, wall time, cold download, on 16 GB (VM sized to 16 GB `[VERIFY]` GPU passthrough, or a real
  16 GB Mac) and on Marc's larger Mac. Record `contextSize` reported.
**Day 2 (~0.5 day):** score, write the go/no-go, list residual work; do not start the Settings UI.

## Acceptance criteria (spike passes if all hold)
- Both reference transcripts summarise end to end with validator clean and 16/16 sections; no repetition collapse.
- Rubric score (`score.py`, private) within one point of `gemma4:26b` on the English call; Catalan note judged usable by Marc.
- Facts ledger honest: no invented organisations (the check llama3.1:8b failed).
- Peak RAM fits the 16 GB floor with WhisperKit unloaded (stages do not overlap today) for the chosen tier.
- 60-min transcript summarises in < 5 min on a 16 GB Apple Silicon Mac `[VERIFY: target chosen by Marc]`.
- macOS 14/26 builds and CI unaffected; App Store build has no Sparkle/donate/sandbox regressions.

## Risks
- macOS 27 gating: feature invisible to macOS 14-26 users, the current base; keep Foundation Models 26 + Ollama as fallbacks.
- 16 GB floor: 12B at 11 GB plus system leaves little headroom; e4b may be the only viable tier there, with Catalan quality unknown.
- Gemma repetition collapse seen on `gemma4:26b`; may recur in MLX builds.
- App Store review/sandbox for GPU + large downloads; 5-15 GB downloads need clear UI and cancel/delete.
- Dependency weight and update burden (mlx-swift-lm); MLX is already the named successor, so lower regret than llama.cpp.
- Schedule: nothing runtime-verifiable until macOS 27 is installed; recommendation in the spec is to wait for install share.

## Decision after the spike
Go: implement spec tasks 2-6 (~4.5 days), ship behind a flag, default off. No-go: close #2198 and keep Ollama + Foundation Models.
