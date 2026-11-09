# Participants sheet for files dropped into the watch folder (Vikunja #4012)

Core is done and tested: `apple/DistavoCore/Sources/DistavoCore/DroppedFileSheet.swift`
(`DroppedFileSheetTests`, 13 tests). This note is the app-target half, for a person to build and check by eye.

## What the core gives the app
- `DroppedFileSheet.decide(workDir:base:source:isLiveCapture:)` -> `.offer` or `.skip(.answered | .liveCapture | .alreadyOffered)`.
- `DroppedFileSheet.prefill(workDir:record:owner:)` -> `Prefill(hints, source, sourceLine)`; source is the sheet of a
  recording of the same call (start within 2 min), else recent sheets (role, people, same-contact terms), else empty.
- `DroppedFileSheet.markOffered(workDir:base:)` after the sheet is shown (answered or dismissed).
- The answer is saved with `SpeakerHints.save`, exactly like the recorder; `Pipeline.processOne` already reads it.

## UI to build (not done; needs a signed build and a design call)
1. **Where**: a new `WatcherController+Sheets.swift` (`+Feature` file). When the scan finds a pending file with no
   `.processing/.done/.failed` marker, call `decide`; on `.offer`, post a notification "New recording: <name> - who was in it?"
   with an action that opens the sheet. Do NOT open a modal from a timer (the non-modal window decision is
   https://familia.riera.co.uk/tasks/4020).
2. **Never block**: the pipeline keeps going without the answer. Answered before transcription, the hints apply; after, the
   answer is for Regenerate (the sheet says so). Defer-never-fail is unchanged.
3. **Form**: reuse the recorder fields (your role, other participants, count, meeting terms) from
   `MeetingCaptureController` (~lines 597-840); extract a shared `ParticipantsForm` instead of copying. Show
   `Prefill.sourceLine` under the fields.
4. **Record time**: build the `CallRecord` from the file container time and duration (`isLiveCapture: false`) and call
   `DuplicateCallLink.register` as the pipeline already does, so a later twin links both ways.
5. **Edition gate**: none; the sheet touches only the work dir. The sidecar beside the file needs the watch-folder bookmark
   (App Store), which already exists.

## Still open (not core)
- Filename hint (`interview-15-10-2026-16.00` -> interview template) and owner inference without a sheet overlap
  https://familia.riera.co.uk/tasks/3857; `OwnerSpeakerLabel` already returns "unknown" for a label that is not in the file.
- Found while writing this: the recorder sheet writes `Alex (Alex, me): role` for a named owner, but
  `SpeakerSuggestions.role(in:)` searches for `(me): `, so the role is never recalled for a named owner (works for "Me").
  Fix both in one place when the form is extracted (item 3).
