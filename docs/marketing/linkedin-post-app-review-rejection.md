# LinkedIn follow-up post — the App Review 2.1(a) rejection, in depth

Drafted 2026-09-17, for Vikunja #1008 (the "second touch ~1 week later" follow-up
listed in `linkedin-launch-post.md`). Facts below are sourced only from this repo:
`docs/permissions-helper-verification.md`, `PROJECT_STATE.md`, and the commit
history (`d57ac72`, `1eba716`, `e21d9c6`, `be08e2e`, `17a6010`).

Story facts used:
- Build 1.8.0 (build 9) was tested by an App Review reviewer whose Mac had no
  Ollama server. Settings showed both the "Server Ollama" and "Local Ollama"
  status dots red with no explanation, and Distavo did not appear in the
  Local Network privacy pane the app pointed at. Apple rejected under
  guideline 2.1(a).
- Fix (commit `d57ac72`, "present no-server state as guidance, not failure"):
  the dots go amber instead of red when nothing is configured beyond
  loopback, with an inline explanation that Ollama isn't running, that
  recording/transcription still work, and how to point Distavo at a server.
- The in-app Permissions helper ("Check permissions…" sheet, commit
  `1eba716`) explains and fixes Local Network and microphone/system-audio
  access in one place instead of leaving a dead end in System Settings.
- A second, separate rejection hit 1.9.0 (build 10): Apple objected to the
  custom microphone pre-prompt action label "Request Access" and asked for
  neutral wording. Fixed in commit `e21d9c6` ("use neutral permission prompt
  actions") — the button now reads "Continue", shipped as 1.9.1 (build 11).
- 1.9.1 build 11 was resubmitted and reported `Waiting for Review` in
  `PROJECT_STATE.md`; the app is confirmed live on the Mac App Store per
  `CLAUDE.md` ("Mac App Store (live)") and the current shipped version
  (1.13.0) postdates that submission by several releases, so the resubmission
  went through. No specific approval date is recorded in the repo, so none is
  claimed below.

---

## Main version (1,295 characters)

A follow-up to the Distavo App Store launch: the review rejection, in full.

Distavo needs Ollama running locally or on a server to summarise a meeting. The reviewer's test Mac had neither. Settings showed two red dots next to "Server Ollama" and "Local Ollama" — and nothing else. No explanation of what was wrong or what to do about it. Apple rejected the build under guideline 2.1(a): from where they sat, the app looked broken.

Fair. A red dot with no context is a UX bug, even though the underlying behaviour was correct — recording and transcription still work without Ollama.

The fix had three parts:
- The no-server state became guidance, not failure: the dots turn amber, with an inline note explaining Ollama isn't running, that recording/transcription still happen, and how to point Distavo at a server.
- A "Check permissions…" sheet was added, so Local Network and microphone access are explained and fixable in one place instead of a dead end in System Settings.
- The microphone pre-prompt's "Request Access" button became "Continue" — Apple's recommended wording — after that drew a second rejection.

Resubmitted, and it went through. Distavo is free and open source, on the Mac App Store:
https://apps.apple.com/us/app/distavo/id6785437932

#macOS #Swift #AppStore

---

## Alternative, shorter version (591 characters)

The one Distavo App Review rejection, briefly.

The reviewer's Mac had no Ollama running. Settings showed two red dots and no explanation — fair grounds for a guideline 2.1(a) rejection, since recording/transcription still work without it, but nothing said so.

Fix: the no-server state now explains itself (amber, not red), a "Check permissions…" sheet handles Local Network/microphone access, and the mic pre-prompt says "Continue" instead of "Request Access" (a second, smaller rejection).

Resubmitted, approved.

https://apps.apple.com/us/app/distavo/id6785437932

#macOS #AppStore

---

## Image/screenshot suggestion

`apple/metadata/screenshots/03-settings-continued.png` — it's the only existing
screenshot that shows the actual "Connections" panel with the "Server Ollama" /
"Local Ollama" status dots and the "Check permissions…" button, i.e. the exact
UI the story is about.

## Comment-bait replies (post under the LinkedIn post)

1. "The part that got me: the underlying behaviour was already right (no
   Ollama just means recording/transcription without a summary) — the bug
   Apple caught was purely that the UI didn't say so. Anyone else found App
   Review is often a decent proxy for 'would a first-time user understand
   this screen'?"
2. "Two rejections back to back for the same build cycle: one on the red
   dots, one on a button that said 'Request Access' instead of 'Continue'.
   Small wording, but Apple clearly has a house style for permission
   prompts. Worth checking yours against it before you submit, not after."
3. "Genuinely curious what other reviewers have hit with guideline 2.1(a) —
   is 'silent failure state with no explanation' a common flag, or did I get
   an especially thorough reviewer?"
