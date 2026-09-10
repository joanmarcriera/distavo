# 1.11 engine bake-off results (2026-09-10)

Spec §8: "Catalan summary quality is the go/no-go" before tagging 1.11.0. Five live runs through
`EmbeddedPipelineLiveTests` (Task 14's harness, extended in Task 16 to dispatch on `model.engine`
so it can also drive `ParakeetTranscriber` — see the diff to
`apple/DistavoEmbedded/Tests/DistavoEmbeddedTests/EmbeddedPipelineLiveTests.swift`). Ollama
(`gemma4:26b` at `http://127.0.0.1:11434`) produced the summaries scored below; the on-device
Foundation Models summariser ran too as a harmless side effect of the harness (not scored here).

**No transcript or note text appears in this file** — only counts, timings and language-mix
percentages. The scratch outputs (never the repo) are named below for Marc's own read; they
include the raw notes and transcripts and should not be copied anywhere else.

## Runs

| Run | Recording | Model | Language | Engine | Wall-clock (full test) | Model load | Transcribe-only | Diarize | Word count | ANE/timeout warnings |
|---|---|---|---|---|---|---|---|---|---|---|
| a | 2026-07-23 (64 min) | large-v3-turbo | auto | whisperKit | 311.8 s | 4 s (warm) | 145 s | 14 s | 7,287 | 0 |
| b | 2026-07-23 (64 min) | bsc-los | ca | whisperKit | 576.9 s | 5 s (warm) | 367 s | 14 s | 5,970 | 61 |
| c | 2026-07-23 (64 min) | bsc-los | auto | whisperKit | 592.1 s | 5 s (warm) | 464 s | 13 s | 4,096 | 84 |
| d | 2026-09-09 (21 min) | parakeet-tdt-v3 | en | parakeet | 281.7 s | 190 s (**cold**, ~460 MB download + load) | 5 s | 2 s | 3,139 | 0 |
| e | 2026-09-09 (21 min) | large-v3-turbo | en | whisperKit | 158.8 s | 11 s (warm) | 48 s | 2 s | 2,756 | 0 |

Model state before each run: `large-v3-turbo` and `bsc-los` were already on disk (Task 14
downloaded `bsc-los`); `parakeet-tdt-v3` was not — run **d** is the first bake-off use of Parakeet
and downloaded it cold (`model_on_disk_before_run=false`). `openai_whisper-tiny` (the language
detector) was not exercised by this harness — the router's automatic-model path (Task 5/10), not
directly driven here.

**Transcript language mix** (`language-mix.py`, counts only):

| Run | Words | en | ca | es | mixed |
|---|---|---|---|---|---|
| a | 7,114 | 98% | 2% | 0% | 1% |
| b | 5,927 | 0% | 76% | 0% | 24% |
| c | 4,062 | 2% | 59% | 3% | 36% |
| d | 3,099 | 99% | 0% | 0% | 1% |
| e | 2,712 | 100% | 0% | 0% | 0% |

**Finding beyond Task 14's:** Task 14 found `language="en"` makes Whisper *translate* the
2026-07-23 meeting into 98% English. Run **a** used `DISTAVO_PIPELINE_LANGUAGE=auto`
(`languageHint: nil`, Whisper's own detection, not a forced translate) and is *still* 98% English
on a recording that is genuinely Catalan/Spanish/English — so large-v3-turbo's own language
auto-detection is not recovering the source language on this meeting either, not just the
`language="en"` misconfiguration. Runs **b** and **c** (bsc-los) both come out predominantly
Catalan, matching the meeting's real content — though their coverage of the meeting differs
substantially; see the transcript-coverage comparison below.

## English call: `score.py` (21-minute 2026-09-09 recording, checklist written for it)

| Run | Score | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| d-parakeet-en | 12/14 | ✓ | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| e-turbo-en | 14/14 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

Checks 1–14 as defined in `~/Documents/Distavo/work/bakeoff/score.py` (private, not in the repo).

`e` (large-v3-turbo, en) is a clean sweep (14/14). `d` (parakeet-tdt-v3, en) fails 2 of the 14
checks, one of them a hallucinated entity that isn't in the meeting — a real quality gap for
Parakeet's "Fast" engine on this call, worth a note in Settings/marketing copy that Fast trades
some accuracy for speed, but not a router-rule concern (Parakeet is opt-in, not the automatic
default for English — see `EngineRouter`).

## Catalan meeting checklist (2026-07-23, Ollama notes — `note-ollama.md`)

| Check | a (turbo, auto) | b (bsc-los, ca) | c (bsc-los, auto) | f (bsc-los, ca, llama3.1:8b) |
|---|---|---|---|---|
| Sections present | 16/16 | **1/16** | 16/16 | 16/16 |
| Sections substantive (non-empty, >40 chars, not "none"/"unclear") | 15/16 (Decisions made too thin) | **1/16** | 16/16 | 16/16 |
| Action items (table rows) | 3 | unusable | 3 | 1 |
| Named people/orgs (rough proxy: distinct capitalised sequences in that section, not an exact NER count) | 14 | unusable | 10 | 1 |
| Note language | English throughout | garbled (16 words, unclassifiable) | English throughout | English throughout |
| Transcription-corrections section non-empty | yes (475 chars) | **no** (section absent) | yes (266 chars) | yes (178 chars) |
| Obvious artefacts | none (validator clean) | **severe — reproducible repetition collapse** | none (validator clean) | none (validator clean) |

`f` re-summarises run **b**'s own transcript (same bsc-los+`ca` transcription, cached — no
re-transcribe) with the shipped default Ollama model, `llama3.1:8b`, instead of `gemma4:26b`
(`ollama_seconds=44`). See "Where b's problem actually is" below.

