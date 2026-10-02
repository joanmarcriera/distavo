# Distavo — Release automation

How much of shipping Distavo is unattended, what you push to trigger it, and the
one-time secrets each pipeline needs. The mechanical steps in
`docs/distribution-checklist.md` are what these workflows automate.

## What's automated vs manual

| Stage | Channel | Automated? | Trigger |
| --- | --- | --- | --- |
| Build + test (all 3 editions) | — | ✅ fully | every push / PR (`ci.yml`) |
| Bump releasable version | — | ✅ fully | every non-bot push to `main` (`version-bump.yml`) |
| Sign → notarize → DMG → GitHub Release | **Direct** | ✅ fully (once secrets set) | push a `v*` tag (`release.yml`) |
| Build → sign → upload → submit to App Review | **App Store** | ✅ upload fully; submission behind **one Approve click** (`app-store-submission` environment); release is automatic once Apple approves | push a `v*` tag (`release-appstore.yml`) |
| Retry / staged-test an App Review submission | **App Store** | ✅ on demand (`dry_run` defaults on) | Actions → "Submit to App Review (manual)" (`submit-appstore.yml`) |
| Submit build | **Setapp** | ❌ first version is Web-UI only; later versions scriptable | manual — see `setapp-submission.md` |

Every merge to `main` gets a follow-up bot commit that bumps
`MARKETING_VERSION` by one minor version (`1.1.0` → `1.2.0`, patch reset to
zero) and increments `CURRENT_PROJECT_VERSION` by one build number. Update
`apple/metadata/whats-new/en-GB.txt` (the App Store "What's New" text — the
workflow refuses to run without it), then push **one tag** for the version
already on `main` (`git tag v1.2.0 && git push origin v1.2.0`) and both release
workflows fire: a notarized DMG lands on GitHub Releases, and the App Store
build uploads to App Store Connect, after which the workflow **pauses** until
you press Approve on the `app-store-submission` environment — that single click
replaces the old manual ASC steps (attach build, export compliance, Submit for
Review). Release is automatic once Apple approves (`releaseType:
AFTER_APPROVAL`). Setapp's first upload stays manual by Setapp's own rules.

> These workflows are validated for YAML/shell syntax but **cannot be run end-to-end
> until the secrets below exist and the Apple/App-Store-Connect setup in
> `distribution-checklist.md` §1 + §4.1 is done.** Do a `workflow_dispatch` dry run
> of `release.yml` first — it builds and notarizes a DMG as an artifact without
> publishing a Release.

## One-time prerequisites (you, once)

From `distribution-checklist.md` §1 + §4.1:
- **Developer ID Application** certificate (Direct/Setapp signing).
- **Apple Distribution** *and* **3rd Party Mac Developer Installer** certificates + an
  App record for `uk.co.riera.distavo` in App Store Connect. A Mac App Store `.pkg`
  needs both: the first signs the `.app`, the second signs the `.pkg` installer.
- A **Mac App Store provisioning profile** for `uk.co.riera.distavo`. App Store
  Connect can accept delivery without it, but Apple reports ITMS-90889 and the
  build cannot be used with TestFlight unless the main `.app` bundle embeds it.
- An **App-Specific Password** (notarization) and an **App Store Connect API key**
  (.p8, App Manager role — used for App Store upload).

## Secrets to add

Repo → **Settings → Secrets and variables → Actions → New repository secret**.
Never commit these; never paste them in chat — add them yourself in the GitHub UI.

### `release.yml` (Direct DMG)
| Secret | What it is / how to make it |
| --- | --- |
| `APPLE_TEAM_ID` | 10-char Team ID (developer.apple.com → Membership). |
| `DEVELOPER_ID_CERT_P12_BASE64` | Export the **Developer ID Application** identity from Keychain Access as `.p12`, then `base64 -i cert.p12 \| pbcopy`. |
| `DEVELOPER_ID_CERT_PASSWORD` | The password you set when exporting that `.p12`. |
| `ASC_API_KEY_ID` / `ASC_API_ISSUER_ID` / `ASC_API_KEY_P8_BASE64` | App Store Connect API key — also used by `notarytool --key` in `release.yml` (the Apple ID + app-specific password path expired → HTTP 401 on v1.15.0). |

### `release-appstore.yml` (App Store upload)
| Secret | What it is / how to make it |
| --- | --- |
| `APPLE_TEAM_ID` | Same as above (shared). |
| `APPLE_DISTRIBUTION_CERT_P12_BASE64` | Export the **Apple Distribution** identity (signs the `.app`) as `.p12`, base64 it. |
| `APPLE_DISTRIBUTION_CERT_PASSWORD` | That `.p12`'s export password. |
| `APPLE_INSTALLER_CERT_P12_BASE64` | Export the **3rd Party Mac Developer Installer** identity (signs the `.pkg`) as `.p12`, base64 it. Required — a Mac App Store submission is a signed installer. |
| `APPLE_INSTALLER_CERT_PASSWORD` | That `.p12`'s export password. |
| `MAC_APP_STORE_PROVISIONING_PROFILE_BASE64` | Download the **Mac App Store** provisioning profile for `uk.co.riera.distavo`, then `base64 -i Distavo_AppStore.provisionprofile \| pbcopy`. The workflow validates team id, app id, and `get-task-allow=false`, installs it, and verifies the archive/pkg embed it. |
| `ASC_API_KEY_ID` | App Store Connect → Users and Access → Integrations → App Store Connect API → key **Key ID**. |
| `ASC_API_ISSUER_ID` | The **Issuer ID** on that same page. |
| `ASC_API_KEY_P8_BASE64` | The downloaded `AuthKey_XXXX.p8`, base64'd (`base64 -i AuthKey_XXXX.p8`). Used by `altool` for upload to App Store Connect. |

