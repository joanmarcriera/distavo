# Search Notes (Vikunja #2942)

Menu bar -> **Search Notes…** opens a window that searches every note and every cached transcript.

## How it works

- `DistavoCore/SearchIndex.swift` keeps one SQLite database (the system SQLite, FTS5 table, `unicode61 remove_diacritics 2` so Catalan/Spanish accents match, `bm25` ranking, `snippet()` excerpts) at
  `~/Library/Application Support/Distavo/search-index.sqlite` (inside the container in the App Store build; no extra entitlement).
- One row per note (`<notes>/<base>.md`, `.prev-` backups skipped) and one per transcript (`<work>/<base>.transcript.clean.txt`). Transcript rows store the `[SPEAKER_xx]` labels found in them; a note inherits the speakers of the transcript with the same base, which is what the speaker filter uses.
- The index is a **cache**: the files on disk are the truth. A corrupt, unknown or newer-schema database (`PRAGMA user_version`) is deleted and rebuilt; every call fails soft (empty result) so search can never break a recording.
- Kept current by: indexing right after a note is written or regenerated (`WatcherController+Search.swift`), a background `reconcile` at app start, and a `reconcile` whenever the window opens (picks up notes written before this feature, hand-edited by mtime+size, or deleted).
- Queries are tokenised to letters/digits and every term is quoted (`"a" "b"*`, last term a prefix), always as a bound parameter: FTS operators or SQL typed by the user are plain words.

## Reuse for "ask across notes" (#2948)

`SearchIndex.passages(matching:limit:words:)` returns ~300-word passages around the matches of the best-ranked documents; `search(...)` returns snippets with score, date and speakers.

## Privacy

The index contains transcript text. It stays on this Mac and is covered by the same local-first rule as the notes. The window's ellipsis menu has **Rebuild search index** and **Delete search index** (removes the file; it is recreated the next time the window opens or a note is written).
