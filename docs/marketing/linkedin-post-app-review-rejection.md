# LinkedIn follow-up post: the App Review 2.1(a) rejection, in depth

> **Draft - not posted; needs Marc's voice pass.** Refreshed 2026-10-16 for
> Vikunja #1008 (first drafted 2026-09-17; it was meant for July, so the
> "launch follow-up" framing is gone and it now reads as a lessons-learned post
> written after several releases). Never post from a script; Marc posts it.

Facts below are sourced only from this repo: `docs/permissions-helper-verification.md`,
`PROJECT_STATE.md`, `DECISIONS.md`, and the commit history (`d57ac72`, `1eba716`,
`e21d9c6`, `be08e2e`, `17a6010`).

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
  (1.18.0) postdates that submission by several releases, so the resubmission
  went through. No specific approval date is recorded in the repo, so none is
  claimed below.

---

## Main version

Months ago, App Review rejected an early Distavo build. It is the most useful bug report I have had.

Distavo turns a meeting recording into a Markdown note. The summary step uses an Ollama server, and the reviewer's Mac had none. Settings showed two red dots next to "Server Ollama" and "Local Ollama", and nothing else. Apple rejected the build under guideline 2.1(a): from where they sat, the app looked broken.

Fair. Recording and transcription worked fine without Ollama. The app just never said so. A red dot with no context is a UX bug.

What I changed:
- The no-server state became guidance, not failure: amber instead of red, with a line saying Ollama isn't running, that recording and transcription still work, and how to point Distavo at a server.
- A "Check permissions..." sheet now explains Local Network and microphone access in one place, instead of sending people to a dead end in System Settings.
- A second, smaller rejection came for a button that said "Request Access" in my own microphone pre-prompt. Apple wants neutral wording, so it now says "Continue".

What I took from it: App Review is a decent stand-in for a first-time user who has none of my setup. If a screen only makes sense on my machine, I have a bug.

Distavo has been on the Mac App Store since. The source is MIT on GitHub, and everything runs on your own Mac.
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
