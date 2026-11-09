# Quality check for #3934 on synthetic fixtures (drive 2026-11-09-1308, lane distavo-q)

The 21 Oct recordings behind https://familia.riera.co.uk/tasks/3934 are third-party calls: they stay local and were
not opened. The failure classes in the task were reproduced on an invented panel (made-up people, company and tools)
in `SyntheticQualityFixtureTests` (6 tests, 0 failures). These are characterisation tests of existing checks, so they
passed on first run; nothing was red.

| Class in the task | Deterministic check today | Result on the synthetic panel |
|---|---|---|
| Invented skill in the facts ledger | `LedgerVerifier` (a): quote must be in the transcript | caught, row removed |
| Quote said by the interviewer, ledger blames the owner | `LedgerVerifier` (d): speaker corrected from the turn | caught, corrected |
| Wrong figure (35 vs 53) | `LedgerVerifier` (c) | caught, row removed |
| Vocabulary mis-heard ("MVL seventy two" for the product name) | `transcribe.replacements` rules | works when the user lists the pair; no fuzzy repair |
| Skill claimed when the speaker said "No, never" | none | **gap**: quote and key tokens are real, negation is not read |
| Language drift inside one turn ("skift kvaring ... Amerikan") | none | **gap**: the cleaner never judges a word's language |
| Role "not stated", questions given to the wrong person, invented next steps and owner (narrative prose) | none; `LedgerVerifier` touches only the ledger | **gap**: needs a model or a human; see below |
| Diarisation at turn boundaries | `SpeakerAlignmentRepair`, `TurnRepair` (1.19) | out of scope here: needs audio |

## Suggestions (not built; each needs a decision or audio)
1. Negation: a ledger row whose quote contains a negator ("no", "never", "not") within three tokens before the fact's key
   token could be marked `[unverified]` instead of kept. Cheap and conservative, English only; the risk is flagging true rows.
2. Drift: flag (do not rewrite) a turn when a re-decode with the language forced differs by more than 15% of tokens;
   reuse `HoleRecovery`. Needs audio and a model, so it belongs in `DistavoEmbedded`.
3. Narrative claims: the summary check that fits is a second pass that lists every "he/she/Marc did X" sentence with a
   transcript quote, then runs `LedgerVerifier` over those rows. That is a prompt change and a bake-off (CLAUDE.md:
   the unset prompt must stay byte-identical), so it is Marc's call.
4. Debrief calls summarised with the interview template: `TemplateAutoPick` exists (#3582) and picks from participants and the
   start of the transcript; the 7-minute recruiter debrief is a case for its test set when a synthetic one is written.
