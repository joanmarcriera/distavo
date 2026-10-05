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

## Action items and decisions (#2941)

Needs a signed build of each edition (Reminders permission and entitlements cannot be exercised
unsigned or headless). Do NOT run from a build that shares your real config without a backup.

- [ ] Settings > Notes > Action items: off by default on an existing install. Turn on, process (or
      Regenerate) a recording: the note has `## Tasks` (lines like
      `- [ ] Send quote — owner: Ana; due: 2026-10-12`) and `## Decisions`, and no `## Action items`.
      Turn it off again: a regenerated note is back to the stock sections.
- [ ] Menu bar > Open Action Items…: lists open items grouped by note, newest first; hand-written
      `- [ ]` lines in other notes appear too; `.prev-` backups never do.
- [ ] Tick an item: the note file now has `- [x]` on exactly that line (check with `git diff`/Finder
      preview; nothing else changed). Edit that line by hand in an editor, then tick it in the
      window: an error shows and the box reverts; file untouched.
- [ ] Reminders (all three editions): click "Send to Reminders" on an item. macOS asks for Reminders
      access ONCE, only now (never at launch). Allow: a reminder appears in the default list with
      the task text, the due date (when parsed) and the meeting title + note file URL in Notes.
      Click again: "Already in Reminders", no duplicate.
- [ ] Deny (or revoke in System Settings > Privacy & Security > Reminders): the window explains how
      to enable it and offers the settings link; ticking, "Open note" and refresh keep working.
- [ ] Sandbox (App Store build): the same flow works with the Calendars entitlement
      (`com.apple.security.personal-information.calendars`); if the prompt never appears or the save
      fails, that entitlement is not enough for Reminders under the sandbox and needs another look.
- [ ] Hardened runtime (Direct / Setapp): same flow; the prompt must appear (the Calendars
      entitlement is in `Distavo.entitlements`). If macOS silently denies, check `codesign -d
      --entitlements - Distavo.app`.

### Action items: known limits (#2941)

- Reminders de-duplication is by item identity (note path + line text + ordinal), kept in
  `reminders-exported.json` in the work folder. Editing an item's text, or renaming/moving the
  note, after it was sent makes it a new item: sending it again creates a second reminder.
  A corrupt ledger is moved aside as `reminders-exported.json.corrupt-<time>` (never silently reset).
- Ticking writes one byte in place (symlinks, tags and permissions are kept). The window scans the
  newest 500 notes only. Ticks wait up to ~3 s for a scan/regenerate to finish, else say to retry.
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

## Quick Notes while recording (#2949)

Needs a launched build (any edition) with a real recording; the panel, focus and the model's behaviour cannot be exercised headless. Unit tests cover the sidecar, the prompt block, the budget, the Highlights safety net and `processOne`/`regenerate` plumbing only.

