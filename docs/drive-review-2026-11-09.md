# Drive review 2026-11-09: the h chain (lanes d-h) and branch j

Reviewer: drive 2026-11-09-0516, lane `distavo-review` (Opus). Scope: `main..feat/drive-distavo-h-2026-11-09`
(110 commits, 181 files, +25.7k lines of which ~4.4k under `apple/`; the rest is docs, market memos,
`docs/architecture/*.html`, the site under `ops/site/` and the changelog). Fixes for what the review found are on
`feat/drive-distavo-j-2026-11-09` (10 commits on top of h, listed below).

## Recommendation

**Merge `feat/drive-distavo-j-2026-11-09` (which contains all of h) into `main`, after the three decisions under
"Decisions for Marc" and the by-eye checks.** Do not merge h alone: on its own it breaks the defer-never-fail rule
in both directions (see findings 1 and 2), and a duplicate-call match can put another call's participants into a note.

- Dry run, 2026-11-09, throwaway worktree off `main` 16003f8: `git merge --no-commit --no-ff` of h, and then of j,
  both "Automatic merge went well" (181 and 185 files), aborted, worktree removed. `main` is an ancestor of both,
  so the merge is conflict-free (it can be a fast-forward).
- Tests on j: `cd apple/DistavoCore && swift test`: 1581 tests, 2 skipped, 0 failures (h was 1567, 0 failures).
  `cd apple/DistavoEmbedded && swift build`: Build complete. The app target was NOT built in this lane (no
  `xcodebuild`): j changes one app-adjacent file, `DistavoEmbedded/EmbeddedSummariser.swift`, which compiled.

The merge command, when Marc is happy:

    cd ~/Development/Project/distavo && git checkout main && git merge --no-ff feat/drive-distavo-j-2026-11-09

(`origin` is GitHub: push `main` there yourself; the drive does not.)

## How the review was done

Two Opus reviewers read the diff in two slices (pipeline/state/config/engines; speakers/transcript/vocabulary/
capture/menu/ops scripts), read-only. I verified each finding against the code before fixing it, wrote a failing
test first, then the fix. A Sonnet reviewer then read the j commits.

## Findings and what happened to them

