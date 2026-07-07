# Distavo — Setapp Submission Playbook

Standalone, step-by-step guide for shipping the Distavo Setapp edition. All
technical requirements confirmed against Setapp docs (2026); see Sources at the
end.

Prerequisites: Apple Developer credentials and the `distavo-notary` keychain
profile must already be set up (see `docs/distribution-checklist.md` §1). Run the
commands below from the repo's `apple/` directory.

---

## 1. Vendor onboarding

**Needs Marc** — a bot cannot do this.

1. Sign up or request vendor access at `https://setapp.com/developers`
   (or email `developers@setapp.com`). MacPaw reviews vendor applications
   manually; allow a few business days.
2. Once approved, log in to the vendor dashboard at `https://developer.setapp.com`.

### Choose a revenue model

Setapp offers two models; pick before you configure your app listing.

| Model | Who it suits | How revenue works |
|---|---|---|
| **Setapp Membership** | Apps with broad appeal / daily use | Setapp shares ~**70 %** of subscription revenue across all developers in the bundle. Your share is weighted by how many members used Distavo during the billing period, multiplied by your chosen price-tier (tiers 1–100). You also earn a +20 % bonus on users you referred to Setapp. Paid for *usage*, not downloads. |
| **Single-App Distribution** | Apps you want to sell individually | Sell Distavo as a one-time purchase or subscription via the Setapp Marketplace. Available in **EEA + US** only. You keep **85 %** of the app price. |

Setapp Membership gets you into the bundle catalogue and is the default path.
Single-App Distribution requires opting in separately during onboarding; choose
it if you want a predictable per-purchase revenue model.

