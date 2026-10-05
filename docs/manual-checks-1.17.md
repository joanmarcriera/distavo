# Manual checks for 1.17

Things unit tests cannot cover (a running app, real models). Each feature appends its own section.

## Regenerate Note (Vikunja #2947)

Needs a signed or Debug build of the real app; do NOT run it alongside your daily Distavo (they share one config and data folder).

1. Menu bar -> **Regenerate Note…** opens the window listing the 15 newest notes; the newest note with a saved transcript is preselected, notes without one are labelled "(no saved transcript)" and cannot be run.
2. Pick **Facts first** (or Classic), leave backend "As in Settings", add the instruction "Put the action items first", press **Regenerate**.
3. Open the activity log (menu -> Activity -> Open full log…): it must say `Regenerating note for <base> (transcript reused)` and then `Regenerated note: …`. It must NOT contain any converting/transcribing/language-detection/model-loading-for-transcription line.
4. In the notes folder: `<base>.md` is the new note and `<base>.prev-<yyyyMMdd-HHmmss>.md` holds the old one. Regenerate again: a second `.prev-…` file appears, the first is untouched.
5. The menu's **Open last note** opens the new note; **Compare…** does not list the `.prev-` file as a variant.
6. Stop Ollama (or point the server URL at a dead host, local fallback off) and regenerate: a "Note not regenerated" notification appears, the note is unchanged, no new `.prev-` file, and the "recordings failed" line does not appear in the menu.
7. Delete `<base>.transcript.clean.txt` from `~/Library/Application Support/Distavo/work` and open the window: that note is greyed out as "no saved transcript".
8. With on-device summaries enabled: choose **Built-in (this Mac)** and a long instruction; the note is written (or the error says why) and the previous note is kept.
9. Start a scan (drop a recording) and press Regenerate while it runs: the regenerate waits for the scan to finish (single-flight), it never overlaps.

Not exercised by unit tests: the SwiftUI window, notifications, the real Ollama / Foundation Models / Gemma paths with a custom instruction.

Notes made before this version regenerate fine as long as the work folder still holds `<base>.transcript.clean.txt` (every note the pipeline has written since the transcript cache was introduced); notes whose work folder was cleared, or imported without processing, cannot be regenerated.

Language parity: with Settings -> Notes -> "Write notes in" = match the meeting, regenerate a note from an auto-detected Catalan meeting processed on this version: it must stay Catalan (the detected language is kept in `<base>.transcript.meta.json`). A note processed before this version has no such file and falls back to the spoken language set in Settings.

## Export formats (Vikunja #2943)

Unit tests cover the formats, but nothing here has been opened in a real app or driven through the
real panel. Do these once on a signed build, in the Direct and App Store editions.

Prerequisite: process a fresh recording (the sidecar `<base>.segments.json` only exists for
recordings processed with this version). Ideally one with two speakers and diarisation on.

1. Menu bar > **Export transcript as…** is enabled after processing. After relaunch (note seeded
   from disk) it stays enabled for the new recording.
2. For an OLD recording (no sidecar) the item reads "Export transcript as… (no timestamps saved)"
   and is disabled; nothing crashes.
3. The save panel shows a **Format** popup; changing it changes the file extension in the name field.
4. **DOCX:** open in Word and Pages. No "unreadable content" prompt; speaker labels are bold; each
   turn has a grey `[m:ss]` timestamp.
5. **PDF:** open in Preview. Speaker labels in bold, timestamps grey, multiple pages for a long
   meeting, text selectable.
6. **SRT:** play the recording in VLC or QuickTime with the `.srt` loaded (same base name beside the
   audio). Cue timing tracks speech within about 0.5 s; speaker prefix shown.
7. **VTT:** load in a browser `<track>` or VLC; `<v SPEAKER_00>` voices parse, no stray tags shown.
8. **JSON:** opens as valid JSON (`jq . file.json`); equals the work-dir sidecar.
9. **HTML:** opens in Safari/Chrome, readable in light and dark mode, no network requests.
10. **App Store edition:** saving to Desktop/Documents via the panel works (user-selected
    read-write entitlement is already present in `apple/Distavo-AppStore.entitlements`).
11. A `Process a recording with…` variant exports from its own sidecar (`<base>@<suffix>`).

## Custom vocabulary and replacements (Vikunja #2939)

Settings > Transcription > Vocabulary.

1. Record or pick a short clip that says an uncommon name or acronym the model
   gets wrong (e.g. "Slurm" heard as "slum"). Baseline: process it with an empty
   vocabulary and note the misspelling.
2. Built-in engine, Whisper model (not Fast/Parakeet): add the term under
   "Names and jargon", re-process. Expect the transcript to spell it correctly.
   Expect no change in the other words. If the transcript came out empty or
   starts with the term list, the activity log must show "Vocabulary prompt
   degraded the transcript - retrying without it" and the recording must still
   produce a transcript.
3. WhisperX server: same check; the request carries `initial_prompt` (server
   access log), and is absent when the list is empty.
4. Fast (Parakeet) engine: the list has no effect on the transcript (no prompt
   support); a replacement rule does.
5. Add a replacement "slum" -> "Slurm": transcript (`*.transcript.clean.txt`) and
   the note both say "Slurm"; "category" style substrings are untouched.
6. Apple on-device summariser with a 40-term glossary and a long meeting: the
   note is still produced (glossary is capped and counted in the 4096-token budget).