**Note on "note language":** every Ollama note comes out in English regardless of engine —
`Prompt.swift:25` hard-codes "Use British English", so this is by design, not a per-engine
difference. It does **not** discriminate between the runs; it's recorded because the brief asked
for it. What differs by engine is whether the *transcript* underneath the note is actually Catalan
(see the language-mix table above) — (a)'s transcript itself is a near-total English mismatch to
the recording; (b), (c) and (f, which reuses b's transcript) are not.

**Run b's Ollama failure (under `gemma4:26b`) is real and reproducible**, not a one-off: I re-ran
the summary step alone (transcript cached, no re-transcribe) and `gemma4:26b` degenerated into
repetition collapse both times — the harness's own validator caught both: a single short token
repeated 83× on the first run and 3,045× on the retry. The on-device Foundation Models summariser
handled the exact same bsc-los+ca transcript fine (12/16 sections, substantive,
`validator=clean`), and run **f** (below) shows the shipped default Ollama model handles it fine
too — so this is specific to `gemma4:26b` on this transcript+language-hint combination, not a
bsc-los transcription defect, not an Ollama-backend defect, and not the `ca` hint's fault.
**Scratch logs with both reproductions:** `.../scratchpad/bakeoff-16/b-bsclos-ca/run.log` (first)
and `.../b-bsclos-ca/run2.log` (retry); the first Ollama note is preserved at
`.../b-bsclos-ca/note-ollama.run1.md` before being overwritten by the retry's
`.../b-bsclos-ca/note-ollama.md`.

## Transcript coverage: b vs c

The router's real automatic path matters here: `EngineRouter` rules 3–4 set `languageHint = "ca"`
when Catalan is confidently detected, and `AppPipelineDeps` passes it straight to the engine — so
for a confidently-Catalan meeting like this one, the shipped Automatic path is **bsc-los + `ca`**
(run **b**), not bsc-los + `auto` (run **c**). An earlier draft of this file compared (c) against
(a) to justify keeping rule 4; that compared the wrong pair.

Controller-computed `difflib` comparison over the two transcripts (counts only, no transcript text
reproduced here):

- run **c** matched only **35%** of run **b**'s words.
- run **c** is missing **14 stretches of ≥60 consecutive words** present in run **b** (the largest
  missing stretch is 386 words).
- run **c** contains a **63-word run of one identical word repeated** (a hallucination loop); run
  **b**'s longest identical-word run is **4**.

Run **b**'s coverage of the meeting is therefore materially better than run **c**'s. Run **b**,
not run **c**, is the router's real path for a confidently-Catalan meeting.

## Where b's problem actually is

Run **b**'s transcript is the better one; its Ollama note collapsed under `gemma4:26b`
specifically, not under the shipped default. Foundation Models summarised the *same* b transcript
cleanly (12/16 sections substantive, `validator=clean`). Run **f** re-summarises that same
transcript with the shipped default, `llama3.1:8b` (present in Ollama on this Mac):

```
DISTAVO_PIPELINE_LIVE=1 DISTAVO_PIPELINE_MODEL=bsc-los DISTAVO_PIPELINE_LANGUAGE=ca \
  DISTAVO_PIPELINE_AUDIO="$HOME/Library/Application Support/Distavo/work/Meeting_2026-07-23_10.58.50.wav" \
  DISTAVO_PIPELINE_OUT=<scratch>/f-bsclos-ca-llama \
  DISTAVO_PIPELINE_OLLAMA=http://127.0.0.1:11434 DISTAVO_PIPELINE_OLLAMA_MODEL=llama3.1:8b \
  swift test --filter EmbeddedPipelineLiveTests
```

(transcript.txt copied in from run b's output dir first, so the harness's cache picked it up and
transcription did not re-run — `transcribe_seconds=cached`.)

```
METRIC transcribe_seconds=cached timestamps_present=cached
METRIC transcript_chars=30484 word_count=5970 est_tokens=10162 lines=86
METRIC plan=mapReduce chunks=4
METRIC embedded_seconds=70 chars=5157 sections=16/16 substantive=16 table_rows=0 validator=clean
METRIC ollama_seconds=44 chars=5084 sections=16/16 substantive=16 table_rows=1 validator=clean
```

`llama3.1:8b` produced a clean note on the exact transcript `gemma4:26b` collapsed on twice: 16/16
sections, all substantive, corrections section non-empty, validator clean, no repetition. This
confirms the collapse is a `gemma4:26b`-specific summariser problem, not an engine, transcript, or
`ca`-hint problem.

## Recommendation: **KEEP** rule 4 and its `ca` hint (`EngineRouter`)

Rule 4 ("any Catalan → Languages of Spain") and the `ca` language hint it sets both stay: run
**b** — the router's actual automatic path for a confidently-Catalan meeting — has materially
better transcript coverage than run (c) (see above), and (a) (large-v3-turbo, `auto`) remains 98%
English on a genuinely Catalan/Spanish/English recording regardless of language-hint setting. No
code change made — `EngineRouter` is untouched, per the brief.

The spec §8 go/no-go on the Catalan note is Marc's own read. Read run **b**'s transcript summarised
by:

- the shipped default Ollama model (run **f**, `llama3.1:8b`):
  `/private/tmp/claude-501/-Users-marc-Development-Project-distavo/c833a0dc-affd-4c63-a2fe-1976618dc11e/scratchpad/bakeoff-16/f-bsclos-ca-llama/note-ollama.md`
- the on-device Foundation Models summariser:
  `/private/tmp/claude-501/-Users-marc-Development-Project-distavo/c833a0dc-affd-4c63-a2fe-1976618dc11e/scratchpad/bakeoff-16/b-bsclos-ca/note-embedded.md`

Both are clean on the automated checks above; if Marc's own read of either still finds it lacking,
that is a summariser-quality question (slice 2 per spec §9's "Catalan/Spanish note templates"), not
an engine-routing one — `gemma4:26b`'s repeated collapse on this same transcript already shows the
Ollama **model choice**, not the transcription engine, is where a fix would belong if one turns out
to be needed.

**Other note files (absolute paths, scratch, never the repo), for reference:**

- (a) large-v3-turbo/auto: `/private/tmp/claude-501/-Users-marc-Development-Project-distavo/c833a0dc-affd-4c63-a2fe-1976618dc11e/scratchpad/bakeoff-16/a-turbo-auto/note-ollama.md`
- (b) bsc-los/ca under `gemma4:26b`: `/private/tmp/claude-501/-Users-marc-Development-Project-distavo/c833a0dc-affd-4c63-a2fe-1976618dc11e/scratchpad/bakeoff-16/b-bsclos-ca/note-ollama.md` (degenerate — see `note-ollama.run1.md` for the first reproduction)
- (c) bsc-los/auto: `/private/tmp/claude-501/-Users-marc-Development-Project-distavo/c833a0dc-affd-4c63-a2fe-1976618dc11e/scratchpad/bakeoff-16/c-bsclos-auto/note-ollama.md`
- (d) parakeet-tdt-v3/en: `/private/tmp/claude-501/-Users-marc-Development-Project-distavo/c833a0dc-affd-4c63-a2fe-1976618dc11e/scratchpad/bakeoff-16/d-parakeet-en/note-ollama.md`
- (e) large-v3-turbo/en: `/private/tmp/claude-501/-Users-marc-Development-Project-distavo/c833a0dc-affd-4c63-a2fe-1976618dc11e/scratchpad/bakeoff-16/e-turbo-en/note-ollama.md`

Also worth investigating before relying on `bsc-los` at scale, though not blocking this
recommendation: (b)'s and (c)'s transcripts carry far more `ANE op async execution has timed out`
warnings than the turbo runs (61 and 84 vs. 0).

This scratch directory is session-local and not guaranteed to persist — copy anything worth
keeping before it's cleaned up.

## Environment note

One background run of (b) was killed mid-build by the harness's own low-memory reaper (system had
~46 GB of its 48 GB physical memory in use, most of it a large unrelated `llama-server` process —
not touched). The retry succeeded cleanly; no Distavo code or model issue was involved. Flagging
in case (b)'s numbers ever need reproducing on a busier machine.
