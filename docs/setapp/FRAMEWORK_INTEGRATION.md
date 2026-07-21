# Setapp Framework Integration — Code Change Plan

## When to execute this

Only after **BLOCKER 2** is cleared: you have the Setapp Framework SDK archive
from the vendor dashboard AND the app public key file for `uk.co.riera.distavo-setapp`.

The Setapp Framework integration requires a one-time code change, a project.yml
update, and a new CI step. All three are described here.

---

## What the Setapp Framework does for Distavo

Distavo has **no activation/licensing system** — the app is fully functional
without any license check. This is actually ideal for Setapp: Setapp replaces
the licensing layer, so the Framework just needs to:
1. Verify the user has an active Setapp subscription at launch.
2. Prevent use if the subscription lapses (Setapp's standard pop-up handles this).
3. Optionally report usage events (used for the membership revenue pool weighting).

Because Distavo is a menu-bar app (LSUIElement, no main window), the Framework
pop-up behaviour is the only integration required at minimum.

---

## Step 1: Add the SDK files to the repo

From the SDK archive you download from the vendor dashboard:

```
libSetapp.a        — the static library (universal binary, arm64 + x86_64)
Setapp.h           — the C header (if using the Framework, you get a .xcframework instead)
SetappPublicKey.pem — the public key file (generated per-app in the dashboard)
```

Place them in the repo under `apple/vendor/setapp/`:

```
apple/vendor/setapp/libSetapp.a          (or Setapp.xcframework/)
apple/vendor/setapp/Setapp.h             (omit if using xcframework)
apple/vendor/setapp/SetappPublicKey.pem
```

Add `apple/vendor/setapp/` to `.gitignore` if you don't want to commit the
proprietary SDK binary, and instead document how to restore it from the vendor
dashboard. Or commit it — MacPaw permits redistribution to build machines.

---

## Step 2: Update Setapp.xcconfig

Open `apple/configs/Setapp.xcconfig` and add the linker flags. The file already
has an `ENABLE_HARDENED_RUNTIME = YES` line. Add after it:

```xcconfig
// Setapp Framework — static lib (uncomment after SDK is in vendor/setapp/)
OTHER_LDFLAGS = $(inherited) -force_load "$(PROJECT_DIR)/vendor/setapp/libSetapp.a" -framework Security -framework IOKit -framework QuartzCore -framework Cocoa
```

If MacPaw ships a modern `.xcframework` package instead of `libSetapp.a` by the
time you integrate, link it via SPM or as an Xcode framework reference instead.

---

## Step 3: Wire the Framework call in DistavoApp.swift

The `EDITION_SETAPP` compilation condition is already set in `Setapp.xcconfig`.
Add the Setapp activation to `DistavoApp.swift`:

```swift
import SwiftUI
#if EDITION_SETAPP
import Setapp
#endif

@main
struct DistavoApp: App {
    @StateObject private var controller = WatcherController()

    init() {
        #if EDITION_SETAPP
        // Setapp Framework activation — must be called before any UI is shown.
        // The public key is read automatically from SetappPublicKey.pem in the bundle.
        SetappManager.shared.start(with: SetappConfiguration())
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(controller: controller)
        } label: {
            MenuBarLabel(state: controller.iconState)
        }
        .menuBarExtraStyle(.menu)
    }
}
```

**Note:** The exact API (`SetappManager.shared.start(with:)` vs.
`SFSetappManager.sharedManager().start(with:)`) may differ depending on whether
MacPaw is shipping the newer Swift-native Framework or the legacy Obj-C one.
Check `https://docs.setapp.com/docs/install-and-set-up-framework` at integration
time — the structure above is the standard modern pattern.

---

## Step 4: Add usage reporting (menu-bar apps — important for revenue)

Because Distavo is a menu-bar app and Setapp's revenue pool is weighted by
**usage events**, you must report that the user actually opened/used the app.
Without usage reporting, Distavo's revenue share will be near zero regardless of
how many Setapp subscribers have it installed.

Add a usage report in `WatcherController` or wherever the menu bar icon receives
its first click, gated behind `EDITION_SETAPP`:

```swift
// In StatusMenu.swift or WatcherController.swift, on first user interaction:
#if EDITION_SETAPP
SetappManager.shared.reportUsageEvent(SCUserEngagementEvent.userInteraction)
// or the string-based API if using the older SDK:
// SCReportUsageEvent("user-interaction", nil)
#endif
```

Also report on pipeline completion (a recording was processed):

```swift
#if EDITION_SETAPP
SetappManager.shared.reportUsageEvent(SCUserEngagementEvent.userInteraction)
#endif
```

---

## Step 5: Add SetappPublicKey.pem to the Xcode target

The public key must be bundled inside `Distavo.app`. In `apple/project.yml`,
add a resource reference to the Setapp target:

```yaml
targets:
  Distavo-Setapp:
    templates: [DistavoApp]
    # ... existing config ...
    resources:
      - path: vendor/setapp/SetappPublicKey.pem
```

Run `cd apple && xcodegen generate` to regenerate the Xcode project after the
yaml change.

---

## Step 6: Verify the integration locally

```bash
# Build unsigned for basic validation first
cd apple
xcodebuild -project Distavo.xcodeproj \
  -scheme Distavo-Setapp \
  -configuration Release \
  -derivedDataPath build/SetappValidation \
  CODE_SIGNING_ALLOWED=NO build

# Check the framework linked correctly:
nm build/SetappValidation/Build/Products/Release/Distavo.app/Contents/MacOS/Distavo \
  | grep -i setapp
# Expect: SetappManager or SCSetapp symbols present

# Check the public key is bundled:
ls build/SetappValidation/Build/Products/Release/Distavo.app/Contents/Resources/ \
  | grep -i setapp
# Expect: SetappPublicKey.pem
```

Then follow `docs/setapp-submission.md §3` for the full notarize + staple + package flow.

---

## Step 7: Update the CI release workflow (future automation)

Once the first version is accepted, subsequent builds can be uploaded via the
Setapp REST API. Add a `release-setapp.yml` workflow following the same pattern
as `release.yml`, triggered on `v*` tags, with the SDK fetched from a repo
secret or the vendor/setapp directory if committed.

The Setapp CLI (`setapp-cli` or the Fastlane plugin `fastlane-plugin-setapp`)
can upload builds automatically. Document the token as a GitHub Actions secret:
`SETAPP_VENDOR_TOKEN`.

---

## Estimated integration effort

| Task | Time |
|---|---|
| Add SDK files to repo | 5 min |
| Update Setapp.xcconfig | 2 min |
| Edit DistavoApp.swift | 10 min |
| Add usage reporting (1–2 call sites) | 15 min |
| Update project.yml + xcodegen | 5 min |
| Local build + verification | 20 min |
| Full notarize + package + dashboard upload | 30 min |
| **Total** | **~1.5 hours** |
