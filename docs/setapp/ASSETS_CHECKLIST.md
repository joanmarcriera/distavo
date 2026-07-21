# Distavo — Setapp Assets Checklist

## App icon

Setapp requires a **1024 × 1024 px PNG** submitted alongside the app zip.

| Asset | Status | File |
|---|---|---|
| 1024×1024 AppIcon.png | **Ready** | `apple/Resources/Assets.xcassets/AppIcon.appiconset/icon_512@2x.png` (512@2x = 1024px) |

The `build-and-notarize.sh setapp` script already places `AppIcon.png` next to
`Distavo.app` in the final upload zip. No action needed.

Verify the size:
```bash
sips -g pixelWidth -g pixelHeight apple/Resources/Assets.xcassets/AppIcon.appiconset/icon_512@2x.png
# Expect: pixelWidth: 1024, pixelHeight: 1024
```

---

## Screenshots

Setapp accepts macOS screenshots in these sizes (px, @1x):

| Size | Notes |
|---|---|
| 1280 × 800 | 13" display simulation |
| 1440 × 900 | Standard widescreen |
| 2560 × 1600 | Retina 13" |
| 2880 × 1800 | Retina 15"/16" |

You need **at least 1 screenshot** uploaded; **3–5 is recommended**.

### Current screenshot status

| Screenshot | File | Setapp-ready? |
|---|---|---|
| Main menu | `apple/metadata/screenshots/01-main-menu.png` | **Ready** — 2560×1600 (Setapp-accepted) |
| Settings | `apple/metadata/screenshots/02-settings.png` | **Ready** — 2560×1600 (Setapp-accepted) |
| Settings continued | `apple/metadata/screenshots/03-settings-continued.png` | **Ready** — 2560×1600 (Setapp-accepted) |

All three screenshots are 2560×1600, which is one of Setapp's accepted sizes.
They can be uploaded to the vendor dashboard as-is.

### Recommended screenshot set for Setapp

1. **Menu bar icon + dropdown menu** — the app in its natural state, showing the
   "Record meeting / Activity / Settings" menu. Capture with the menu open.
2. **Settings — transcription section** — showing the engine picker (Built-in vs
   WhisperX) and model selector. Demonstrates user control.
3. **Settings — summarisation section** — Ollama URL fields. Shows "no cloud" aspect.
4. **A completed note preview** (if feasible) — show a Markdown note file in
   Finder or a text editor alongside the Activity log. Demonstrates the output.

### Screenshot capture approach

The `marketing-screenshot-walkthrough` skill supports automated screenshot
capture for marketing purposes. Given Distavo is a menu-bar app (LSUIElement),
screenshots need to be taken while the app is running with the menu open:

```bash
# Run the Direct build locally, then use screencapture:
screencapture -x -R "0,0,1440,900" screenshot-menubar.png
# Or with the menu open (use a timer and open the menu manually):
screencapture -T 5 -x -R "0,0,1440,900" screenshot-menu-open.png
```

For Setapp specifically, a clean macOS desktop background (the default blue/purple
gradient) and no other app clutter in the menu bar work best.

---

## Listing copy

See `docs/setapp/LISTING_DRAFT.md` — full description, tagline, keywords, and
feature bullets are ready to paste into the vendor dashboard.

---

## What's still needed from Marc for assets

- [x] Screenshot dimensions confirmed: all 3 are 2560×1600 (Setapp-accepted)
- [ ] Optionally add a 4th screenshot showing a completed Markdown note output
- [ ] Paste listing copy from `LISTING_DRAFT.md` into the vendor dashboard