1. Menu bar shows **Quick Notes…** only while a recording runs (under "Stop and delete recording"). Idle: absent. macOS < 14.4: the whole recorder section is hidden, so it is too.
2. Start recording, open Quick Notes. The panel floats above the meeting window and takes typing without pulling focus from the call app. Type `ask about notice period`, Return -> a line stamped with the elapsed time appears above the field. Type `!decision: option B`, Return -> shown with a filled star. Edit a line in place, toggle a star, delete a line.
3. While recording, `~/Library/Application Support/Distavo/work/<base>.scratchpad.json` exists and follows each edit (`<base>` = the recording name with spaces as `_`/as `DistavoState.baseFor` writes it; the `.wav.part` sits in the recordings folder). Deleting every line removes the file.
4. Stop. The panel closes; the sidecar stays. When the note is written it contains a `## Highlights` section directly after `# Meeting notes`, one bullet per typed line (flagged ones start with a star), ideally with what the meeting said about each. Repeat with a model that ignores instructions (or Apple's on-device model): the section must still appear with the lines verbatim and their mm:ss.
5. **Regenerate Note…** on that note keeps the Highlights (the sidecar is reused).
6. **Stop and delete recording** after typing a note: `<base>.scratchpad.json` is gone and the panel closes.
7. Crash recovery: type a note, `kill -9` Distavo mid-recording, relaunch. The `.wav.part` is recovered to `<name>.wav` and the note it produces carries the Highlights.
8. A recording with no notes typed: no sidecar, no Highlights section, summary prompt unchanged.
9. On-device (Apple) model with 20 long lines: the note still generates (lines are capped at 20 lines / 140 chars / 800 chars total).

### Quick Notes follow-ups (#2949)

10. Type a note but do NOT press Return, then Stop (and, separately, let the silence auto-stop fire): the note is still in the sidecar and the Highlights. **Stop and delete recording** discards an unsent draft too.
11. Screen sharing: share your screen in Zoom/Meet while the panel is open; participants must NOT see the Quick Notes panel (`sharingType = .none`). The panel's footer says it is hidden from screen sharing.
12. Edits are written after about half a second of quiet (off the main thread); typing stays smooth in a long session, and Stop flushes everything.
13. Move a too-short recording to the Bin from the menu: its `<base>.scratchpad.json` is removed.
## Processing Queue window (#2952)

Needs a launched build (Direct and App Store); the window, drag and drop and Pause cannot run headless. Unit tests cover the reducer, ETA maths, ordering, pause-between-files, single-file retry and a 20-file sequential run (`ProcessingQueueTests`).

1. Menu bar -> **Processing Queue…** opens a resizable window. With an empty folder it shows the "Drop audio or video files here" hint.
2. **Drop 20 audio files** from Finder onto the window: the drop outline appears; rows show **Copying** one after another (never 20 copies at once; the menu bar and window stay responsive), then **Waiting**, then exactly ONE row at a time moves through Converting -> Transcribing -> Summarising -> Done, in path (alphabetical) order. No ETA/progress bar on the first file; after the first completes, waiting rows and later files show "about N min" and the toolbar shows the total.
3. Drop a **folder**, a `.pdf` and a `.mkv`: each is rejected with an orange message under the list; nothing is copied. Drop a file already inside the recordings folder: no duplicate is made. Drop the same file twice: second copy is `name 2.m4a`.
4. **Pause** while file N is running: file N finishes and gets its note, file N+1 never starts, the status reads "Paused" (not "Last note"), the icon does not flash. Pause holds AUTOMATIC work only: while paused, menu/window **Process now**, `distavo://process-now`, the Finder Service / Transcribe File, enabling local Ollama, "Retry failed" and a row's **Retry** all still run (Process now runs the whole pass once). **Resume** continues the timer. Quit and relaunch while paused: the app is NOT paused.
5. **Skip** a waiting row: it shows Skipped and is not processed; Restore puts it back. Relaunch: the skipped file is processed again (it never left the folder). A running row's context menu shows Cancel greyed with the reason; there is intentionally no way to stop a file mid-process.
6. **Retry**: make a file fail (e.g. point the summariser at a dead port with local fallback allowed, or drop a corrupt `.m4a`), then fix the cause. With two failed rows, choose Retry on ONE: only that row restarts (next after the current file) and the other stays Failed; no other pending file jumps in. "Process now" still retries all failed files.
7. **Reprocess with another model or language…** on a Done row: the existing model/language sheet appears; the run shows as an extra row "name @model-lang" and the note lands beside the normal one. Compare… lists both.
8. Context menu: **Reveal in Finder**, **Open note**, **Move recording to the Bin** (also clears its failed/too-short marker; the menu-bar failed list updates).
9. **Deferred**: stop Ollama with local fallback off, drop a file: row goes to "Waiting to retry" (not Failed); start Ollama, within one scan it processes. A too-short clip shows "Too short" and is not retried by Retry.
10. App Store build: repeat 2 with files dragged from the Desktop and from an external volume (sandbox access for the dropped URLs must last until the LAST serial copy, minutes later).
11. Leave the window open during a long run for ~10 minutes: CPU stays low (list refreshes every 3 s from disk, progress at about 4 Hz).
## Key moments and clip export (#2950)

Needs a real recording and a launched build; the hotkey, the icon cue, clip playback and the sandboxed
export cannot be exercised headless. The step-by-step list is in
[meeting-capture-verification.md](meeting-capture-verification.md#key-moments-and-clip-export-vikunja-2950---unverified-until-run-on-a-real-build):
3 presses give 3 correct markers, clip -15 s/+30 s plays correctly, hotkey conflict, App Store build.

## Obsidian-friendly output (#2954)

Unit tests cover YAML escaping, split/strip, idempotent regenerate, title/tags parsing, tracked
terms, the vault planner and the pipeline with fakes. These need a signed, running build and a
real model. All settings live in Settings > Notes > "Obsidian & frontmatter" and default to off.

- [ ] Upgrade path: launch with an old `watcher-config.json` (no `notes` key). Settings shows every
      toggle off, the vault as "None", tracked terms empty; the next note is identical to before
      (no `---` block, no "Tracked terms" section, no extra prompt text).
- [ ] Turn on "Add frontmatter", process a recording: the note opens with `date`, `attendees`,
      `tags: [meeting, lang/xx]`, `source`, `duration_minutes`. Open it in Obsidian: Properties shows
      them, and a participant like `Edward (Cambridge) — interviewer` appears as `Edward (Cambridge)`.
- [ ] "Suggest a title" + "Suggest tags" with Ollama (gemma4:26b) and again with Apple Intelligence
      (macOS 26+, long recording): the note has a `title:` and up to 6 tags, no `Distavo-Title` /
      `Distavo-Tags` text anywhere in the body, and the note is still produced if you switch to a
      model that ignores the request (title/tags simply absent). The note file name in the notes
      folder does NOT change.
- [ ] Tracked terms: add `pricing` (a word you say in a test recording). The note ends (before the
      "Transcribed on this Mac" footer) with `## Tracked terms` and a line
      `- [mm:ss] **pricing** — "…context…" (SPEAKER_00)`; the tag `pricing` is in the frontmatter.
      Process a recording with a WhisperX server that returns no timings: lines have no `[mm:ss]`.
- [ ] Vault (Direct): Choose… a folder inside an Obsidian vault, optionally a sub-folder
      "Meetings". After a recording a file `<date> <title or base>.md` appears there and Obsidian
      indexes it. Regenerate the note (new title): the SAME vault file is updated, not duplicated.
      Edit the vault copy in Obsidian, regenerate again: your edit is kept and the new version is
      saved as `… 2.md`.
- [ ] Vault (App Store build, sandbox): same, after quitting and relaunching (the security-scoped
      bookmark `bookmark.vault` must survive). Not run by the author. The App Store entitlements
      already carry `files.user-selected.read-write` and `files.bookmarks.app-scope`.
- [ ] Unmount/rename the vault folder, process a recording: the note is written normally, a
      "Note not copied to your vault" notification appears and the Activity log says why; the
      folder is not re-created.
- [ ] Compare view (Process a recording with…) shows the note body without the YAML block.
- [ ] Known limit: regenerating a note rewrites `date/title/attendees/tags/source/duration_minutes`
      in its frontmatter; other keys you added are preserved. A note with frontmatter OFF has no
      block to preserve, and its vault copy is only replaced in place while the copy is untouched.
