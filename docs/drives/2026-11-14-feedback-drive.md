# Feedback drive, 13-14 Nov 2026

Marc's instruction (13 Nov evening): fix, improve and release the Distavo feedback backlog; first long recordings
that must not fail because of their size, then an automatic stop at 8 hours, then the P4/P3 bugs; one release.

## What shipped

- **Version:** 1.21.0 (build 24), tag `v1.21.0` — https://github.com/joanmarcriera/distavo/releases/tag/v1.21.0 (merge commit 756afe3, PR #19)
- **PR:** https://github.com/joanmarcriera/distavo/pull/19 (`release/1.21` into `main`)
- **CI on the release branch:** green, https://github.com/joanmarcriera/distavo/actions/runs/43547701272 (smoke + test: DistavoCore, DistavoEmbedded, all three editions unsigned)
- **Release runs:** Direct DMG https://github.com/joanmarcriera/distavo/actions/runs/43549999120 (success: signed, notarised "Accepted", appcast published); App Store https://github.com/joanmarcriera/distavo/actions/runs/43549999079 (upload-appstore success, submit-for-review waiting for the `app-store-submission` approval)
- **Appcast / App Store Connect:** https://distavo.com/appcast.xml serves 1.21.0 (build 24), HTTP 200. App Store Connect (API dry run 2026-11-14 03:30): build 1.21.0 (24) processingState VALID; 1.20.0 READY_FOR_DISTRIBUTION; the 1.21.0 version record is created by the gated submit job

### Marc's two requirements