| # | Sev | Finding (h branch) | Status |
|---|-----|--------------------|--------|
| 1 | high | A transient or machine-level conversion failure (disk full, offline volume, no permission) was rethrown and marked `.failed`. Only the menu's Retry and Process now clear `.failed` (nothing at launch, although four comments say so), so the file stayed failed. | **Fixed** adf740c: defers with backoff; five-in-a-row cap and the file-fault path unchanged. |
| 2 | high | `contextTooSmall` on the Apple path always deferred. The size-0 "not ready" case is caught before the driver runs, so this error comes from the recording's own prompt (vocabulary, Quick Notes, template) and recurs: the file was re-transcribed every 30 min for ever, with no note and no error. | **Fixed** 28b08dd: defers only for a 0 window. |
| 3 | high | `DuplicateCallLink` tries a dropped file's container time as END and as START. A memo started at 10:31 after a 10:00-10:30 Mac call, read as END, matched 96% and inherited the call's participants and speaker count; two back-to-back phone files paired too. | **Fixed** c15e797: same reading for two dropped files; the sheet is copied only when starts are within 2 min (the link alone otherwise). |
| 4 | medium | `ops/pre-tag-check.sh`: under `pipefail`, `strings \| grep -q` exits 141 when grep finds the string, so the App Store "no Lemon Squeezy / no Run in Terminal" check printed ok exactly when the string was present. | **Fixed** 1a7d12e (reproduced first). The sandbox check still does not test for `<true/>`. |
| 5 | medium | Duplicate-call linking has no config key: always on for every user (footer line + sheet copy). | Open: see decision B. Finding 3's fix removes the harmful part. |
| 6 | medium | `summarise.apply_corrections` decodes to **on** for configs that predate it, and runs after `LedgerVerifier`, so verified ledger quotes can be rewritten. | Open: decision A (commit bc2b852 chose "default on" deliberately). |
| 7 | medium | Role-term packs (#3950): a participants line with "accountant" adds 11 English UK-tax terms to the transcription vocabulary with no opt-in; a vocabulary prompt is what collapses BSC Catalan chunks (#3579). | Open: decision C. |
| 8 | medium-low | The Parakeet-empty fallback to WhisperKit (`AppPipelineDeps.swift:88`) may start a ~1.6 GB `large-v3-turbo` download with no consent, and retry it every scan offline. | Open, app target; suggest falling back only when the model is already downloaded. |
| 9 | low | "(CEO of Acme)" dropped the whole term, so "Acme" was no longer a spelling hint. | **Fixed** 1049d0f. |
| 10 | low | OffensiveWordGuard: the tool-context pattern no longer accepts hyphen/slash forms ("…-plugins", "…/Icinga"), so those become "[word removed]-plugins". | Open (low). |
| 11 | low | A `.convertfail` count of 1 survives a later successful conversion; trashing from the queue leaves `.unreadable`; only `CancellationError` counts as a cancel. | Open (low; no production code cancels `processOne`). |
| 12 | low | #3930 wiring is partial: `inputMuted` is hard-coded false; the diagnosis' actions (Open Microphone Settings, Switch input) are dropped; a nil input name reads "No microphone is selected". | Open: by-eye check 1. |
| 13 | low | `MeetingReminderPolicy`: a meeting shorter than 10 min with detection on and no call signal is never reminded. | Open (design). `MeetingDigest`, `MeetingReminderPolicy`, `DeferredQuestionContext` have no callers yet. |

Checked and fine (reviewers): TranscriptMeta stays backward compatible; `channel_speakers` and `non_meeting_guard`
are off by default; compaction skips when the stereo take is needed; partial WAVs are removed on failure; the
corrupt-config fallback uses `Config()`; regenerate keeps the glossary order of `processOne`;
TranscriptionCorrections protects Highlights, fences and URLs; digest day keys use an injected time zone;
`DeferredQuestionContext` sends the event title to the UI only; `check-tag-version.sh`, `smoke.sh` and
`weekly-metrics.sh` only do public GETs.

## Second round: Sonnet review of branch j

No high findings. Fixed: a long dense meeting planned as map-reduce could still overflow per chunk (now split
once, 30c2fd9); the density scale shrank the reduce budget for the model's own bullets (removed, 30c2fd9);
deferring transient conversion failures made five quick retries hit the cap in ~15 min (now counted at most once
an hour, 397d3fe). Open, low:
- Machine-level conversion failures (disk full, no permission on the source) now defer for ever at a 30-min
  backoff with only a "deferred" row as the signal; a lost security-scoped bookmark recurs identically. Consider a
  cap, or treating read permission on the source as the file's fault.
- Silence phrases are dropped from the clean transcript only: `.segments.json` (viewer, SRT/PDF exports) and
  `MeetingShapeGate` still see them. Any segment mentioning "amara.org" is dropped.
- "(Head of Research at Acme)" gives the term "Research at Acme"; "(Head of Finance)" now seeds "Finance".
- Two dropped files from phones with different time conventions (Android END + iPhone START) no longer link.

## Branch j: the packet tasks

- **#5284** aa63fc4: a prompt the heuristic planned as one pass but the real tokenizer says overflows
  (`promptTooLong` / `outputBudgetTooSmall`; dense text, digits, Catalan) is retried once as map-reduce, chunks and
  the reduce budget scaled by the measured ratio. If the instructions alone leave no room, the original error
  stands. Plus 28b08dd (finding 2).
- **#4025** ab13ba8: whole segments that are a Whisper silence phrase ("Thank you for watching" x20,
  "you you you", Amara.org credits, the es/ca equivalents) are dropped by `TranscriptCleaner.clean`. A recording of
  nothing else takes the existing "empty transcript" path instead of producing an invented note. The ledger
  examples in the task (wrong figures, quotes from other facts, invented names) are already caught by
  `LedgerVerifier` rules (b)-(d) from #4017 on this chain. Speech-to-text errors themselves ("415" for "115") and the
  model's interpretation errors are not fixable in code.
- **#4021**: no code. The pure parts are on h (`SpeakerRecallAids` 9336500, `DeferredQuestionContext` ea1b1aa);
  the form UI still waits for the non-modal window decision in https://familia.riera.co.uk/tasks/4020.

## Decisions for Marc

