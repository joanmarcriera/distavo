# #1793: should `summarise.embedded_enabled` default to true? Evidence and recommendation

Prepared 2026-11-09 by the distavo-next drive lane (branch `feat/drive-distavo-k-2026-11-09`). The flag is **not** flipped.
Task: https://familia.riera.co.uk/tasks/1793 . Background: `docs/embedded-summarisation-decision.md`.

## What the task asked and where each item stands

| Defect from the 97-minute field test (#1781) | State on this branch | Evidence |
|---|---|---|
| Every action row stamped "Post-engagement / not yet active" | Tuned: the map prompt says it is rare, not the default; the shared template rule is pinned | commits 70b0d12, 01290ff; `EmbeddedSummaryPrompt.mapInstructions` |
| "Possible transcription corrections" lists verbatim quotes | Mitigated by code, not by prompt: `LedgerVerifier` drops ledger rows whose quote is not in the transcript, `[unverified]` marks the rest; corrections never rewrite the owner's typed Highlights (ced0a0a) | `LedgerVerifierTests`, `SummaryChecks.apply` |
| Speaker labels drift (`SPEAKER_00` vs "Speaker 00"), repeated sections | Label repair after the model (938a6a5); repetition handled by the collapse guard + retry + chunked third attempt (#4011, 1142a9d) | `SummaryValidator`, `PipelineTests` |
| Re-run the live harness after each change | **Not run in this lane**: it needs a real recording, Apple Intelligence on a macOS 26 Mac and minutes of transcription (`EmbeddedPipelineLiveTests`, `DISTAVO_PIPELINE_LIVE=1`) | gated |

## Why the default should stay `false`

1. **Catalan is the product's differentiator** (decided 2026-09-10) and Apple's on-device model does not do Catalan. A default-on
   embedded summariser would route Catalan/Spanish meetings to the weaker path on exactly the machines Distavo targets.
2. **4096-token context** (input + output, measured). Long meetings go through map-reduce; quality evidence is one 97-minute English meeting.
   The task itself asks for 2-3 more shapes (short call, multi-speaker, non-English) before defaulting on, and none exists yet.
3. **Migration rule** (CLAUDE.md): a config predating a key must decode to the old behaviour. So the flag cannot change for existing users anyway;
   the only candidate is `Config.recommendedForThisMac()` for fresh installs on macOS 26+.
4. **The richer on-device route already exists**: `summarise.embedded_model` (#2198, downloaded Gemma, GO on e4b incl. Catalan with a recipe)
   sits behind the same switch. Flipping the switch is really a decision about which embedded model a fresh install gets, not only Apple's.

## Recommendation

- Keep `embedded_enabled = false` by default and in `recommendedForThisMac()`.
- Surface it in Settings (as an explicit opt-in, with the English-first / no-Catalan wording) so nobody needs the config edit. This is the
  only part of the task worth doing now.
- Re-decide after one live pass on three recordings (short call, 3+ speakers, one Catalan) with the harness; record the numbers in
  `docs/embedded-summarisation-decision.md`.

## For Marc (needs a Mac with Apple Intelligence; not done unattended)

```
cd apple/DistavoCore && DISTAVO_PIPELINE_LIVE=1 DISTAVO_PIPELINE_AUDIO=<recording> DISTAVO_PIPELINE_OUT=<dir> DISTAVO_PIPELINE_OLLAMA=http://127.0.0.1:11434 swift test --filter EmbeddedPipelineLiveTests
```
