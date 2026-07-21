# LinkedIn launch post — Distavo on the Mac App Store

Drafted 2026-07-21. Facts verified against the repo and the live store listing
(v1.4.0, released 2026-07-13, https://apps.apple.com/us/app/distavo/id6785437932).

**Status: Variant A scheduled via Postiz** (postId `cmrunm074000any6z2l17jg6c`) to
Marc's personal LinkedIn for 2026-07-22 07:15 UTC, with the `01-main-menu.png`
screenshot attached; bullets converted to `•` for LinkedIn plain-text rendering.
Tracking: Vikunja tasks #1006 (verify publish), #1007 (stale site copy), #1008
(follow-up touch).

---

## Variant A (main, ~200 words)

I didn't set out to launch a product. I wanted to see, end to end, what it takes to ship native code through every one of Apple's validations until it actually appears on the App Store.

So I wrote Distavo — and three weeks after the first commit, it's live.

What "all their validations" turned out to mean:

- The name I picked was already taken on the store. Renamed the whole app.
- ffmpeg's licence would have blocked distribution. Rewrote audio conversion on AVFoundation.
- TestFlight rejected a build over a missing provisioning profile. The CI pipeline now checks for it before upload.
- App Sandbox, entitlements, hardened runtime, notarization — each one earned separately.
- One real App Review rejection: the reviewer's Mac saw two red status dots and no explanation. Fair point. Redesigned that state as guidance instead of failure.
- Even submission itself I ended up automating through the App Store Connect REST API.

The app that came out of it: a native macOS menu-bar tool that records meetings and turns them into clean Markdown notes. On-device transcription, summaries via your own Ollama server. No accounts, no cloud, no telemetry.

It's free, and open source (MIT).

App Store: https://apps.apple.com/us/app/distavo/id6785437932
Site: https://distavo.com

#macOS #Swift #AppStore #privacy #buildinpublic

---

## Variant B (short, ~90 words)

Small personal milestone: Distavo is live on the Mac App Store.

The honest motivation wasn't a product launch — I wanted to walk the full path of shipping native code on Apple's platform: Swift, sandboxing, entitlements, notarization, provisioning, App Review (including one rejection, fixed), and automating the submission through the App Store Connect API.

The artifact: a free, open-source menu-bar app that turns meeting recordings into Markdown notes — entirely on-device, no accounts, no cloud, no telemetry.

https://apps.apple.com/us/app/distavo/id6785437932 · https://distavo.com

#macOS #Swift #AppStore #privacy

---

## Image suggestion

Attach `apple/metadata/screenshots/01-main-menu.png` (the menu-bar UI — most
recognisable as "a real shipped Mac app"), or a screenshot of the live App Store
listing page itself, which underlines the "it appears in their store" point.

## Follow-ups (per launch checklist)

- Fix stale distavo.com copy: it still says the App Store edition is "working
  through review" — it's live as of 2026-07-13.
- Second touch ~1 week later: the App Review rejection story in more depth
  (guideline 2.1(a) → "present no-server state as guidance, not failure").
