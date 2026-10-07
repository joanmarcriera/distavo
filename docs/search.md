# Search Notes (Vikunja #2942)

Menu bar -> **Notes…**, scope **Inside notes and transcripts**, searches every note and every cached transcript. (Until 1.17 this was its own "Search Notes…" window; since 1.18 it is the search field of the Notes window, see `docs/notes-window.md`. With the scope on **Titles** the field only filters the list and uses no index.)

## How it works

- `DistavoCore/SearchIndex.swift` keeps one SQLite database (the system SQLite, FTS5 table, `unicode61 remove_diacritics 2` so Catalan/Spanish accents match, `bm25` ranking, `snippet()` excerpts) at
  `~/Library/Application Support/Distavo/search-index.sqlite` (inside the container in the App Store build; no extra entitlement).
- One row per note (`<notes>/<base>.md`, `.prev-` backups skipped) and one per transcript (`<work>/<base>.transcript.clean.txt`). Transcript rows store the `[SPEAKER_xx]` labels found in them; a note inherits the speakers of the transcript with the same base, which is what the speaker filter uses.
- The index is a **cache**: the files on disk are the truth. A corrupt, unknown or newer-schema database (`PRAGMA user_version`) is deleted and rebuilt; every call fails soft (empty result) so search can never break a recording.
- Kept current by: indexing right after a note is written or regenerated (`WatcherController+Search.swift`), a background `reconcile` at app start, and a `reconcile` whenever the Notes window opens with the index enabled (picks up notes written before this feature, hand-edited by mtime+size, or deleted).
- Queries are tokenised to letters/digits and every term is quoted (`"a" "b"*`, last term a prefix), always as a bound parameter: FTS operators or SQL typed by the user are plain words.

## Reuse for "ask across notes" (#2948)

`SearchIndex.passages(matching:limit:words:)` returns ~300-word passages around the matches of the best-ranked documents; `search(...)` returns snippets with score, date and speakers.

## Opt-in and privacy

The index contains transcript text, so it is **opt-in by use**: nothing is created, read or written until you press **Build the Search Index** in the Notes window (scope "Inside notes and transcripts"). Opening the Notes window does not opt you in. The button sets an "index enabled" flag (`search.indexEnabled` in UserDefaults, default off; not a Config key), shows "Indexing…" and builds the index. Until then the launch reconcile and the after-note-written indexing do nothing, so existing installs behave exactly as before.

The index stays on this Mac. The ellipsis menu beside the search field has **Rebuild search index** and **Delete search index**. Delete clears the flag, cancels any pending search/refresh and removes the file; it stays deleted — nothing is indexed again — until you press Build the Search Index again.

## Robustness

- A folder that cannot be listed (unplugged drive, unresolved sandbox bookmark) is not treated as empty: its rows are kept; only rows under folders that listed successfully are removed.
- The database is opened with a 2 s busy timeout (Direct and Setapp share the path). It is deleted and rebuilt only when SQLite reports corruption / not-a-database, or the schema version was read and differs; a locked or otherwise unavailable file is left untouched and search is simply unavailable for that call.
