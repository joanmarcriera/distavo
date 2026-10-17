# Summarise together (Vikunja #3199)

Notes window: select 2 to 10 notes, press **Summarise Together…**, give a project title.

- Reads the selected notes' bodies only (no transcripts), never modifies them.
- Backend and local-only rules are Ask's: on-device, or Ollama on loopback/private LAN; a public endpoint is refused before any request.
- Notes that do not fit one model window are summarised in batches and merged (`ProjectSummary.batches`, `merge`).
- The model must cite each bullet as `[[note name]]`. A bullet is removed when it cites no selected note, cites an unknown note, or contains a number found in none of the cited notes. The count removed is printed at the end of the new note.
- Output: a new `Project - <title>.md` in the notes folder (never overwrites; `... 2.md` if it exists) with frontmatter `type: project-summary` and `sources:`. If no bullet survives verification nothing is written.

Code: `DistavoCore/ProjectSummary.swift` (pure + `run`), `Sources/Distavo/Core/WatcherController+ProjectSummary.swift`, `NotesWindow/NotesView.swift`. Tests: `ProjectSummaryTests`.
Manual check (needs a real run): select 3 real notes, summarise, open the output, confirm every bullet's `[[link]]` supports it.
