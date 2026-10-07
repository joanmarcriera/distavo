# Automation: Shortcuts, URL scheme, Finder Service (#2953)

Available in all three editions (Direct, App Store, Setapp), no setup and no new permissions.
Everything goes through the running app, so it uses the same single-flight scan as the menu.

## Shortcuts (App Intents)

Search "Distavo" in the Shortcuts app.

| Action | Result |
|---|---|
| Transcribe File | Copies an audio/video file into your recordings folder (never overwriting) and starts a scan. Returns the queued file name. |
| Start Recording / Stop Recording | Starts/stops the built-in meeting recorder (macOS 14.4+). Clear errors if already recording / not recording / unsupported. |
| Get Latest Note | Returns the newest note as a Markdown file. |
| Get Latest Note Path | Returns the newest note's file path as text. |

Backup copies (`.prev-` files from Regenerate) are never returned as the latest note.

## URL scheme

`open distavo://<command>`. Commands: `open-latest-note`, `process-now`, `settings`, `notes` (opens the Notes window; it cannot name or select a note), `record/start`, `record/stop`.

Any web page or app can open a URL, so the scheme is deliberately tiny: no command takes a path, reads, moves or
deletes files, or changes settings. Starting a recording by link always asks first (Cancel is the default button,
so a stray Return does nothing; repeated links while the question is open are dropped). `record/stop` needs no
confirmation because stopping saves the audio. `process-now` repeats within 5 seconds are ignored. The Start Recording
shortcut posts a "Recording started (via Shortcuts)" notification so a recording never starts silently.
Unknown or malformed URLs are ignored and logged. `process-now` scans for new recordings but, unlike the menu's
Process now, does not clear failed markers.

## Finder Service

Finder -> right-click an audio/video file -> Services -> **Transcribe with Distavo**. The file is copied into the
recordings folder and processed. If it is missing, enable it in System Settings -> Keyboard -> Keyboard
Shortcuts -> Services -> Files and Folders.

## Sandbox notes (App Store edition)

The intents and the Service write to and read from the recordings/notes folders you granted at first launch
(security-scoped bookmarks, `Core/SandboxFolders.swift`). Input files from Shortcuts/Services are readable only
during the call, so they are copied immediately and the original URL is never kept.

## Not built: Voice Memos share extension

A Share extension for Voice Memos needs a new extension target with its own bundle ID
(e.g. `uk.co.riera.distavo.share`), its own App Store provisioning profile and App Group (to hand the file to the
app), and matching Direct (Developer ID) and Setapp signing; it also changes the archive/notarisation pipeline.
Those identifiers and profiles can only be created by the account holder, and a half-configured target could
break the release archive, so it was left out. Until then: share the memo to Files (or drag it onto the recordings
folder), or run the Transcribe File shortcut / Finder Service on the exported file.
