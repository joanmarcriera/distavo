# Auto-update (Sparkle) — setup + verification

Distavo's **Direct** edition self-updates with [Sparkle 2](https://sparkle-project.org/). The App
Store and Setapp editions update through their stores and **do not** link Sparkle (verified below).
CI can't exercise a real update (it needs a signed build, a live appcast, and a human to watch the
prompt), so this is the manual checklist — mirroring `docs/meeting-capture-verification.md`.

## What's already wired in the repo

- `project.yml` builds three targets; only **`Distavo`** (Direct) links the Sparkle SPM package.
- `SparkleUpdater` (`apple/Sources/Distavo/Core/`) is compiled `#if EDITION_DIRECT`; `AppUpdaterFactory`
  returns `nil` elsewhere, so the "Check for Updates…" menu item and the "Automatically check for
  updates" settings toggle only appear in the Direct build.
- `apple/Distavo-Direct-Info.plist` carries `SUFeedURL = https://distavo.com/appcast.xml` and an
  **empty** `SUPublicEDKey` (Sparkle refuses updates until it's filled — the safe default).
- `.github/workflows/release.yml` generates + signs `appcast.xml` on tag **iff** the
  `SPARKLE_ED_PRIVATE_KEY` secret exists, and attaches it to the GitHub Release.

## One-time setup (Marc — needs the signing key + hosting)

1. **Generate the EdDSA keypair** with Sparkle's tool (from the `Sparkle-<ver>.tar.xz` release, or
   `brew install --cask sparkle` → `bin/generate_keys`):
   ```sh
   ./bin/generate_keys                 # stores the PRIVATE key in your login Keychain
   ./bin/generate_keys -p              # prints the PUBLIC key (for the plist)
   ./bin/generate_keys -x private.pem  # exports the PRIVATE key to a file (for the CI secret)
   ```
   - Put the **public** key in `apple/Distavo-Direct-Info.plist` → `SUPublicEDKey` (public keys are
     not secret; commit it).
   - Store the **private** key in `~/.tokens` and add it as the GitHub Actions repo secret
     **`SPARKLE_ED_PRIVATE_KEY`**. **Never commit or print the private key.** Then delete `private.pem`.
2. **Host the appcast** at the constant `SUFeedURL` — `https://distavo.com/appcast.xml`. Each Direct
   release attaches the signed `appcast.xml`; publish/sync it to that URL (the enclosure inside it
   already points at the GitHub Release `Distavo.dmg`). SUFeedURL must stay constant, so don't point
   it at a per-release asset URL.
3. **Entitlements check** (Direct is non-sandboxed + hardened runtime + notarized): after the first
   signed build, confirm `codesign -dv --entitlements - Distavo.app` and that Sparkle's XPC helpers
   under `Contents/Frameworks/Sparkle.framework/…/XPCServices` are signed with your Developer ID.
   Add `com.apple.security.cs.disable-library-validation` to `Distavo.entitlements` **only** if
   signature validation of the framework fails — record the outcome here.

## Manual verification (per Sparkle-affecting change)

1. Build the Direct edition **signed + notarized** at the current build N (`scripts/build-and-notarize.sh`
   or the `release.yml` dry run).
2. Prepare a **test appcast** advertising build **N+1** (sign a dummy N+1 DMG with the same key) and
   serve it at a URL; temporarily point `SUFeedURL` there (or edit the installed app's Info.plist).
3. Launch Distavo → menu ▸ **Check for Updates…** → confirm: the update is found, the signature
   verifies, it downloads, and the app relaunches into N+1.
4. In **Settings ▸ Updates**, toggle **Automatically check for updates** off/on and confirm it
   persists across relaunch (Sparkle stores `SUEnableAutomaticChecks`).
5. Confirm a **bad signature is rejected**: serve an appcast whose `edSignature` doesn't match and
   confirm Sparkle refuses the update.

## Edition isolation (verifiable unsigned — already checked on this branch)

Build each edition and confirm only Direct carries Sparkle:

```sh
cd apple && xcodegen generate
# Direct
xcodebuild -scheme Distavo -configuration Release -xcconfig configs/Direct.xcconfig \
  -derivedDataPath build-direct CODE_SIGNING_ALLOWED=NO build
# App Store
xcodebuild -scheme Distavo-AppStore -configuration Release-AppStore \
  -derivedDataPath build-as CODE_SIGNING_ALLOWED=NO build
# Setapp
xcodebuild -scheme Distavo-Setapp -configuration Release \
  -derivedDataPath build-setapp CODE_SIGNING_ALLOWED=NO build

# Expect: Sparkle.framework ONLY in the Direct app; App Store/Setapp have none.
ls build-direct/Build/Products/Release/Distavo.app/Contents/Frameworks | grep -i sparkle   # Sparkle.framework
ls build-as/Build/Products/Release-AppStore/Distavo.app/Contents/Frameworks | grep -i sparkle || echo "none"
ls build-setapp/Build/Products/Release/Distavo.app/Contents/Frameworks | grep -i sparkle || echo "none"
```

All three must ship as `Distavo.app`; Setapp keeps its `-setapp` bundle id and `NSUpdateSecurityPolicy`.
