# Distavo → Setapp: submission packet (index)

Status as of 2026-10-25, for Distavo 1.20.0 (build 23). **Nothing is submitted.** Setapp
application, vendor dashboard, SDK/public key and the upload are Marc's (human account steps).
Channel: Single App Distribution, USD 29 one-off (`docs/setapp-submission.md` §1); Membership was
declined by MacPaw on 2026-09-07. KYC submitted 2026-09-17; vendor dashboard not yet open.

## Where each piece lives

| Need | File |
|---|---|
| Step-by-step playbook, build, notarise | `docs/setapp-submission.md` |
| Marc-only actions in order | `MARC_RUNBOOK.md`, short version `FIRST_UPLOAD_CLICKS.md` |
| Listing copy and field mapping | `LISTING_DRAFT.md` (What's New updated for 1.20 below) |
| Comment for the review team | `REVIEW_TEAM_NOTES.md` |
| Assets and screenshot rules | `ASSETS_CHECKLIST.md` |
| Framework integration (after SDK arrives) | `FRAMEWORK_INTEGRATION.md` |
| Open blockers and release-readiness evidence | `BLOCKERS.md` |

## Requirements checklist

| Requirement | State | Evidence |
|---|---|---|
| Bundle ID `uk.co.riera.distavo-setapp` | done | `apple/configs/Setapp.xcconfig` |
| Developer ID signed, notarised, hardened runtime, no sandbox | script ready, run at upload time | `apple/scripts/build-and-notarize.sh setapp` |
| `NSUpdateSecurityPolicy` for SetappAgent | done | `apple/Setapp-Info.plist` |
| No Sparkle, no donate link in this edition | enforced by `verify_edition` | `BLOCKERS.md` table |
| Zip under 1 GB | ok (about 2.3 MB without models) | 2026-09-06 build |
| Icon 1024×1024, 824 art, inset | done | `apple/metadata/setapp/AppIcon-setapp.png` |
| Screenshots, ≤5, 16:10, ≥1280×800 | 4 ready | list below |
| Description ≤3000, Key Benefits ≤80, Release notes ≤5000, Review comments ≤2000 | drafted | `LISTING_DRAFT.md` field map |
| Support / promo / privacy URLs | set | distavo.com/support, distavo.com, distavo.com/privacy |
| Setapp Framework + app public key | **blocked on vendor dashboard** | confirm first whether Single App Distribution needs the Framework |
| Upload via Web UI | **Marc** | `FIRST_UPLOAD_CLICKS.md` |

## Screenshots to upload (all from the Setapp edition, no donate/Sparkle items)

| # | File | Size |
|---|---|---|
| 1 | `apple/metadata/screenshots/setapp/01-menu.png` | 2560×1600 |
| 2 | `apple/metadata/screenshots/setapp/02-watch.png` | 2560×1600 |
| 3 | `apple/metadata/screenshots/setapp/03-engines.png` | 2560×1600 |
| 4 | `apple/metadata/screenshots/setapp/04-note.png` | 2560×1600 |

Optional 5th: a Notes window shot (`docs/screenshots/1.18-notes-window/01-notes-window.jpg` is
1400×1050, 4:3, so it does not meet 16:10; re-capture before use, synthetic content only, see
task 2971).

## Release notes for the first Setapp version (1.20.0)

First release on Setapp. Distavo is a native macOS menu-bar app that turns your meeting recordings
into structured Markdown notes, using on-device transcription and a local Ollama server you control.
Nothing leaves your machine.

New in this version:
- Summarise together: select two to ten notes in the Notes window and choose "Summarise Together…"
  to get one project note. Every bullet cites the meeting it came from; unsupported bullets are dropped.
- Tidier vocabulary: when you change participants or language, Distavo offers to clear custom terms
  that were not heard.
- Better Catalan and Spanish notes, fewer invented facts, recovered dropped speech, an automatic
  summary template and in-person meeting mode (1.19).

Already in the app: Notes window, search and Ask (local only), action items and Reminders export,
optional read-only calendar match, transcript export to SRT/VTT/HTML/DOCX/PDF.

## Next for Marc

1. Chase MacPaw for the vendor dashboard (email text in `FIRST_UPLOAD_CLICKS.md`).
2. Ask on that call if Single App Distribution needs the Setapp Framework.
3. Run `TEAM_ID=… NOTARY_PROFILE=distavo-notary apple/scripts/build-and-notarize.sh setapp` and upload.
