# Project State

## Current objective

Update `distavo.com` for the 1.1.0 App Store submission and move the Setapp
edition as far as possible without vendor-dashboard assets.

## Completed work

- App Store 1.1.0 build 2 was uploaded from CI in the previous cycle.
- Static website source was added under `ops/site`.
- Setapp submission playbook now reflects repo-side metadata and packaging
  work that can be automated.
- Setapp Release build validation passes unsigned and produces a universal
  `x86_64 arm64` app with the expected Setapp Info.plist keys.
- `swift test` passes for `apple/DistavoCore`.
- `ops/site` is deployed and live at `https://distavo.com/`.

## Current implementation state

- `ops/site` is deployed as the public static website.
- The Setapp build uses `apple/Setapp-Info.plist` for Setapp-only metadata,
  including `NSUpdateSecurityPolicy`.
- `apple/scripts/build-and-notarize.sh setapp` packages a notarized app with
  `Distavo.app` and `AppIcon.png` in the final upload zip.

## Files changed

- `ops/site/`
- `apple/Setapp-Info.plist`
- `apple/configs/Setapp.xcconfig`
- `apple/scripts/build-and-notarize.sh`
- `docs/setapp-submission.md`
- `PROJECT_STATE.md`
- `TASKS.md`
- `DECISIONS.md`

## Tests run

- `plutil -lint apple/Setapp-Info.plist` — passed.
- `bash -n apple/scripts/build-and-notarize.sh` — passed.
- Static website link/asset/title/meta parser over `ops/site` — passed.
- `git diff --check` — passed.
- `cd apple && xcodegen generate` — passed.
- `cd apple && xcodebuild -project Distavo.xcodeproj -scheme Distavo -configuration Release -derivedDataPath build/SetappValidation -xcconfig configs/Setapp.xcconfig CODE_SIGNING_ALLOWED=NO build` — passed unsandboxed after the sandbox blocked Swift/Xcode cache writes.
- Built Setapp app metadata check — passed: bundle id `uk.co.riera.distavo-setapp`, version `1.1.0`, build `2`, icon key, `LSUIElement`, and `NSUpdateSecurityPolicy`.
- `lipo -info apple/build/SetappValidation/Build/Products/Release/Distavo.app/Contents/MacOS/Distavo` — passed: `x86_64 arm64`.
- Simulated Setapp zip extraction — passed: root contains `Distavo.app` and `AppIcon.png`.
- `cd apple/DistavoCore && swift test` — passed unsandboxed: 62 tests, 1 live E2E skipped.
- Clean `ops/site` tarball deployed to `/opt/stacks/core/distavo` on the
  existing server. Current remote backup is
  `/tmp/distavo-site-backup-20260629T165646Z`.
- Live HTTPS check for `https://distavo.com/`, `/privacy/`, `/support/`,
  `/feedback/`, `/assets/site.css`, and `/assets/settings.png` — passed.

## Unresolved risks

- Setapp Framework integration still requires the vendor dashboard public key
  and SDK archive.
- The first Setapp build must still be uploaded through the Setapp Web UI.

## Known blockers

- Marc must create or access the Setapp vendor account, choose the distribution
  model, and provide the Setapp Framework/public key assets.

## Next recommended action

Commit and push the completed slice.
