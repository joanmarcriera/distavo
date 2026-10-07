# Notes window (1.18)

Menu bar -> **Notes…** (or `open distavo://notes`) lists every note, newest meeting first, and shows the
selected note with what it has and every action that applies to it. It replaces nine menu commands that
each chose "which note" their own way (the last note, a popup, a file panel).

Screenshots from a Debug build with synthetic notes: `docs/screenshots/1.18-notes-window/`.

## What is where

- **List** (left): title, date, length, and a mark only when something is missing or unusual:
  `no transcript`, `no timestamps`, `variant`, `2 versions`, `new` (written since the window opened),
  `regenerate waiting` / `regenerating`.
- **Search field**: scope **Titles** filters the list as you type (title, file name, calendar title; case and
  accents ignored). Scope **Inside notes and transcripts** is the full-text search of #2942 with an excerpt per
  note, plus the Kind and Speaker filters. The index is still opt-in: nothing is created until you press
  **Build the Search Index** in that scope (see `docs/search.md`).
- **Selected note** (right): what is on disk (timed transcript, saved transcript, speakers, calendar match),
  then the actions in three groups, then the rendered note.

| Group | Action | Needs | Reason shown when disabled |
|---|---|---|---|
| Read | Open Note, Reveal in Finder, Ask About Note… | the note | never disabled |
| Read | Open Transcript… | saved or timed transcript | no saved transcript |
| Export | Export Transcript… | `<base>.segments.json` | no timestamps saved / no saved transcript |
| Export | Copy Transcript | `<base>.transcript.clean.txt` | no saved transcript |
| Export | Export Key Moments… | `<base>.bookmarks.json` with marks | no key moments marked |
| Change | Regenerate… | saved transcript, no regenerate pending | no saved transcript / already waiting to regenerate / regenerating now |
| Change | Rename Speakers… | a speaker in note, transcript or timestamps | no speakers found / wait for the regenerate to finish |
| Change | Compare Versions… | two or more notes for the recording | only one version |

A disabled action stays visible with its reason printed under the button.

- **Several notes selected**: Export N Transcripts… writes one file per note into a folder you choose, in one
  format, named after the note (` 2`, ` 3`… when the name exists; nothing is overwritten). Notes without
  timestamps are skipped and counted in the reason line.
- **Regenerate** and **Rename Speakers** are sheets on the window, titled with the note and its file name. They
  have no note chooser. The sheet belongs to the note whose button was pressed; the list can change behind it.
- **Open Transcript**, **Compare Versions** and **Ask About Note** open their own windows for that note.
  "Ask All Notes…" is offered when nothing is selected.
- **Footer**: what Distavo is doing, how many regenerates are waiting, and **Queue…**.

## Staying current

The folders are re-read every 3 s while the window is open and at once when a regenerate starts or ends. Rows
are cached until one of the note's files changes (note, transcript, timestamps, speaker names, calendar match,
key moments), so a refresh reads almost nothing. A refresh never moves the selection: a note written while the
window is open appears in the list marked `new`, and the selected note stays selected. The newest note is
selected once, when the window first loads.

The list is ordered by when the meeting happened (calendar match, else the date in the file name, else the
file date), so regenerating an old note does not move it to the top.

## Regenerate and the Processing Queue

A regenerate is a row in the Processing Queue from the moment it is asked for: **Waiting** while a recording is
being processed, **Summarising** while it runs, then **Done**, or **Skipped** with the reason when it could not
run (the note is untouched and no recording is marked failed). A second regenerate of the same note is refused
until the first ends. The Queue stays a separate window because it lists recordings, including ones with no
note yet, in processing order; its Done rows and regenerate rows offer **Show in Notes**.

## What did not change

- Everything that rewrites a note keeps its safety: `.prev-` backup, atomic write, under the scan lock
  (`regenerateNote`, `renameSpeakers`, `resetSpeakers` in `WatcherController`).
- No config key was added. Window size is remembered by AppKit; the search opt-in is the existing
  `search.indexEnabled` in UserDefaults.
- `distavo://notes` opens the window only. It cannot name or select a note.

## Code

- `DistavoCore/NotesLibrary.swift`: `NotesLibrary.scan`, `availability`, `marks`, `filter`,
  `retainedSelection`, `TranscriptBatchExport` (tests: `NotesLibraryTests`).
- `DistavoCore/ProcessingQueue.swift`: regenerate rows (tests: `QueueRegenerateTests`).
- App: `NotesWindow/` (`NotesModel`, `NotesView`, `NotesWindowController`), `Core/WatcherController+Notes.swift`.