1. **Long recordings (#6759)** — `LongRecording.swift`. A work WAV over 90 min is cut at the quietest second near every
   30-min boundary (streamed), silent parts are skipped, each part goes through the normal engine, the results are
   stitched (absolute times, speakers renumbered per part, a footer line). Parts are cached so a quit, deferral or crash
   resumes. A transcript longer than the Ollama `num_ctx` is summarised in parts and merged (also in Regenerate).
   A file Distavo died on is set aside with a notification, never retried at launch (`setAsideInterrupted`; a normal
   quit clears its own pid-tagged markers). Proof: `LongRecordingTests` runs a synthetic 5 h 20 min WAV through
   `Pipeline.processOne` with the live converter: 9 engine calls of at most 35 min, a note, flat memory, 43 s.
2. **8-hour cap (#6857)** — `RecordingDurationCap.swift`, `recording.max_duration_hours` (default 8, also for old
   configs; 0 = off), warned 10 min before, stopped through the normal stop path without the speakers question,
   processed as usual, notification. Settings, Recording. Tests inject the elapsed time.

### Also in 1.21

- The whole unmerged drive chain of 24 Oct - 9 Nov (d..s lanes): #3951, #4010, #4011, #4013, #4014, #4017, #5284, #6647,
  #6355, #3857, #3953, #4018, #6353 (opt-in), #6666 (opt-in), #4015 (opt-in), #6668 core, #6670 storage format.
- Review decisions A-C of `docs/drive-review-2026-11-09.md`, taken as recommended (they follow the documented
  inert-until-switched-on rule): `summarise.apply_corrections` and `notes.link_duplicate_calls` off for old configs, on
  for fresh installs; role-term packs only for meetings whose transcription language is English or Automatic.
- #6772 parts 1-2: the owner's name seeds the glossary (and the transcriber prompt only when one already exists); a
  rule says "standing in for" is not evidence of who the owner is.
- #6670: Settings, Recording: format picker (full / compact 16-bit), recordings folder size and free disk.
- CI abort on macOS 26 runners fixed (see below).

## How it was checked

- `cd apple/DistavoCore && swift test`: 1774 tests, 2 skipped, 0 failures (local, Xcode 27) and green on CI (macOS 26.7, Xcode 26.6). DistavoEmbedded: 92 tests, 0 failures.
- Release builds of all three editions unsigned (Direct, Setapp, App Store): BUILD SUCCEEDED; App Store and a clean
  Setapp build contain no Sparkle and no Lemon Squeezy link. `ops/pre-tag-check.sh --static v1.21.0`: 0 failures.
- A Sonnet review subagent read every non-trivial diff (long recordings, cap, A-C, #6772, #6670); each finding was
  checked against the code and fixed on its branch before merging.
- gitleaks over the whole range: no leaks.

## Things worth knowing

- **Public history kept clean.** The drive chain carried internal market memos (CEO/CFO/COO, pricing), store-copy
  drafts, the real-meeting findings (which mention job-search calls) and metrics. They were removed from every commit
  of the release range before the first push to GitHub (`git filter-branch --index-filter`, code byte-identical); they
  stay on the private Forgejo drive branches (`marc/distavo-work`). Initials of a person from a client meeting in the
  #6772 tests were replaced the same way.
- **CI abort on macOS 26 (Xcode 26.4-26.6).** `main` itself failed CI since d6bd264 (#4018): "freed pointer was not
  the last allocation" when `processOne` resumed from awaiting a genuinely async `PipelineDeps` default
  (`containerCreationDate` -> AVFoundation `load`). Bisected on CI (v1.20.0 green, d6bd264 first red), backtraced with
  `SWIFT_BACKTRACE`; fixed by synchronous-bodied defaults and a pure `noteStart`. It reproduces only on the runner
  (macOS 26.7, Xcode 26.x), not on the Mac (macOS 27, Xcode 27), and the release workflows build on that runner, so a
  release from before the fix could have aborted when dating a dropped file without a name stamp.

## Tasks

Closed with evidence (commit + tests + release) on 14 Nov:
[#6759](https://familia.riera.co.uk/tasks/6759), [#6857](https://familia.riera.co.uk/tasks/6857),
[#3951](https://familia.riera.co.uk/tasks/3951), [#4010](https://familia.riera.co.uk/tasks/4010),
[#4011](https://familia.riera.co.uk/tasks/4011), [#4013](https://familia.riera.co.uk/tasks/4013),
[#4014](https://familia.riera.co.uk/tasks/4014), [#4016](https://familia.riera.co.uk/tasks/4016),
[#4017](https://familia.riera.co.uk/tasks/4017), [#4022](https://familia.riera.co.uk/tasks/4022),
[#3929](https://familia.riera.co.uk/tasks/3929), [#3857](https://familia.riera.co.uk/tasks/3857),
[#5284](https://familia.riera.co.uk/tasks/5284), [#6355](https://familia.riera.co.uk/tasks/6355),
[#6647](https://familia.riera.co.uk/tasks/6647), [#5536](https://familia.riera.co.uk/tasks/5536) (stale: finding no longer holds).

Released, left open with a comment for the by-eye check on a signed build the task asks for:
[#4001](https://familia.riera.co.uk/tasks/4001), [#4023](https://familia.riera.co.uk/tasks/4023),
[#3943](https://familia.riera.co.uk/tasks/3943), [#4039](https://familia.riera.co.uk/tasks/4039),
[#3584](https://familia.riera.co.uk/tasks/3584).

Partly done, open with a comment: [#6670](https://familia.riera.co.uk/tasks/6670) (format picker and folder size
shipped; default stays Full), [#6772](https://familia.riera.co.uk/tasks/6772) (parts 1-2 shipped; part 3 left).

## What is left, and why

- **#4019 memory growth (P4):** findings only (`docs/memory-growth-2026-10-31.md`); the fix needs an Instruments run on
  the Mac to confirm which engine holds the memory. The long-recording parts bound the per-file peak, not the growth.
- **#6668 split a recording (P4):** the pure core shipped; the "new meeting" marker and the Split action in the Notes
  window are app UI still to build.
- **#6667 stop-sheet template preselect (P4):** wired and compiled in 1.21, never clicked on a signed build.
- **#6772 part 3:** a solo tail after the meeting ("afterwards myself talking alone") is still summarised as meeting
  content; needs #6668's split UI or a segment-aware prompt.
- **#6760 forgotten recording:** the 8-hour cap and the silent-part skip cover the worst case; a repeating stop
  suggestion was not built. #6671 (Stop and discard on the nudge) not started.
- **Live checks not run:** the 4 h 21 min file of #6759 itself, and the owner rule of #6772 against a real model on
  the 12 Nov meeting. Both are on the Mac with client audio, which this drive does not copy or read.
- The P3 list beyond these was not reached tonight; `triage.md`-style classes for each are in the task comments.

## What needs Marc

1. **Approve the App Store submission** (card [#6858](https://familia.riera.co.uk/tasks/6858) on the inbox board):
   https://github.com/joanmarcriera/distavo/actions/runs/43549999079 , Review deployments, Approve. AFTER_APPROVAL, so it
   goes live by itself once Apple approves.
2. **Setapp upload** stays manual (vendor UI, `docs/setapp-submission.md`).
3. The by-eye checks above (#4001, #4023, #3943, #4039, #3584, #6667) on the signed 1.21.0.
4. Defaults still yours to flip if you want them on for existing users: `transcribe.channel_speakers` (#6353),
   `summarise.neutral_default` (#6666), `summarise.non_meeting_guard` (#4015), `recording.storage_format` (#6670).
5. Decisions A-C of `docs/drive-review-2026-11-09.md` were taken as recommended (reversible config defaults); say so if
   you want any of them the other way.
