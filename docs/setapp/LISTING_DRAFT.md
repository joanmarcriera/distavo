# Distavo — Setapp Listing Draft

Drafted from existing `apple/metadata/listing.json` (App Store copy), Setapp's
tone conventions, and Distavo's actual feature set as of v1.8.0.
Setapp listings are typically shorter and punchier than App Store descriptions.
Adapt to the character limits shown in the vendor dashboard.

---

## App name

**Distavo**

(No version number in the name — Setapp policy: one name, no version indicator.)

---

## Category

**Productivity**

(Consistent with App Store listing. Setapp also has a "Work" collection and an
"AI & ML" collection — request inclusion in both during vendor onboarding.)

---

## Tagline (one line, ~60 characters)

> Meeting recordings → structured Markdown notes, entirely on your Mac.

Alternative (shorter):
> Private AI meeting notes. No cloud. No subscriptions within subscriptions.

---

## Short description (~160 characters, shown in Setapp catalogue cards)

> Turn any meeting recording into structured Markdown notes using WhisperKit
> on-device transcription and your own Ollama — everything stays on your Mac.

---

## Full description

Record a meeting or drop any audio file into a watched folder. Distavo
transcribes it with speaker labels, cleans the transcript, and writes a concise
Markdown note with decisions and action points — all without any data leaving
the machines you choose.

**Private by design**
Your recordings and transcripts never leave your Mac. Transcription runs
on-device using WhisperKit (Apple Silicon required for built-in mode).
Summaries use an Ollama server you run yourself — on this Mac or anywhere on
your network. No accounts. No cloud. No telemetry.

**Built-in meeting recorder**
Captures both the meeting audio playing through your Mac and your microphone in
one recording — works with any conferencing tool, nothing to install.
Requires macOS 14.4 or later.

**Folder-watching pipeline**
Point Distavo at a folder and every new recording becomes a note automatically.
Works with iCloud Drive, Dropbox, or any synced folder — record on your phone,
drop the file in, collect the note.

**Choose your transcription engine**
- Built-in on-device (WhisperKit) — six model sizes from Tiny to Large-v3
- Your own WhisperX server — for GPU-accelerated transcription on a NAS or workstation

**Flexible summarisation**
Connect to any Ollama server — local or LAN. Switch models, tune temperature,
keep a fallback. Distavo never sends your content anywhere you haven't configured.

Requires macOS 14 or later.
On-device transcription requires Apple Silicon.
Built-in recorder requires macOS 14.4 or later.
Summarisation requires an Ollama server you run yourself.

---

## Feature list (bullet points for Setapp catalogue)

- Records meetings (mic + system audio) with one click
- Transcribes with speaker labels — on-device or via your own WhisperX server
- Summarises to Markdown notes — decisions and action points
- Folder watcher: drop a file, get a note
- Six WhisperKit model sizes (Tiny → Large-v3)
- Ollama summarisation: local, LAN, or fallback — your choice
- Activity log per recording
- No cloud, no accounts, no telemetry

---

## Keywords

meeting, notes, transcription, recorder, whisper, ollama, summary, markdown,
minutes, private, transcript, AI, local, on-device, meetings

---

## Support URL

https://distavo.com/support/

## Marketing URL

https://distavo.com/

## Privacy policy URL

https://distavo.com/privacy/

---

## What's New (first Setapp version)

First release on Setapp. Distavo is a native macOS menu-bar app that turns your
meeting recordings into structured Markdown notes — using on-device WhisperKit
transcription and a local Ollama server you control. Nothing leaves your machine.

---

## Setapp positioning notes

Setapp users skew toward power users and developers — Distavo's "your own
servers" angle is a feature, not a liability, for this audience. Lean into:
- Privacy (no cloud dependency) — Setapp markets heavily to privacy-conscious users
- Local-first (no subscription-within-subscription) — resonates with Setapp's value prop
- Automation / folder-watch workflow — power-user appeal

Comparable Setapp apps to reference in the application pitch:
- Reeder (media), Bear (notes), Permute (local processing) — all privacy-first, local tools

---

## Setapp field mapping (use this at upload time)

Setapp's dashboard has specific named fields with hard limits — they do **not**
map 1:1 to App Store fields. Slot the copy above into these:

| Setapp field | Limit | Use |
|---|---|---|
| **Description** (public) | 3,000 chars | The polished copy already in `apple/metadata/listing.json` `description` (~1.5k chars, on-brand) — or the "Full description" above. Either fits. |
| **Key Benefits** (internal, team categorisation) | 80 chars | See line below. |
| **Release Notes** (public, Markdown) | 5,000 chars | The "What's New" section above, or `apple/metadata/whats-new/en-GB.txt`. |
| **Comments for Review Team** (internal) | 2,000 chars | The block in `REVIEW_TEAM_NOTES.md` — **important**, explains the Ollama requirement. |
| **Support URL** | — | https://distavo.com/support/ |
| **Promo URL** (Setapp's name for marketing URL) | — | https://distavo.com/ |
| **Screenshots** | ≤ 5, 16:10, ≥ 1280×800 | `apple/metadata/screenshots/*.png` (3× 2560×1600, all compliant). |
| **App icon** | 1024×1024, 824 art + 100px margin, curved corners | `apple/metadata/setapp/AppIcon-setapp.png` (Setapp-spec variant, inset). The build script's bundled `AppIcon.png` is the full-bleed macOS icon — prefer the inset variant for the catalogue. |

There is **no separate 160-char "short description" field** on Setapp — the
tagline/short-description entries above are only source material; drop them into
the Description opening line or the Key Benefits field as needed.

**Key Benefits (≤ 80 chars) — pick one:**
> Private on-device meeting recorder + Markdown notes. No cloud, no account.

(74 chars.) Alternative: `On-device meeting notes: WhisperKit + your own Ollama, nothing leaves your Mac.` (79 chars.)
