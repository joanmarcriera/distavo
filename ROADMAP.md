# Roadmap

Seshat is a native Swift/SwiftUI menu-bar app that ships in three editions from
one codebase. Distribution moves from a notarized direct download toward Setapp
and the Mac App Store. The detailed, copy-pasteable shipping steps live in
[`docs/distribution-checklist.md`](docs/distribution-checklist.md).

## Phase 1 — Native app + open source (current)

- Native Swift/SwiftUI rewrite with a UI-free `SeshatCore` package (no GPL
  dependencies — AVFoundation replaces ffmpeg, so the app can ship on the App
  Store).
- Public GitHub repository under an MIT license, CI, issue/PR templates, and
  contribution guidelines in place.
- Three build editions wired via `apple/configs/{Direct,Setapp,AppStore}.xcconfig`
  with reverse-DNS bundle IDs `uk.co.riera.seshat` / `uk.co.riera.seshat-setapp`.

## Phase 2 — Direct download (notarized)

- Developer ID signed, **notarized**, stapled `.app` / DMG published on GitHub
  Releases.
- Optional [Sparkle](https://sparkle-project.org/) auto-update for the Direct
  edition.

## Phase 3 — Setapp

- Link the Setapp Framework into the `-setapp` bundle (gated behind
  `EDITION_SETAPP`), upload the first build via the Setapp Web UI, pass review.

## Phase 4 — Mac App Store

- Sandboxed build (security-scoped bookmarks for the watched folders), Apple
  Distribution signing + provisioning profile, App Store Connect record, and
  App Review.
- Donations on the App Store would require StoreKit In-App Purchase (consumable
  "tip" products) — the external donate link is Direct-only and must stay gated.

Each phase's exact commands and credential prerequisites are in the
distribution checklist.
