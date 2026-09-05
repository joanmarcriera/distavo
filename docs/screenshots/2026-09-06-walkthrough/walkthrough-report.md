# Distavo marketing screenshot walkthrough — 2026-09-06

## Method

Distavo is a native macOS `LSUIElement` menu-bar app — there's no DOM/Electron surface for
Playwright, so this walkthrough drove the **live, already-running production app**
(`/Applications/Distavo.app`, in daily use since 2026-08-29) via `osascript`/System Events
accessibility automation, with `screencapture` capturing tight, accessibility-bounded crops
(never full-screen — the desktop had several other live sessions and windows with sensitive
content that must never land in a screenshot; see Safety notes below).

A Debug build was also compiled (`apple/build-screenshot/`, gitignored, unsigned, Direct edition)
for `distavo-native-verify`-style confirmation that the current source still builds, but it was
**not launched** — launching it would have pointed a second process at the same shared
`~/Library/Application Support/Distavo/watcher-config.json` and real recordings/notes folders as
the live instance, risking config or double-processing corruption. This trade-off was confirmed
with Marc before starting (see "Screenshot approach" decision).

**Never clicked** (per explicit confirmation): Save, Process now, Record meeting, the "Use local
Ollama" toggle, Watch interval, Pause/Resume watching, Quit, Check for Updates…

## Screenshots captured

| # | File | Shows |
|---|---|---|
| 1 | `01-menu-main.png` | Main menu-bar dropdown — idle status, all menu items |
| 2 | `02-menu-activity.png` | Activity submenu with real recent-activity log entries |
| 3 | `03-menu-help.png` | Help submenu — usage tips, supported formats, links |
| 4 | `04-settings-general.png` | Settings — "Getting started" + "General" (folders, watch interval, login item) |
| 5 | `05-settings-transcription-summarisation.png` | Settings — Transcription (built-in engine, model, diarize) + Summarisation (Ollama) |
| 6 | `06-settings-connections-updates.png` | Settings — Connections (test/permissions) + Updates |
| 7 | `07-notes-folder.png` | Finder — the notes output folder (cropped to exclude sidebar/other folders) |
| 8 | `08-recordings-folder.png` | Finder — the recordings input folder (cropped to exclude sidebar/desktop) |

Not captured, with reason:

- **Permissions sheet / "Test connection" result** — the SwiftUI Form's accessibility tree nests
  these buttons too deeply for `System Events` name-based lookup to resolve reliably, and
  coordinate-based clicking is blocked by the auto-mode safety classifier (reasonably — a blind
  click can't be verified safe). Not attempted further; screenshots 6 still show both buttons in
  their default (untested) state.
- **"Record meeting" / "Stop recording" state** — starting a real recording on the live app would
  create a genuine audio file that the watcher would then try to process, and risks capturing
  ambient audio in this session. Skipped per the confirmed safety boundary.
- **Watch interval submenu** — explicitly on the "never click" list.
- **A completed note's actual content** — deliberately not shown; real transcripts may contain
  private meeting content. The folder-listing screenshots show structure/output without exposing
  transcript text.

## UI-health findings (from the live activity log + source read, not from clicking through)

1. **Two 2026-07-07 recordings are permanently stuck failed and have no note.**
   `Meeting 2026-07-07 12.36.59.wav` and `Meeting 2026-07-07 14.47.35.wav` are both 4 KB (empty/near-empty
   WAV — almost certainly failed recording captures, not failed transcriptions) and logged
   `could not start reading (The operation could not be completed)` on 2026-07-31. Per
   `DistavoState`, `.failed` markers persist until "Process now" is used, so these two will sit
   silently forever unless Marc notices they're missing from `notes/`. → Vikunja task filed.
2. **Confusing error message when the embedded model can't download while offline.**
   The 2026-07-31 log shows `Failed: … — Model not found. Please check the model or repo name and
   try again. Error: downloadError("The Internet connection appears to be offline.")` — the primary
   message ("model not found… check the repo name") doesn't match the actual cause (no internet),
   which would send a user down the wrong troubleshooting path. → Vikunja task filed.
3. **`hasLastNote` (enables "Copy last transcript" / "Open last note") never re-initializes from
   disk.** `WatcherController.hasLastNote` (`Core/WatcherController.swift:22`) starts `false` and is
   only set `true` after processing a recording *in the current run* (line 253) — it's never seeded
   from the newest file already in `notesDir` at launch. So after every restart (including today's),
   both menu items are disabled even though 11 real notes exist on disk. Confirmed by inspecting the
   live main-menu screenshot (both greyed out) against a non-empty `notes/` folder. → Vikunja task
   filed.

No console/crash errors were logged by the Distavo process during the walkthrough itself
(`log show --predicate 'process == "Distavo"' --last 30m` was clean) — the automation did not
disturb the running instance.

## Safety notes (for whoever runs this again)

- Distavo shares one config/data path (`~/Library/Application Support/Distavo/`,
  `~/Documents/Distavo/`) across every build/edition — there is **no env-var override** (Swift's
  `FileManager.homeDirectoryForCurrentUser` ignores `$HOME` on macOS, confirmed empirically). Never
  run a second instance against the same paths as a live production install without isolating one
  of them first.
- Full-screen `screencapture` is unsafe on a multi-session desktop like this one — background
  Claude/Terminal sessions actively handling secrets and personal email surfaced in two accidental
  full-screen captures during this run (both deleted immediately, never written to a kept file).
  **Always crop to the exact accessibility-reported bounds of the target element**, and verify by
  reading the image back before keeping it. A "combined bounding box" of two non-adjacent UI
  rectangles (e.g. a menu + its submenu) can contain an uncovered notch that exposes whatever is
  behind it — capture each rectangle separately instead.
- Hiding other apps (`set visible of process … to false`) is **not durable** — a background process
  can re-surface its own app (e.g. on completing a task) at any moment. Don't rely on it as a privacy
  guarantee; tight cropping is the actual safety mechanism.
