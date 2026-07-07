# Spec B — Direct-edition Sparkle auto-update

Date: 2026-07-07
Status: approved (design), implement after Slice A merges
Slice: B of 2 (touches build-system structure, release pipeline, and a signing secret)

## Goal

Add in-app "Check for Updates…" to the **Direct** edition using **Sparkle 2**, with an
"Automatically check for updates" preference. Setapp and the Mac App Store manage their own updates,
so the feature is hidden there and Sparkle is never linked into those builds.

This matches `docs/distribution-checklist.md` §2.7 (Sparkle is Direct-only; Setapp ships its own
updater; the App Store updates through the store).

## The key structural constraint

Sparkle must be **linked/embedded only in the Direct build**:
- Embedding Sparkle in the **App Store** build risks rejection (it bundles the Autoupdate/Installer
  XPC helpers — an update mechanism outside the store) and breaks the sandbox signing model.
- **Setapp** forbids third-party updaters; it ships its own and requires `NSUpdateSecurityPolicy`
  (already in `apple/Setapp-Info.plist`).

XcodeGen links dependencies per **target**, not per **config**. Today `apple/project.yml` has a
single `Distavo` target with per-config xcconfigs (Direct/AppStore), and Setapp is a command-line
`-xcconfig configs/Setapp.xcconfig` override of the Direct config. A single target cannot link
Sparkle for Direct only.

### Resolution — edition-specific targets via a shared template

Split into three targets sharing one `targetTemplates` entry (identical `sources`/`settings`,
differing only in `configFiles` + `dependencies`):

| Target            | configFile          | Sparkle | Notes                                             |
|-------------------|---------------------|---------|---------------------------------------------------|
| `Distavo`         | `Direct.xcconfig`   | **yes** | Direct DMG                                         |
| `Distavo-Setapp`  | `Setapp.xcconfig`   | no      | promotes today's CLI override to a real target    |
| `Distavo-AppStore`| `AppStore.xcconfig` | no      | sandboxed store build                             |

- Schemes `Distavo` and `Distavo-AppStore` already exist and keep their names → **CI is unaffected**
  (it archives those scheme names). Add a `Distavo-Setapp` scheme.
- Verify the generated `.xcodeproj` shows Sparkle only under the `Distavo` target's Frameworks.
- Regenerate with `xcodegen generate`; re-run the unsigned Direct + AppStore builds in CI to confirm
  the split didn't break the app target.

## In-app integration

### Updater seam (keeps Sparkle out of shared code)

```swift
protocol AppUpdater { func checkForUpdates(); var automaticChecks: Bool { get set } }
```

- `SparkleUpdater` wraps `SPUStandardUpdaterController(startingUpdater: true, …)`; compiled
  `#if EDITION_DIRECT`. `checkForUpdates()` → `updater.checkForUpdates()`; `automaticChecks` proxies
  `updater.automaticallyChecksForUpdates`.
- No updater and no menu item in Setapp/App Store builds.

### UI

- `StatusMenu.swift`: add `Button("Check for Updates…")` inside `#if EDITION_DIRECT`, calling the
  updater. Place it in the Help menu or above "Settings…".
- `SettingsView.swift`: a `#if EDITION_DIRECT` "Automatically check for updates" `Toggle` bound to the
  updater's `automaticChecks`.

## Config, signing, entitlements (Direct only)

- Direct-only Info.plist keys (via a Direct-only supplemental plist, mirroring the existing
  `Distavo-Extra-Info.plist` merge):
  - `SUFeedURL` = **`https://distavo.com/appcast.xml`** (stable, on our own domain; the appcast's
    `<enclosure>` points at the GitHub Release DMG).
  - `SUPublicEDKey` = the EdDSA **public** key from Sparkle's `generate_keys`.
- **EdDSA keypair**: generate with Sparkle's `generate_keys`. Private key stored in `~/.tokens` (and
  a GitHub Actions secret for the release workflow) — **never committed, never printed**. Public key
  goes only in the plist.
- Hardened-runtime review: the Direct build is non-sandboxed + hardened runtime + notarized. Confirm
  Sparkle's XPC helpers are signed with the Developer ID and that no extra entitlement is needed
  (add `com.apple.security.cs.disable-library-validation` only if signing verification requires it).
  Capture the outcome in the verification doc.

## Release pipeline

After the tag-triggered workflow notarizes + staples the Direct DMG, add a step that:

1. Runs Sparkle's `generate_appcast` over the release artifact (reads the private key from the CI
   secret) to produce/update `appcast.xml` with the signed `<enclosure>` (`sparkle:edSignature`,
   length, `sparkle:version` = build, `sparkle:shortVersionString`).
2. Publishes `appcast.xml` to `distavo.com` (deploy per `riera-selfhost-ops`). The DMG enclosure URL
   points at the GitHub Release asset.

Requires the EdDSA private key as a repo secret and (optionally) release notes in the appcast item.
This is why Slice B is separate: it touches CI and a signing secret.

## Verification (manual — cannot run in CI)

New `docs/update-verification.md`, mirroring `docs/meeting-capture-verification.md`:

1. Build the Direct edition signed + notarized at build N.
2. Point `SUFeedURL` at a test appcast advertising build N+1 (signed with the same key).
3. Launch → "Check for Updates…" → confirm the update prompt appears, downloads, verifies the
   signature, and relaunches into N+1.
4. Confirm the "Automatically check for updates" toggle persists and schedules background checks.
5. Confirm the App Store and Setapp builds contain **no** Sparkle framework (`ls …/Contents/Frameworks`)
   and show **no** "Check for Updates" item.

## Human-gated steps (need Marc)

- Generating the EdDSA keypair and placing the private key in `~/.tokens` + a GitHub Actions secret.
- Hosting `appcast.xml` on distavo.com (infra) and adding the release-workflow secret.
- The manual auto-update verification above (needs a signed build + a human to watch the prompt).

Everything else (target split, Sparkle wiring, plist, menu/settings UI, appcast tooling, docs) is
implementable and reviewable without those.

## Files touched

- `apple/project.yml` — target template + three targets + `Distavo-Setapp` scheme; Sparkle package on
  Direct only. Regenerate the project.
- `apple/Sources/Distavo/Core/` — `AppUpdater` + `SparkleUpdater` (`#if EDITION_DIRECT`).
- `apple/Sources/Distavo/Menu/StatusMenu.swift`, `Settings/SettingsView.swift` — gated UI.
- Direct-only supplemental plist for `SUFeedURL`/`SUPublicEDKey`.
- Release workflow under `.github/workflows/` — appcast generate + publish step.
- `docs/update-verification.md` — manual checklist. Update `docs/distribution-checklist.md` §2.7 to
  point at it.

## Out of scope

Delta updates tuning, staged rollouts, in-app release-notes styling beyond the default Sparkle UI,
auto-update for Setapp/App Store (handled by those stores).