Sources: [Membership revenue](https://docs.setapp.com/docs/setapp-membership-revenue)
· [Single-app distribution revenue](https://docs.setapp.com/docs/single-app-distribution-revenue)
· [Single-app distribution overview](https://docs.setapp.com/docs/single-app-distribution-overview)

---

## 2. Technical build requirements

Most of this is already wired in `apple/configs/Setapp.xcconfig`,
`apple/Setapp-Info.plist`, and `Distavo.entitlements`, but the Setapp Framework
integration requires a one-time manual step in the vendor dashboard.

### 2.1 Bundle ID

```
uk.co.riera.distavo-setapp
```

Already set via `PRODUCT_BUNDLE_IDENTIFIER` in `Setapp.xcconfig`. The `-setapp`
suffix is mandatory. **This ID is permanent — it cannot be changed once set.**
Any helper executables (login items, XPC services) must follow the pattern
`uk.co.riera.distavo-setapp.<HelperName>`.

Source: [Set an app bundle ID](https://docs.setapp.com/docs/set-an-app-bundle-id)

### 2.2 Signing and notarization

- Signed with **Developer ID Application** (same as the Direct edition).
- **Apple notarization is required** by Setapp before submission.
- No sandbox: `CODE_SIGN_ENTITLEMENTS = Distavo.entitlements` (the same
  non-sandboxed entitlements used by the Direct edition).
- `ENABLE_HARDENED_RUNTIME = YES` is already set in `Setapp.xcconfig`.

### 2.3 Setapp Framework integration

**Needs Marc** — requires the vendor dashboard.

1. In the vendor dashboard generate a **public key** for your app. Download it.
2. Add the public key file to the Distavo app bundle (drag it into the Xcode
   project under the Setapp scheme target, or reference it in `project.yml`).
3. Add `libSetapp.a` to the Xcode project (download the SDK from the dashboard).
   Wire it in `Setapp.xcconfig` — the flag is already present as a comment; add
   the actual path:

   ```
   OTHER_LDFLAGS = $(inherited) -force_load "$(BUILT_PRODUCTS_DIR)/libSetapp.a"
   ```

4. Gate all Setapp Framework calls behind the `EDITION_SETAPP` compilation
   condition, which is already set in `Setapp.xcconfig`:

   ```swift
   #if EDITION_SETAPP
   import Setapp
   // Activate Setapp at app launch:
   SetappManager.shared.start(with: SetappConfiguration())
   #endif
   ```

   This ensures the Direct and App Store builds never link or call Setapp.

5. Follow the exact current API for initialisation in
   `https://docs.setapp.com/docs/install-and-set-up-framework`.

Source: [Install and set up Framework](https://docs.setapp.com/docs/install-and-set-up-framework)

### 2.4 Info.plist requirements

The Setapp build uses `apple/Setapp-Info.plist` via `Setapp.xcconfig` so the
Setapp-only metadata does not leak into the Direct or App Store editions. The
following keys must be present in the Setapp build:

| Key | Value |
|---|---|
| `CFBundleIdentifier` | `uk.co.riera.distavo-setapp` |
| `CFBundleName` | `Distavo` |
| `CFBundleIconFile` | your app icon name |
| `CFBundleVersion` | build number (integer) |
| `CFBundleShortVersionString` | marketing version (currently `1.6.0`) |
| `NSUpdateSecurityPolicy` | allows `com.setapp.DesktopClient.SetappAgent` under team `MEHY5QF425` |

`NSUpdateSecurityPolicy` is already present in `apple/Setapp-Info.plist`.
Setapp will reject the build without it.

Source: [Submitting apps for review](https://docs.setapp.com/docs/submitting-apps-for-review)

### 2.5 Bundle size

The submitted zip must not exceed **1 GB**.

---

## 3. Build → notarize → package

### 3.1 Archive the Setapp edition

```bash
xcodebuild -project Distavo.xcodeproj \
  -scheme Distavo \
  -configuration Release \
  -xcconfig configs/Setapp.xcconfig \
  -archivePath build/Distavo-Setapp.xcarchive \
  archive \
  DEVELOPMENT_TEAM=<TEAM_ID> \
  CODE_SIGN_IDENTITY="Developer ID Application"
```

> `-xcconfig configs/Setapp.xcconfig` is what makes the bundle ID
> `uk.co.riera.distavo-setapp` and sets `EDITION_SETAPP`. Or run the wrapper:
> `TEAM_ID=… NOTARY_PROFILE=distavo-notary ./scripts/build-and-notarize.sh setapp`,
> which does the archive → export → notarize → staple in one go.

### 3.2 Export

Create `apple/ExportOptions-Setapp.plist` (same as the Direct plist — both use
the `developer-id` method):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>            <string>developer-id</string>
  <key>teamID</key>            <string>TEAM_ID_HERE</string>
  <key>signingStyle</key>      <string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
```

```bash
xcodebuild -exportArchive \
  -archivePath build/Distavo-Setapp.xcarchive \
  -exportPath build/export-setapp \
  -exportOptionsPlist ExportOptions-Setapp.plist
# → build/export-setapp/Distavo.app
```

### 3.3 Notarize

```bash
ditto -c -k --keepParent build/export-setapp/Distavo.app build/Distavo-Setapp-notarize.zip

xcrun notarytool submit build/Distavo-Setapp-notarize.zip \
  --keychain-profile "distavo-notary" \
  --wait
```

If status is `Invalid`, pull the log (replace `<id>` with the UUID printed):

```bash
xcrun notarytool log <id> --keychain-profile "distavo-notary" developer_log.json
```

### 3.4 Staple

```bash
xcrun stapler staple build/export-setapp/Distavo.app
xcrun stapler validate build/export-setapp/Distavo.app   # → "The validate action worked!"
```

### 3.5 Package for Setapp

Setapp expects a clean **zip** with the `.app` bundle and a 1024 × 1024
`AppIcon.png` next to it — no `__MACOSX` metadata folder. Use `ditto`, not
Finder compression or `zip`. The wrapper script creates this structure for the
Setapp edition:

```bash
TEAM_ID=… NOTARY_PROFILE=distavo-notary ./scripts/build-and-notarize.sh setapp
```

Validate the structure before uploading:

```bash
rm -rf /tmp/distavo-check
ditto -x -k build/release-setapp/Distavo-setapp.zip /tmp/distavo-check
find /tmp/distavo-check -maxdepth 2 -print | sort
# Expect: Distavo.app and AppIcon.png, and no __MACOSX folder.
```

Verify signature and Gatekeeper acceptance as a final sanity check:

```bash
codesign --verify --strict --verbose=2 build/export-setapp/Distavo.app
spctl -a -vvv --type exec build/export-setapp/Distavo.app
# Expect: "accepted   source=Notarized Developer ID"
```

---

## 4. Submit

### 4.1 First version — Web UI (required)

**Needs Marc** — Setapp requires the first build to be uploaded manually.

1. Log in to the vendor dashboard at `https://developer.setapp.com`.
2. Open your app listing → **Edit Version**.
3. In the **Build** area, drag `build/Distavo-Setapp.zip` onto the upload target.
4. Add **release notes** (plain text; describe what Distavo does for first-time
   Setapp reviewers).
5. Set the version status to **review** and submit.

Setapp reviews every build before it goes live; expect a few business days.

### 4.2 Later versions — automatable

Once you have a vendor account and the first version is live, subsequent uploads
can be automated using any of:

- **Setapp REST API** — documented at `https://docs.setapp.com/`.
- **MacPaw shell-script template** — provided in the vendor dashboard.
- **Fastlane plug-in** — `fastlane-plugin-setapp` (community-maintained).

Source: [Submitting apps for review](https://docs.setapp.com/docs/submitting-apps-for-review)

---

## 5. What needs Marc vs. what can be automated

| Task | Needs Marc | Automatable |
|---|---|---|
| Create Setapp vendor account | Yes | — |
| Choose Membership vs. Single-App model | Yes | — |
| Generate Setapp public key in dashboard | Yes | — |
| Integrate Setapp Framework (`libSetapp.a`) + public key into Xcode project | Yes | — |
| First build upload (Web UI) | Yes | — |
| Archive, notarize, staple, package | No | Yes — shell script / Makefile / CI |
| Setapp `Info.plist` metadata and package icon structure | — | Yes — already wired |
| Subsequent build uploads | No | Yes — REST API / MacPaw script / Fastlane |
| Release notes per version | Yes (content) | Template automatable |

---

## Sources

- [Setapp for developers](https://setapp.com/developers)
- [Setapp — Single-app distribution overview](https://docs.setapp.com/docs/single-app-distribution-overview)
- [Setapp — Set an app bundle ID (-setapp suffix)](https://docs.setapp.com/docs/set-an-app-bundle-id)
- [Setapp — Install and set up Framework](https://docs.setapp.com/docs/install-and-set-up-framework)
- [Setapp — Submitting apps for review (zip structure, Info.plist, NSUpdateSecurityPolicy, 1 GB limit)](https://docs.setapp.com/docs/submitting-apps-for-review)
- [Setapp — Single-app distribution revenue (85 %)](https://docs.setapp.com/docs/single-app-distribution-revenue)
- [Setapp — Membership revenue (usage-pool, ~70 %)](https://docs.setapp.com/docs/setapp-membership-revenue)
