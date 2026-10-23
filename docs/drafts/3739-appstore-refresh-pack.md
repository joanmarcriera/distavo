# DRAFT — #3739 App Store refresh pack (pictures + text + vendor number)

**Status:** prepared by the 2026-10-23 drive. Nothing uploaded to App Store Connect, nothing written to
`apple/metadata/listing.json` (`scripts/setup-appstore-listing.py` pushes that file). 1.20.0 build 23 is in review.

## Text (ca/es/en)
Base copy: `docs/drafts/2140-store-listing-ca-es-en.md` (name, subtitle, keywords, description per language).
1.20 promo text + "Notes window" description block: `docs/drafts/2140-listing-1.20-addendum.md` (en 160 / ca 166 / es 158 chars, limit 170).
Decision for Marc: approve both drafts, apply the Catalan voice pass (wording is not native-reviewed).

## Screenshots: what exists (bytes and pixels, measured 2026-10-23)
| File | Pixels | Bytes | Usable for the Mac App Store? |
|---|---|---|---|
| apple/metadata/screenshots/01-main-menu.png | 1280x800 | 63,407 | size valid, but taken 2026-09-16 (pre-1.17 UI) and from a Direct build |
| apple/metadata/screenshots/02-settings.png | 1280x800 | 97,776 | size valid, stale UI (pre sidebar-panes) |
| apple/metadata/screenshots/03-settings-continued.png | 1280x800 | 86,352 | size valid, stale UI |
| docs/screenshots/1.18-notes-window/01-notes-window.jpg | 1400x1050 | 219,768 | NO: not an accepted size |
| docs/screenshots/1.18-notes-window/02-new-note-and-disabled-reasons.jpg | 1400x1050 | 206,831 | NO: not an accepted size |
| docs/screenshots/1.18-notes-window/03-regenerate-sheet.jpg | 1400x1050 | 210,329 | NO: not an accepted size |

Accepted Mac sizes (Apple): 1280x800, 1440x900, 2560x1600, 2880x1800; 1 to 10 images per localisation.
**Conclusion:** the set must be re-shot. It could not be produced unattended (no GUI session; memory:
editions are not interchangeable, so shots must come from the `Distavo-AppStore` scheme, never reused from Direct).

## Shot list (App Store build, 2560x1600 or 1440x900, with demo notes in en/ca/es)
1. Notes window, 5+ notes, one selected, search field filled
2. Summarise Together sheet, then the resulting cited note
3. Ask window with a cited answer and the local-only badge
4. End-of-recording sheet with prefilled speakers (needs #3943, in 1.20)
5. Settings, Transcription pane showing Automatic + Catalan model
Localised captions: reuse the promo text lines from the addendum.

## Vendor number (gate)
🤖⏸ AWAITING MARC — App Store Connect → Business (or Payments and Financial Reports) → the vendor number is shown
under the account name (also Sales and Trends → Reports → "Vendor" dropdown). Then store it:
`echo 'export ASC_VENDOR_NUMBER=<number>' >> ~/.tokens`. [VERIFY the exact menu name in the current ASC UI.]
`ASC_VENDOR_NUMBER` is not in `~/.tokens` today (checked by count, value not read). Weekly sales then come from
`GET /v1/salesReports?filter[vendorNumber]=…` with the existing ASC key.
