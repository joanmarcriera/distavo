---
name: distavo-release
description: Use when cutting a Distavo release — tagging a v* version, updating apple/metadata/whats-new/en-GB.txt, bumping MARKETING_VERSION/CURRENT_PROJECT_VERSION in apple/project.yml, running or approving release.yml / release-appstore.yml / submit-appstore.yml, the app-store-submission GitHub environment approval gate, or a Setapp manual upload. Trigger phrases: "cut a release", "tag a new version", "ship v1.x.x", "update What's New", "approve the App Store submission", "bump the version", "Setapp upload". Complements (does not duplicate) the mac-appstore-submission-api skill, which owns the App Store Connect REST API detail.
---

# Distavo release

One codebase, three channels, one `v*` git tag fires two GitHub Actions workflows at once.

## Before tagging — MUST update What's New

```sh
$EDITOR apple/metadata/whats-new/en-GB.txt
```

`release-appstore.yml`'s first step (`Preflight — What's New release notes present`) hard-fails
(`exit 1`) if this file is missing or empty (`[ -s "$f" ]`) — **before** the ~20-minute build, so
fix it here, not after a failed run. Bullet style, no version header (see the file for current
tone).

## Version bump — check reality, not the docs

`apple/project.yml` holds `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. `docs/release-automation.md`
still documents "every non-bot push to `main` gets a bot commit that bumps the minor version" —
but **`.github/workflows/version-bump.yml` is now `on: workflow_dispatch` only.** Dev moved to
self-hosted Forgejo (`git.riera.co.uk`); GitHub is a push-mirror, and an automatic push trigger
would also fire on mirrored pushes and diverge from the mirror source. Treat the workflow file as
ground truth over the doc table. Bump manually:

```sh
python3 scripts/bump-minor-version.py     # bumps apple/project.yml, docs/setapp-submission.md,
                                            # ops/site/index.html; prints NEW_MARKETING_VERSION=
git commit -am "chore(release): bump version to X.Y.Z (build N) [skip version bump]"
```

The `[skip version bump]` trailer matters even manually — it's what the (currently dormant)
auto-bump job checks for.

## Tag → two workflows fire

```sh
git tag v1.10.0 && git push origin v1.10.0
```

**`release.yml` (Direct DMG)** — `macos-latest`, single job:
imports the Developer ID cert → `xcodegen generate` → archive `-scheme Distavo -configuration
Release -xcconfig configs/Direct.xcconfig` → export (`developer-id` method) → `notarytool submit
--wait` + `stapler staple` the **app**, then build + notarize + staple the **DMG** →
`spctl -a -vvv --type exec` Gatekeeper check → (if `SPARKLE_ED_PRIVATE_KEY` is set) sign a Sparkle
appcast, else silently skip — **check this secret exists before assuming Direct auto-update
actually ships** → `gh release create`/`upload`. Secrets: `APPLE_TEAM_ID`,
`DEVELOPER_ID_CERT_P12_BASE64`, `DEVELOPER_ID_CERT_PASSWORD`, `APPLE_ID`,
`APPLE_NOTARY_PASSWORD`. `workflow_dispatch` (no tag) = dry run, uploads the DMG as a build
artifact only, no GitHub Release.

**`release-appstore.yml` (App Store upload)** — two jobs:
1. `upload-appstore` (`macos-latest`, 30 min timeout): preflights the What's New file + all 8
   secrets, imports **both** `Apple Distribution` (signs the `.app`) and `3rd Party Mac Developer
   Installer` (signs the `.pkg`) certs into one throwaway keychain, installs the ASC API key +
   Mac App Store provisioning profile (validated: team ID, app ID `TEAMID.uk.co.riera.distavo`,
   `get-task-allow=false`), archives `-scheme Distavo-AppStore`, checks the archive embeds
   `Contents/embedded.provisionprofile` (else `TestFlight`-ineligible per ITMS-90889), exports the
   signed `.pkg`, re-checks the payload for that same file, then `altool --upload-app` — and
   greps the upload log for `90889`/"missing a provisioning profile" as a **hard failure even on
   exit 0** (Apple can accept-with-warning).
2. `submit-for-review` (`ubuntu-latest`, needs job 1): sits behind the **`app-store-submission`**
   GitHub environment — configure a required reviewer there once; every release then needs
   **one Approve click** on that environment, after which
   `python3 scripts/submit-appstore-review.py --until submit` runs. The version's `releaseType` is
   `AFTER_APPROVAL`, so it goes live automatically once Apple approves — no second click.

**Retry path** — `submit-appstore.yml`: manual `workflow_dispatch`, `dry_run` **defaults true**,
`until` picks a stop phase (`processed|compliance|version|attach|submit`). Use it if processing
timed out, after fixing an App Review rejection, or to stage-test before a real submission. Same
ASC secrets as `release-appstore.yml`.

## Setapp — stays manual

The **first** Setapp version must be uploaded through the Setapp Web UI (needs Marc's vendor
account; see `docs/setapp-submission.md` §4.1) — not scriptable, Setapp's own rule. Later versions
can be scripted once that first upload exists. The `Distavo-Setapp` scheme/xcconfig is already
release-ready (`configs/Setapp.xcconfig`, bundle ID `uk.co.riera.distavo-setapp`) — only the
upload step is manual.

## Gotchas

- All three editions ship as `Distavo.app` (`PRODUCT_NAME`) but only two bundle IDs exist
  (`uk.co.riera.distavo` for Direct + App Store, `uk.co.riera.distavo-setapp` for Setapp) — don't
  assume one bundle ID per edition.
- `CODE_SIGN_STYLE: Manual` everywhere; `DEVELOPMENT_TEAM` is deliberately blank in
  `apple/project.yml` and injected only via `DEVELOPMENT_TEAM=...` on the CI `xcodebuild` line.
- For the App Store Connect REST mechanics themselves (submission state machine, the 409 traps,
  age-rating/pricing/privacy prerequisites) — see the `mac-appstore-submission-api` skill; this
  skill only covers Distavo's CI wiring around it.
- Full secrets list + one-time Apple/Setapp setup: `docs/release-automation.md` and
  `docs/distribution-checklist.md`.