7. Upgrade path: launch with an old `watcher-config.json` (no `vocabulary` or
   `replacements`): Settings shows both empty and nothing else changes.
## Summary templates (#2940)

Unit tests cover the prompt, resolution order, guards and the pipeline with fakes; these need a
signed, running build.

- [ ] Settings > Notes > Templates: pick "Stand-up", Save, process a short recording. The note has
      the stand-up headings (Updates by person, Plans for today, Blockers, Action items, Open
      questions) and no "Technical scope". Set the picker back to "None": the next note is the
      standard 16-section note again.
- [ ] Custom: open "Custom template", press "Start from…" > "1:1", edit a heading, choose Custom,
      process a recording: the note uses the edited headings. Clear the text: "Empty - Custom
      behaves as None." shows and notes are standard.
- [ ] Folders: in the recordings folder make `Sales/` and `Standups/`; add rules Sales -> Sales call,
      Standups -> Stand-up; drop a recording in each. The two notes have different headings; a
      recording in the recordings root uses the "Note template" picker.
- [ ] Recorder: stop a recording; the "Who was in this meeting?" window has a "Note template" popup.
      Choose "Interview", Save: that note uses the interview headings even if a folder rule or
      the global setting says otherwise. Leave it on "Default (from Settings)": no
      `<base>.language.json` is written for that recording (check the work folder).
- [ ] Gemma (Direct only): process with a template; the Activity log routing line shows
      `template=<id>`, and the note has the template's headings with none repaired in by the
      "none stated" guard.
- [ ] Apple Intelligence (macOS 26+): same with a template on a long recording (map-reduce); the
      final note has the template headings. Not run by the author.
## Search Notes (Vikunja #2942)

1. Menu bar -> **Search Notes…** opens a resizable window with the field focused; type a distinctive phrase from an older note: results appear within a fraction of a second as you type, the match is bold/tinted in the excerpt.
2. Type an accented word without the accent (e.g. `reunio` for `reunió`): it still matches. Type `"`, `*`, `NEAR(` or `a -b`: no error, no crash.
3. Up/Down arrows move the selection while the field has focus; **Return** and **double-click** open the note in the default app. For a Transcripts hit, the note with the same name opens (the transcript file if the note was deleted).
4. Kind control (Notes & transcripts / Notes / Transcripts) and the Speaker popup (labels such as SPEAKER_00 from your transcripts) narrow the results.
5. Process a new recording, then search for a phrase from it: the new note is found without reopening the window. Edit a note by hand in an editor, reopen the window, search for the new text. Delete a note in Finder, reopen: it is gone from results (a stale hit shows "That file no longer exists").
0. Before ever opening Search Notes…, `~/Library/Application Support/Distavo/search-index.sqlite` must not exist, even after processing a recording. Opening the window for the first time shows "Indexing…" and creates it.
6. Ellipsis menu -> **Delete search index**: the file disappears and stays gone even after processing another recording; it is recreated only when you open Search Notes… again. **Rebuild search index** repopulates it.
7. Quit Distavo, overwrite the index file with garbage, relaunch: Distavo works normally and search is rebuilt.

Not exercised by unit tests: the SwiftUI window, focus, key handling, opening in the default app, the App Store container path.
## Shortcuts, URL scheme and Finder Service (#2953)

Needs a signed/launched build of each edition (Direct, App Store, Setapp); none of this can run headless. Unit tests cover only the URL parser and file naming.

1. **Services entry**: in Finder select a `.m4a` (and a `.pdf`), right-click -> Services. "Transcribe with Distavo" appears for the audio file (if missing: System Settings -> Keyboard -> Keyboard Shortcuts -> Services -> Files and Folders, tick it; it can take a relogin or `/System/Library/CoreServices/pbs -update`). Run it: the file appears in the recordings folder (never overwriting an existing name: run it twice and see `name 2.m4a`), and a note follows. Chosen on a `.pdf` it must show an error, not queue it.
2. **Shortcuts app**: search "Distavo". Run **Get Latest Note Path** -> returns the newest note's path (never a `.prev-` backup). Run **Get Latest Note** -> a Markdown file with the note text. **Transcribe File** with a Voice Memo export -> returns the queued file name; the note appears. Repeat in the App Store build: with the notes/recordings folders granted via the bookmark prompt, all three must work.
3. **Start Recording / Stop Recording** shortcuts: start shows the menu-bar recording state; stop ends it and the recording is processed. Start twice -> "A recording is already running". Stop when idle -> "No recording is running".
4. **URL scheme** (Terminal: `open distavo://...`): `open-latest-note` opens the note; `process-now` scans; `settings` opens Settings; `record/stop` stops. `record/start` MUST show "Start recording?" with Cancel as the default (press Return: nothing starts; Escape cancels), and opening the URL repeatedly while it is up must not stack alerts. Copy a multi-GB video through the Service: the menu bar stays responsive and a notification reports completion; no `.distavo-copy` file remains afterwards. `open "distavo://transcribe?path=/etc/hosts"`, `distavo://bogus` and `distavo://record%2Fstart` do nothing and leave a line in Console (`ignored unknown URL command`).
5. Confirm `plutil -p Distavo.app/Contents/Info.plist` lists `CFBundleURLTypes` and `NSServices` in every edition.
6. Existing users: nothing changes until one of these entry points is used (no new config keys, no new entitlements).