## How `release.yml` works (Direct)
1. Imports the Developer ID cert into a throwaway keychain.
2. `xcodegen generate` → archive the Direct edition with `Developer ID Application`.
3. Export (`developer-id`), zip the app, `notarytool submit --wait`, `stapler staple`.
4. `hdiutil` a DMG, notarize + staple **the DMG too** (trusted offline).
5. Gatekeeper assess (`spctl`), then `gh release create <tag>` with the DMG.
   A `workflow_dispatch` run stops at step 4 and uploads the DMG as an artifact (dry run).

## How `release-appstore.yml` works
1. Imports **both** signing certs (Apple Distribution + 3rd Party Mac Developer
   Installer) into a throwaway keychain, installs the Mac App Store provisioning
   profile, and installs the ASC API key.
2. Archives the `Distavo-AppStore` scheme with **Manual** signing, pinned to the
   Apple Distribution identity and the installed provisioning profile. The
   scheme pins `AppStore.xcconfig` (sandboxed edition). The workflow fails if
   the archive is missing `Distavo.app/Contents/embedded.provisionprofile`.
3. Exports a signed `.pkg` (`method: app-store-connect`) with the two signing identities
   **pinned explicitly** — `Apple Distribution` for the `.app`, `3rd Party Mac Developer
   Installer` for the `.pkg` (a bare automatic export mis-selects the installer cert for
   code signing) — and the provisioning profile pinned by UUID. The workflow
   fails if the exported package payload is missing `embedded.provisionprofile`.
   Then it uploads with `xcrun altool --upload-app`.
4. A second job (`submit-for-review`, cheap `ubuntu-latest`) waits for you to
   **Approve** the `app-store-submission` environment (repo Settings →
   Environments; required reviewer, bills nothing while paused), then runs
   `scripts/submit-appstore-review.py`: waits for Apple to finish processing
   the build, sets export compliance (`ITSAppUsesNonExemptEncryption=false` is
   also declared in `Distavo-Extra-Info.plist`), creates or renames the
   editable version record (`releaseType: AFTER_APPROVAL`), sets "What's New"
   from `apple/metadata/whats-new/` (skipped on the first-ever version — Apple
   forbids it), attaches the build, and submits via the Review Submissions API.
   Every step is idempotent — re-run on failure, or drive it by hand with
   `submit-appstore.yml` (Actions → "Submit to App Review (manual)", `dry_run`
   defaults **on**; `until` stages the run: `processed` → `compliance` →
   `version` → `attach` → `submit`).

## Local equivalent
`apple/scripts/build-and-notarize.sh {direct|setapp}` does the same Developer ID signing
+ notarization from your Mac (uses your Xcode-logged-in account / a `notarytool`
keychain profile instead of CI secrets) — handy for a one-off or to debug before tagging.
For App Store uploads, follow `docs/distribution-checklist.md` §4.4 or the
`release-appstore.yml` workflow because they explicitly pin and verify the Mac
App Store provisioning profile.

To preview or apply the same main-merge version bump locally:

```bash
python3 scripts/bump-minor-version.py --dry-run
python3 scripts/bump-minor-version.py
```

## What stays manual (and why)
- **The Approve click** on the `app-store-submission` environment — deliberate
  safety gate so a bad tag can never reach App Review on its own. (Apple does
  *not* require manual submission — the Review Submissions API handles it —
  but Apple's own review/approval of the app is of course still Apple's.)
- **Setapp first upload** — Setapp only accepts the first version via its Web UI
  (`setapp-submission.md`); later versions can be scripted via its REST API.
- **Trademark clearance** on "Distavo" — a hard gate before any store submission.

## Appcast hosting (Direct edition)

`release.yml` signs `appcast.xml` and attaches it to the GitHub Release, then its last step
(`Publish appcast to distavo.com`) runs `ops/publish-appcast.sh <tag>` to copy it to the constant
`SUFeedURL` (`https://distavo.com/appcast.xml`). Without that copy, shipped Direct builds keep
reading a stale feed and report "you're up to date".

One-time setup — the step no-ops with a warning until the secret exists:

```sh
ssh-keygen -t ed25519 -N '' -C distavo-appcast-ci -f /tmp/appcast_deploy
# append to marc@joanmarcriera.es ~/.ssh/authorized_keys, restricted:
#   restrict ssh-ed25519 AAAA... distavo-appcast-ci
gh secret set APPCAST_DEPLOY_SSH_KEY --repo joanmarcriera/distavo < /tmp/appcast_deploy
shred -u /tmp/appcast_deploy 2>/dev/null || rm -P /tmp/appcast_deploy
```

Manual fallback: `./ops/publish-appcast.sh vX.Y.Z`.
