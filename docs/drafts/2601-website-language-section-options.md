# DRAFT — #2601 Website language section: lead with underserved languages

**Status:** draft for Marc's pick, nothing built. Site untouched (`ops/site/index.html`).
**Facts marked `[VERIFY]` are not established in the repo/memory; do not publish them unchecked.**

## Where the site is today
- Hero lede already says "languages most transcription tools skip".
- `#lang-band` ("The languages other transcription tools skip."): a 4-card list in the order
  Català, **Español**, Euskara, Galego, then a "Fast engine, 25 European languages" chip line, then a note.
- `#language-packs` ("Five more languages, one click away."): Hebrew, Thai, Tamil, Welsh, Norwegian cards.
- Español sits second in the lead row although it is commodity coverage (Parakeet, Whisper, Apple all do it).
- Inline JS re-orders the four cards / Fast chips by `navigator.languages` (no network, no storage).
  **Any option must keep that behaviour** and keep the page working without JS.
- Constraint (`DECISIONS.md` 2026-06-29): static files, no framework; the no-telemetry stance means
  no third-party map tiles/scripts — an inline SVG only.

## Facts we can lean on (all traceable)
- Apple `SpeechTranscriber` has no Catalan and Apple Intelligence has no Catalan (checked 2026-09-10, macOS 26.6);
  Parakeet has no Catalan either (`distavo-catalan-differentiator`).
- BSC models cover ca/es/gl/eu; Catalan needs a Mac with 16 GB. Stock large-v3-turbo on a real
  Catalan/Spanish/English meeting came out 98% English (bake-off run a); BSC came out ~76% Catalan.
- Packs beat stock turbo on real speech: Hebrew, Thai, Welsh ("pack wins, high confidence"); Tamil and
  Norwegian shipped in 1.14 (Tamil no punctuation; Norwegian lower-case only).
- Withdrawn after bake-off (honest "not yet" candidates): Icelandic, Tagalog, Gujarati, Malayalam.
- Speaker counts in the task (ca ~10M, eu ~750k, gl ~2.4M, cy ~880k, he ~9M, th ~60M, ta ~80M, no ~5M)
  are **unsourced** `[VERIFY]` — cite Ethnologue/Wikipedia before use, or drop the numbers.
- Blue/yellow/grey needs a stated bar (Whisper large-v3 + which meeting apps?) `[VERIFY]`; until
  chosen, only the Apple/Parakeet/stock-turbo facts above are defensible.

## Option A — Tiered flag strip (re-order, no new assets)
```
 The languages other transcription tools skip.
 [ Català ] [ Euskara ] [ Galego ] [ עברית ] [ ไทย ] [ தமிழ் ] [ Cymraeg ] [ Norsk ]
   ~10M?      ~750k?      ~2.4M?     ...           (chip + one line each)
 ---- and everything the mainstream tools do well (secondary, small) ----
 Español · English · Français · Deutsch · … 25 Fast languages · Whisper's 99
```
- Copy: H2 "Meetings in the languages the big tools can't follow." Sub: "Catalan, Basque, Galician,
  Hebrew, Thai, Tamil, Welsh, Norwegian — transcribed on your Mac. Spanish, English and the rest are covered too."
- Merges `#lang-band` + `#language-packs` into one section; cards keep the pack credits (ivrit.ai, Mahidol, IIT Madras, Bangor, NLN).
- Pros: ~1 day of HTML/CSS; keeps the JS re-order (targets the lead row); no data risk if counts are dropped.
- Cons: least distinctive; "why these are hard" is not shown; Spanish demoted may confuse the Spanish-speaking core audience.

## Option B — Three-colour coverage map (Marc's idea)
```
 +-------------------------------------------+   legend: [blue]  everyone covers
 |  inline SVG: Europe (+ Israel/Thailand/   |           [yellow] Distavo's edge
 |  India insets); regions filled by tier    |           [grey]  nobody covers well yet
 +-------------------------------------------+
 tap/hover a region -> card: name, speakers?, why hard, engine used
 (below the map: the same list as a real <ul> for no-JS / screen readers)
```
- Copy: H2 "See where Distavo goes that others don't." Sub: "Yellow is where we do better than stock
  Whisper. Grey is where nobody is good yet — we say so."
- Pros: most memorable; the grey tier is an honest, shareable claim; fits the "we tell you the truth" tone.
- Cons: heaviest (SVG + a11y + mobile tap targets, ~3-5 days); needs the tiering decision and a licensed
  map source `[VERIFY]`; regions are not languages (Catalan spans four countries); grey claims invite argument.

## Option C — Sorted table/cards with tier dots
```
 Language    Speakers  Tier    Engine
 ● Català     ~10M?    yellow  BSC Catalan (16 GB)
 ● Euskara    ~750k?   yellow  BSC Languages of Spain
 ● עברית      ~9M?     yellow  ivrit.ai pack (opt-in)
 ● Español    [VERIFY] blue    BSC / Fast / Whisper
 sort: yellow, grey, blue; filter chips [All][Edge][Mainstream]
```
- Copy: H2 "Every language, and how well we do it." Sub: "Sorted by where Distavo helps most."
- Pros: cheapest to keep accurate as packs ship (one row per catalog entry); honest per-language engine and memory floor; works without JS.
- Cons: reads as a spec sheet, not a pitch; needs the same tier/speaker data as B.

## Recommendation
**A now, C as its second layer, B only if the site gets a marketing push.**
1. Ship A: it fixes the actual problem (Español leading, packs buried one section below) with the least risk.
2. Add C's engine/memory column as a collapsed "All languages" table below the strip.
3. Defer B until the tiering bar is agreed; a map with an unargued grey tier is a claim liability.
Drop the speaker-count line unless sourced. Keep the hero, badge and price untouched.

## Open items for Marc
- Choose the "bar" tools for blue/yellow/grey, or skip tiers entirely (A works without them).
- Does Español stay in the lead row for Spanish-language visitors (JS already promotes it for them)?
- Translate H2/sub into ca/es? (`DECISIONS.md`: localized pages are a revisit trigger.)
