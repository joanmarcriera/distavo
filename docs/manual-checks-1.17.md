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
## Rename Speakers (Vikunja #2944, phase 1)

Unit tests cover detection, whole-token rewriting, swap/merge, atomic rollback and the regenerate flow;
the window and notifications have not been opened in a real app. Use a Debug/signed build, not alongside
your daily Distavo (shared config and data folder). Prerequisite: a note made on 1.17 (has
`<base>.segments.json` and `<base>.transcript.clean.txt` in `~/Library/Application Support/Distavo/work`)
with at least two speakers.

1. Menu bar -> **Rename Speakers…** opens a window listing your notes (newest first); each detected speaker shows
   its label, turn count, a sample line and a name field.
2. Rename `SPEAKER_00` to a name and press **Apply**. A notification says speakers were renamed. The note
   now has the name wherever the label was; `<base>.prev-<date>.md` holds the old note; the work folder has
   `<base>.speaker-names.json` (`{"names": {"SPEAKER_00": "…"}}`).
3. Menu -> **Export transcript as…** (SRT or HTML): the speakers carry the new names. **Regenerate Note…**
   produces a note using the new names.
4. Open the window again and rename the same speaker a second time: it composes (the sidecar still maps the
   original `SPEAKER_00` to the latest name). Give two speakers the same name: they merge.
5. Clearing a name field disables Apply; names with `[` or `]` are refused. Only label positions change (speaker headers, a `## Speakers` list, `**Name:**`, `(Name)`, Owner column / `owner: Name`) plus `SPEAKER_nn` anywhere outside code and links; a sentence that merely mentions the name is left alone, the title and footer too.
5b. Give two speakers the same name: a confirmation "Merge X into Y? This cannot be undone from the app" appears, and `….pre-merge-…` copies of the transcript and timestamps appear in the work folder. After a plain rename the window offers **Reset to original labels**. With full-text search enabled, searching the new name finds the note.
6. Open an older note without a segments file or cached transcript: speakers found in the note text are
   still renamable; the missing files are skipped silently.
7. Hand-edit the note first, then rename: your edits survive, only the speaker tokens change.
8. Start a scan and press Apply while it runs: the rename waits for the scan (single-flight).
9. `SPEAKER_1` vs `SPEAKER_10`: renaming one never touches the other (unit-tested; spot-check in a long note).

10. Type a name: under the list the window shows how many note lines will change with a preview of up to 5; a line like `- Mark: the release date` shows up there so you can cancel.
11. **Reset to original labels** resets the transcript, timestamps and mapping exactly. The note is restored to its pre-rename state only if you did not edit it since the last rename; otherwise it is left as it is and the notification says so. After a merge the button is replaced by a note and a "Show copies" button.

Phase 2 (voice profiles) is not built; see `docs/voice-profiles-feasibility.md`.

## Transcript viewer (Vikunja #2951)

Needs a signed or Debug build of the real app and a recording processed with this version (the
timed sidecar `<base>.segments.json` only exists for those); do NOT run it beside your daily
Distavo. Do once in Direct and once in the App Store edition (the latter reads the recording through
the folder bookmark). Use one two-speaker recording of 10+ minutes, ideally also a 1-2 hour one.

Playback and seek
1. Menu bar -> **Open Transcript…**: window opens on the newest note; transcript grouped by speaker
   turns, header lines `SPEAKER_00  ·  m:ss`. The bottom bar is enabled and shows `0:00 / <length>`.
2. Click a word in the middle of a paragraph: audio jumps there and plays. Measure click-to-sound
   with the screen recording at 60 fps: it must be under 0.3 s (try mp3/m4a and a WAV). Repeat 10
   times; also click a word already highlighted and a word in a distant turn.
3. While playing, the highlighted word follows the speech within about one word; the highlight moves
   smoothly (no flicker, no visible re-layout) and the window follows the playing word by
   scrolling it to the middle. Scroll by hand: following pauses for ~4 s then resumes.
4. Space plays/pauses (text area focused, Edit off). Option-Command-Left/Right skip 5 s. Speed 1x/1.5x/2x
   changes playback speed live without a seek.
5. Click a speaker header: seeks to the start of that turn.
6. Playback sources: a recording the app already compacted to a 16 kHz mono WAV plays; a stereo
   in-app meeting recording (mic left, system audio right) plays both sides; a .mp4/.mov source plays audio.
7. Move the recording out of the recordings folder, reopen the window: it opens, shows the text,
   the bar is disabled with the line "Playback is off: the recording file was not found…"; reading
   and editing still work.
8. 2-hour transcript: window opens in about a second; during playback CPU stays low (Activity Monitor,
   Distavo under ~10%); scrolling and typing stay responsive.

Editing
9. **Edit**: click into a paragraph and fix a word. Typing works; Return does nothing; you cannot
   type into or delete a speaker header, and Backspace at the start of a paragraph does not merge
   paragraphs. Save and Discard appear; the Note picker is disabled.
10. **Save** (Command-S): banner says saved and that the note is stale. Work folder now has
    `<base>.segments.orig.json` and `<base>.transcript.clean.orig.txt` (unchanged bytes of the
    pre-edit files) next to the edited `<base>.segments.json` / `<base>.transcript.clean.txt`. Edit and save again:
    the `.orig` files do not change. The note file is NOT modified by saving.
11. The edited paragraph still plays and highlights as one block; unedited paragraphs still highlight word by word.
12. **Re-summarise**: runs, the notes folder gets a new `<base>.md` built from the edited text
    (check the corrected word appears) and `<base>.prev-<stamp>.md` holds the old note. Banner reports the outcome.
13. **Revert to original transcript…**: confirm; text returns to the first version, `.orig` files
    remain, Re-summarise would rewrite from it.
14. Edit something, then close the window with the red button: prompt Save / Discard / Cancel; Cancel keeps it open;
    Save keeps the window open if the save fails (make the work folder read-only to try: nothing changes on disk).
15. Open Search Notes… (search enabled) and look for the corrected word: it is found in the transcript hit after a save.
16. Old recording without a sidecar: window shows the cleaned transcript read-only, banner says timestamps were not saved,
    Edit is disabled, the playback bar is disabled; Re-summarise still works.
17. Dark mode: header text and the highlight are readable.

Not covered by unit tests: all of the above window behaviour, AVPlayer seek latency, the highlight cadence,
auto-scroll, and the App Store sandbox read of the recording. Speaker relabelling is supported by the edit
model (`SegmentEdit.speaker`) but there is no UI for it in this version.
