# DRAFT — #1793 Tune the on-device summary prompt, then decide on flipping `summarise.embedded_enabled`

**Status:** draft plan. No code touched. Marc's rule (2026-09-16): ship disabled behind the Settings toggle; flip the
default to true only after a few macOS point releases. This plan defines *what evidence* makes the flip a yes.

## Where things stand (from repo/memory/Vikunja)
- On-device = Apple Foundation Models 3B, context 4096 tokens (input + output), macOS 26+, Apple Silicon, Apple Intelligence on.
  Map-reduce via `EmbeddedSummary.chunkTranscript()`; map prompt `EmbeddedSummaryPrompt.mapInstructions`, reduce = `Prompt.build`.
- Field test on a 97-min meeting: 16/16 sections, 6 actions, validator clean, 73 s in 4 chunks, no invented organisation
  (llama3.1:8b invented one). Defects then: blanket "Post-engagement / not yet active" stamp; corrections section holding
  verbatim quotes; speaker-label drift; repeated sections.
- Tuning pass already done (commit 70b0d12): stamp fixed (0/2 on a 36-min call), corrections mostly fixed (8 raw quotes -> 1
  proper `heard "X", probably "Y"`), repetition fixed. **Speaker-label drift only partly fixed** (model renormalises
  `SPEAKER_00` to `Speaker_00` in prose) — suggested cheap post-process instead of more prompting.
- `Prompt.swift` is shared with Ollama; tune the map prompt or branch, do not change the shared template blindly.
- Still open: the flip decision and 2-3 more meeting shapes (short call, multi-speaker, non-English) — never attempted.
- Model can refuse or raise `GenerationError` (`guardrailViolation`, `refusal`, `unsupportedLanguageOrLocale`,
  `exceededContextWindowSize`). Catalan is not in `SystemLanguageModel.supportedLanguages` (23) and Apple Intelligence
  cannot be enabled on a Catalan-language Mac; yet the 2026-09-10 bake-off summarised a Catalan-transcript note fine
  (12/16 sections). Behaviour on Spanish/Catalan input is therefore a `[VERIFY]` risk, not a settled fact.

## Test corpus (private recordings stay out of git; commit only scores and counts)
| # | Shape | Source | Why |
|---|---|---|---|
| 1 | Scripted 60 s call with tick list | `docs/testing/test-meeting-script.md` (Marc records once) | Deterministic facts; the go/no-go Marc named |
| 2 | Recruiter/contract call, ~36 min | on-disk recording used in the 70b0d12 pass | Deadlines, rates, orgs |
| 3 | Long meeting, ~93-97 min | on-disk recording (original #1781 file is gone) | Map-reduce stress |
| 4 | English call, 21 min (2026-09-09) | bake-off e; `score.py` 14 checks | Existing rubric |
| 5 | Catalan/Spanish/English mix, 64 min (2026-07-23) | bake-off b transcript (bsc-los, ca) | Differentiator audience, non-English `[VERIFY]` |
| 6 | Multi-speaker (4+) meeting, 30-45 min | Marc to pick, or a CC recording | Speaker labels, attribution |
| 7 | Very short call, 2-5 min | any | Single-pass, min-length paths |
Regenerated reference notes exist under `~/Documents/Distavo/notes/review-1.11-catalan/` (note-embedded, note-ollama,
note-gemma4-26b-facts-first, note-llama3.1-8b-classic + transcript) for read-through.

## Metrics (per note; scripted where possible)
- Structural: sections present/16, substantive sections, action-row count, `SummaryValidator` result, repetition score.
- Fact fidelity: `score.py`-style tick list (corpus 1 and 4); invented entities (manual count); numbers/dates verbatim.
- Known defects as regexes: `Post-engagement` stamp count; corrections section lines lacking `heard "..."`; count of
  `Speaker_\d`/`Speaker \d` vs `SPEAKER_\d`; near-duplicate sections.
- Reliability: refusals/guardrail errors, `exceededContextWindowSize`, deferred/failed statuses, over N runs.
- Cost: wall time, chunk count, peak RAM (Activity Monitor), time per audio minute.
- Human: Marc's 1-5 read of two randomly ordered notes per recording (on-device vs Ollama), blind.

## Method (reuse the 2026-09-10 bake-off)
1. Cache transcripts once (harness `transcribe_seconds=cached`); iterate the prompt only: `DISTAVO_PIPELINE_LIVE=1
   DISTAVO_PIPELINE_AUDIO=... DISTAVO_PIPELINE_OUT=... DISTAVO_PIPELINE_OLLAMA=http://127.0.0.1:11434 swift test
   --filter EmbeddedPipelineLiveTests` (~70 s per run).
2. Arms: (A) on-device current prompt; (B) on-device tuned prompt; (C) Ollama `gemma4:26b` facts-first with `think:false`
   (1.12 default); (D) `llama3.1:8b` classic. Same transcript for every arm.
3. Score with the rubric above; record counts and timings only in the repo (as `2026-09-10-bakeoff-results.md` does);
   raw notes stay in scratch. Re-run each arm 2-3 times on corpus 3 and 5 to catch nondeterminism (gemma collapsed twice).
4. Change one thing per iteration; stop after 3 iterations per defect or on no gain (escalate rather than thrash).

## Tuning steps
1. Baseline arms A/C/D on corpus 1-7 (no prompt change) — establishes where 70b0d12 already helped.
2. Speaker labels: add a deterministic post-process normaliser (`Speaker_00`/`Speaker 00` -> `SPEAKER_00`) in DistavoCore
   with unit tests, rather than more prompt rules.
3. Any residual defect from the metrics list: adjust `mapInstructions` or branch the reduce prompt for the embedded path.
4. Non-English input: test Spanish/Catalan transcripts; if `unsupportedLanguageOrLocale`/refusals appear, decide to
   route those to Ollama or show an explicit message (never a silent bad note).
5. Re-run full matrix; write results as a counts-only doc next to the bake-off results.

## Decision criteria for flipping the default (all required)
- Corpus 1: every tick-list fact present, none invented; corpus 4: >= 13/14.
- Zero invented organisations, zero blanket deadline stamps, corrections section correct or empty across all 7.
- Validator clean and 16/16 sections on >= 6 of 7; zero unexplained refusals/context overflows in the matrix.
- Blind read: Marc rates on-device >= Ollama `llama3.1:8b` on at least 4 of 7; Catalan/Spanish handled safely (route or message).
- Calendar gate from Marc: a few macOS point releases since 26.x without new regressions; recheck the 4096 context measure.
- If it fails: keep default false; the successor is the macOS 27 MLX/Gemma route (#2198), not more prompting.
- If it passes: flip default true for fresh installs only (config migration rule: pre-existing configs keep their value),
  then decide whether to surface the toggle without the config edit (currently the Settings toggle already exists).

## Effort estimate
Corpus + script for metrics: 0.5 day. Baseline + iterations: 1 day. Post-process normaliser + tests: 0.5 day.
Non-English handling + write-up: 0.5 day. Marc's recording and blind read: ~1 hour each. Total ~2.5 days plus Marc's hours.

## Needs Marc
Record the scripted meeting on the on-device path; choose the multi-speaker recording; do the blind read; set the point-release gate.