- **A. `summarise.apply_corrections` for existing configs.** CLAUDE.md says new keys are off for configs that
  predate them; bc2b852 made it on. Recommendation: off on decode, on in `recommendedForThisMac()`, and skip the
  facts-ledger quotes when applying. One-line change in `Config.swift:310` plus a `ConfigMigrationTests` case.
- **B. Duplicate-call linking switch.** Recommendation: a `notes.link_duplicate_calls` key, off for old configs,
  on for fresh installs.
- **C. Role-term packs.** Recommendation: a key off by default, or skip the pack when the spoken language is not
  English, so a Catalan meeting with an accountant does not get an English vocabulary prompt.

## By-eye checklist (signed Direct build on Marc's Mac)

1. **Mic-silent label (#3930).** Start a call recording with the microphone muted in hardware (or a silent input
   selected) while the other side talks. Within the check window you should see "Your microphone is silent" with
   a reason naming the input: "Nothing is coming in from “<input name>”. Is it muted, switched on, or is another
   input meant?". Then revoke Distavo's microphone permission in System Settings and repeat: the text must read
   "Distavo may not use the microphone. Allow it in System Settings, then restart the recording." Note: no buttons appear
   (finding 12), and a muted input is not detected as "muted".
2. **Global shortcut (#4001, on main already).** Settings, Recording, "Start / stop shortcut": switch it on, keep
   ⌃⌥⌘R. With another app in front, press it: a recording starts with no questions; press again: it stops and the
   note is processed. Switch it off: the shortcut does nothing. A clash with another app's shortcut must show the
   registration error under the field.
3. **Stop when the call ends (#4007, wired on branch p).** Settings, Recording, Meeting detection: switch on
   "Offer to record when a call starts" and "Stop recording when the call ends" (both off by default). (a) Press
   Record, then join a Zoom/Teams call 2 min later: nothing stops before you join. (b) Let the call run past its
   calendar slot: it keeps recording. (c) Leave the call: about 60 s later a "Recording stopped — The call ended"
   notification appears, the speakers question shows as for a manual stop, and a note is made. (d) Mute and
   unmute, or drop the network for under a minute: no stop. (e) Switch the option off mid-recording: no stop.
   Unknown until this check: whether Teams/Zoom/Meet keep the microphone open while muted (if one releases it,
   a mute longer than 60 s would stop the recording; the option stays off by default until this is checked).
4. After the merge, one real recording on the built-in engine: a note is written, and a recording made with the
   microphone covered produces no invented note (#4025).

## Review of k (drive 2026-11-09-0758, distavo-review lane, branch feat/drive-distavo-l-2026-11-09)

The last six commits of k (397d3fe..0af0d24: #4011 chunked third attempt, transient-failure spacing, #1793 doc)
read clean: no new finding. swift test on k: its 1584 tests pass (run together with 11 new tests: 1595 executed,
the only failures were the new red tests). Findings in the chain code for the next tasks, each with a failing test
first, fixed on l (swift test 1595, 2 skipped, 0 failures; a Sonnet reviewer read the fixes, its 4 narrowings applied):

| # | sev | Finding | Fix |
|---|-----|---------|-----|
| 1 | medium | #4010 scrubber deleted a section answered "none" (the prompt asks for "none" under transcription corrections) | 1899634 |
| 2 | medium | #4010 scrubber deleted any line with "as per the instructions" / "using evidence only" (ordinary English) | 1899634 |
| 3 | low | #4010 scrubber removed real "### Step 1: Back up the database" headings | 1899634 |
| 4 | medium | #3951 Regenerate, Ask (note + library) and Summarise together read text cached before the guard: the recording that reported the bug still reached a prompt unmarked | 1aa6bfc |
| 5 | low | #3951 hyphen/slash tool forms (open low #10 above) | 1aa6bfc |
| 6 | medium | #4007 MeetingEndPolicy stopped 60 s after Record when the call was not joined yet (a free mic read as an ended call) | 4f06035 |

Open, low: Regenerate does not write `<base>.guard.json`, so the Notes window does not warn for an old recording
whose regenerated summary was guarded in memory; transcript export and viewer of an old recording are unguarded; a
model that paraphrases the speaker instruction with "using evidence only" now leaks that line.
