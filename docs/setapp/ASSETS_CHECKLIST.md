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

Source of truth for both stores: `apple/metadata/screenshots/` (App Store — uploaded by
`scripts/setup-appstore-listing.py`) and `apple/metadata/screenshots/setapp/` (Setapp, 4 shots,
all 2560×1600).

| Screenshot | File | Size | Status |
|---|---|---|---|
| Main menu | `apple/metadata/screenshots/01-main-menu.png` | 2560×1600 | **Accepted size, but see the edition warning below** |
| Settings — Getting started + General | `apple/metadata/screenshots/02-settings.png` | 2560×1600 | **Ready** (refreshed 2026-09-06) |
| Settings — Transcription + Summarisation | `apple/metadata/screenshots/03-settings-continued.png` | 2560×1600 | **Ready** (refreshed 2026-09-06) |

**Refreshed 2026-09-06** from the `docs/screenshots/2026-09-06-walkthrough/` set (captured from the
live app by the `marketing-screenshot-walkthrough` skill), composed to 2560×1600 with
`sips -z <2h> <2w>` then `sips -p 1600 2560 --padColor F5F5F7`. The new 02/03 are strictly better
than what they replaced:

- the old `03-settings-continued.png` exposed a **private LAN address** (`192.168.0.5:30068`) in a
  public store listing; the new one shows `127.0.0.1` only;
- the Language row now reads `English` rather than the raw `en` code;
- 02 now leads with the **"Getting started"** panel, which states the whole value proposition
  ("Nothing is ever sent to a cloud service") in the screenshot itself.

> ### ⚠️ Edition warning — read before uploading a menu screenshot
>
> **Screenshots must be captured from the edition they are uploaded for.** Two menu items are
> compiled out of the App Store and Setapp builds:
>
> | Item | Gate | In App Store / Setapp build? |
> |---|---|---|
> | `Support Distavo…` (donate) | `#if DONATE_ENABLED` | **No** — Direct only |
> | `Check for Updates…` (Sparkle) | `#if EDITION_DIRECT` | **No** — Direct only |
> | Settings → **Updates** section | `#if EDITION_DIRECT` | **No** — Direct only |
>
> The current `01-main-menu.png` shows **"Support Distavo…"**, and every shot in the 2026-09-06
> walkthrough was captured from the live **Direct** app (so `01-menu-main.png` shows both
> Direct-only items and `06-settings-connections-updates.png` shows the Updates section). None of
> those may be used for an App Store or Setapp listing: an external-payment affordance in a store
> screenshot is Guideline 3.1.1 territory, and showing UI the shipped build does not have is
> inaccurate under 2.3.3. It has passed review twice, so this is a debt to clear rather than a
> live emergency — but do not make it worse.
>
> `02-settings.png` and `03-settings-continued.png` are **edition-neutral** (no Updates section, no
> donate item), which is why only those two were refreshed. The menu shot needs a re-capture from
> an actual App Store / Setapp build — tracked separately.
>
> **When re-capturing:** every Distavo build shares one config/data path with no `$HOME` override,
> so check `ps aux` for a running instance before launching a second build, or the two will fight
> over the same state. See the safety notes in `docs/screenshots/2026-09-06-walkthrough/walkthrough-report.md`.

### Recommended screenshot set for Setapp

1. **Menu bar icon + dropdown menu** — the app in its natural state. **Capture from the Setapp
   build**, so neither the donate item nor "Check for Updates…" appears.
2. **Settings — Getting started + General** — folders and watch interval; states the local-only
   promise in-frame. (`02-settings.png` is exactly this.)
3. **Settings — Transcription + Summarisation** — engine picker (Built-in vs WhisperX) and the
   Ollama fields. Demonstrates user control and the "no cloud" aspect. (`03-settings-continued.png`.)
4. **A completed note preview** — a Markdown note in Finder or a text editor. Demonstrates the
   output. Use a **synthetic** meeting; real transcripts contain private content.

### Screenshot capture approach

Distavo is an `LSUIElement` menu-bar app, so there is no window to grab by default. The
`marketing-screenshot-walkthrough` skill drives it via `osascript`/System Events accessibility
automation and captures tight, accessibility-bounded crops with `screencapture`.

**Never use full-screen `screencapture`** on a working desktop — the 2026-09-06 run caught
background terminal sessions handling secrets in two accidental full-screen captures. Always crop
to the target element's reported bounds and read the image back before keeping it.

Compose a raw capture to a store-accepted size with:

```bash
sips -z $((h*2)) $((w*2)) shot.png            # 2x for Retina crispness
sips -p 1600 2560 --padColor F5F5F7 shot.png --out out.png
```

---

## Listing copy

See `docs/setapp/LISTING_DRAFT.md` — full description, tagline, keywords, and
feature bullets are ready to paste into the vendor dashboard.

---

## What's still needed from Marc for assets

- [x] Screenshot dimensions confirmed: all 3 are 2560×1600 (Setapp-accepted)
- [x] 02/03 refreshed from the 2026-09-06 walkthrough (LAN IP removed, clearer labels)
- [ ] **Re-capture the menu screenshot from a Setapp/App Store build** — the current one shows the
      Direct-only "Support Distavo…" donate item (see the edition warning above)
- [ ] Optionally add a 4th screenshot showing a completed Markdown note output (synthetic content only)
- [ ] Paste listing copy from `LISTING_DRAFT.md` into the vendor dashboard
