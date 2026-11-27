# People directory: what is built, what comes next (2026-11-23)

Why: notes name the wrong person. Distavo has no memory of who the owner talks with, so every meeting starts
from zero: the diariser hands out `SPEAKER_nn`, and the summary model guesses names from the conversation.
An owner talks with 10 to 50 people in a week, so a small directory that grows with use is enough.

## Built on `feat/people-pages` (step 1)

Menu **Update People Pages** writes `notes/people/<Name>.md` for each person and `notes/people/_People.md`
(index, most recently seen first). Spec: header of `DistavoCore/PeoplePages.swift`; tests `PeoplePagesTests`.

- A person comes only from what the owner confirmed: a speaker renamed in the Notes window (they spoke) or the
  "who was in this meeting?" answer (they were listed). A name the model guessed never creates a page.
- The page is the owner's: frontmatter `name`, `aliases`, `role`, `organisation`, `linkedin`, then free notes.
  Distavo rewrites only the marked "Meetings" block (first seen, last seen, each meeting linked) and fills
  `role` / `organisation` when they are empty. One Markdown file per person is the Obsidian convention and
  `aliases` is an Obsidian key, so the folder works as a vault as it is.
- Spellings merge through `aliases:` on the page and through `names.txt`.
- LinkedIn: while `linkedin:` is empty the page has a "Find on LinkedIn" link (LinkedIn's own people search,
  opened in the owner's browser). The owner pastes the profile address once. Distavo never contacts LinkedIn.
- Runs only from the menu; no config key; nothing changes in a note or a prompt.

Not checked: the menu item in a running app (the build compiles; nobody clicked it).

## Options, smallest first

| # | Idea | Size | What it fixes | Gate |
|---|---|---|---|---|
| 1 | Merge `feat/drive-distavo-channel-speakers` (owner = microphone channel) | built, unmerged | "which speaker is me" on every call | review + a real call |
| 2 | Known people in the prompt: a participant who has a page brings their role and organisation | **built 2026-11-23** (`summarise.known_people`, Settings > Notes > Names and owners), off by default | wrong roles and employers in notes | not tried with a real model |
| 3 | The participants question offers people from the people pages ("Add a person…"; calendar attendees were already pre-filled) | **built 2026-11-23** | retyping names; more confirmed names | the question was not opened in a running app |
| 4 | Refresh pages after each note, not only from the menu | **built 2026-11-23** (`notes.refresh_people_pages`, Settings > Notes > Names and owners, off by default) | pages go stale | opt-in key |
| 5 | Brief before a meeting: last three meetings with this person and their open action items (no model) | **built 2026-11-23** (menu "Meeting Brief…", `MeetingBrief.swift`, writes `people/_Brief.md`) | walking into a call cold | calendar match exists |
| 6 | Voice profiles: remember a named voice, name it next time (`docs/voice-profiles-plan.md`) | **built 2026-11-23**, off by default | the misidentification itself | threshold not calibrated on real voices; privacy wording before the App Store |
| 7 | "Name Voices…" (menu): the unnamed voices of past recordings grouped across meetings, a stretch to play, a name to type; naming renames every meeting of that voice and remembers it | **built 2026-11-23** | naming people once instead of per meeting; wrong labels | the window was not opened in a running app |
| 8 | Ask across people: "what did I promise Petra?" (Ask + people pages) | **built 2026-11-23** (`AskPeople.swift`: a question naming a confirmed person puts their meetings first) | finding commitments by person | local model quality |
| 9 | Web lookup by an agent: once per person, on request, store the address and the date, owner confirms | 2 to 3 days | filling `linkedin:` and employer | sends a name to a search engine: per-person opt-in |
| 10 | Organisations as pages, "introduced by", role history with dates | **partly built 2026-11-23**: `people/_Organisations.md` groups the pages by organisation; role history is the "said:" on each meeting line; "introduced by" not built | the network view | none |

## What the research says (sources in the session report; several points unverified)

- Voice matching: enrolment quality stops improving after about one minute of clean speech; thresholds depend on
  the model and the microphone, so they must be set on the owner's own recordings; keep one voice sample per
  microphone path per person; accept a match only above a threshold AND clear of the runner-up, otherwise ask.
- Other recorders converge on the same loop: calendar attendees as candidate names, the microphone channel as
  the owner, and a confirmation by the user that feeds the profile. Users complain most about retyping names.
- A voiceprint used to recognise a named person is biometric data (special category under UK and EU GDPR), and a
  professional user is not covered by the household exemption. So: off by default, per person, deletable, never
  synced, declared to the App Store before that edition ships it.
- LinkedIn's terms forbid automated access, logged in or not, and a court enforced that as contract. The safe
  routes are the two built here: the owner pastes the address, or opens a search in their own browser.

## In five years

The recorder becomes the owner's memory of their working relationships. It knows the voices it has been told
about and asks about the ones it has not. Before a call it shows who is coming, what was said last time and
what is still owed in both directions. After a call it drafts the follow-ups for the owner to send. All of it
on the Mac, with the people folder as plain files the owner can read, edit and delete.

## Built 2026-11-23: introductions, team, stated roles

- **Introductions** (`SelfIntroductions.swift`): an unnamed speaker who says "I'm Anna (from Acme)" in the first 5 minutes gets that name as a suggestion in Name Voices. Never applied without the owner pressing Name.
- **Team** (`VoiceTeams.swift`): who was named in the same meetings (from `.speaker-names.json` only). Used for one thing: a voice over the match threshold but within the margin of another remembered voice goes to the person who usually meets with the speakers already recognised. At least 2 meetings together and twice the rival's count, else unnamed. The note footer says when a name was chosen this way.
- **Stated roles** (`SelfIntroductions.said`): what a NAMED speaker says about their job early in a meeting ("I'm the head of platform at Acme"). Each meeting line of their page ends "· said: role, organisation", so a change over time is visible; the most recent statement fills `role:` / `organisation:` only while the owner left them empty. Deterministic (role-word list, en/es/ca), no model.
- Not built: merging two voices, choosing which recordings Name Voices listens to, a model reading the notes for responsibilities.


## Built 2026-11-23, second half: brief, organisations, queue, confirmations

- **Meeting Brief** (`MeetingBrief.swift`, menu "Meeting Brief…"): type who is coming; `people/_Brief.md` lists each person's role and organisation, the last three meetings and the open tasks of their meetings (theirs first). Tasks are written as plain lines, never `- [ ]`, so Action Items does not list them twice.
- **Organisations** (`PeoplePages.organisations`): `people/_Organisations.md`, rewritten with the index. Spellings differing in capitals are one organisation.
- **The index keeps a page whose notes are gone**, with the last-seen date of the page's own block.
- **Refresh after every note** (`notes.refresh_people_pages`, off by default).
- **Ask** prefers the meetings of a person the question names (full name, alias, or a first name only one confirmed person has).
- **A voice-recognised name is confirmed** by ticking it in Rename Speakers, or by remembering the voice under that name (`SpeakerNames.confirming`). Until then it never creates a page.
- **Remembered voices can be renamed and merged** (Settings > Transcription, "Rename…": typing the name of another remembered voice makes the two one person; `VoiceProfileStore.rename`).
- **Naming a voice is a queue**: one meeting at a time with progress, the scan lock released in between.
- **Name Voices listens to the 20 most recent recordings first** (`VoiceReview.firstBatch`), with "Listen to all".
- **Quitting while recording** stops through the normal path: the take, the typed notes and the typed people are saved. A recording recovered after a crash also keeps the people typed in Quick Notes.
- Not built: web lookup of a person (it would send a name to a search engine: needs the owner's decision), "introduced by", merging `feat/drive-distavo-channel-speakers` (needs a real call).
- Tests: `HardeningRound2Tests`, `HardeningPeoplePagesTests`, `MeetingBriefTests`, `AskPeopleTests`, and `PeopleFuzzTests` (seeded random input: parsers never crash, a page refresh never loses an owner line and is stable).

## Built 2026-11-23, third part: one person as two, two people as one

Four different mistakes, each with its own correction. None of them needs a model.

| What went wrong | Where it shows | The correction |
|---|---|---|
| One person, two speakers in ONE meeting (the diariser split them) | two `SPEAKER_nn` in that note | Notes > Rename Speakers: give both the same name (a merge; the transcript before it is kept as `.pre-merge-…`). Unchanged. |
| One person, two PEOPLE PAGES ("Petra N" and "Petra Novak") | two pages, two rows in the index | menu **Merge People…** (`PeopleMerge.merge`): the second name and its aliases become `aliases:` of the kept page, what the owner wrote on the other page is copied onto it as "## From the page of … (merged)", the other page is set aside byte for byte as `_merged-<Name>.md`, a remembered voice of the other becomes a voice of the kept person. Notes and transcripts are not rewritten: the alias joins them. |
| Two people merged into one PAGE by mistake | one page with the meetings of both | Merge People… > **Undo a Merge…** (`PeopleMerge.separate`): the set-aside page comes back, the kept page loses the aliases and the copied section (only while that section is still exactly as copied). A remembered voice is NOT taken apart again: forget it in Settings > Transcription if it is the wrong person's. |
| Two people, one speaker in a meeting (the diariser did not tell them apart) | one `SPEAKER_nn` saying what two people said | Transcript window > **Move to Speaker**: select what the other person said (a caret in a paragraph counts; a speaker line means the whole turn) and give it to an existing speaker or to "A New Speaker" (next free `SPEAKER_nn`, then named in Rename Speakers like any other). Saved at once like a transcript edit (`TranscriptEditing.reassigning`, originals kept, "Revert to original transcript" undoes it); the note changes at Re-summarise. A paragraph in which both people talk cannot be cut in two. |

The merge warns when both names SPOKE in the same meeting (`PeopleMerge.bothSpoke`): that is either a split inside a meeting (first row) or two different people.

Also in this part: "Anna and Pere" typed in the participants answer is two people (`SpeakerHints.joinedPeople`, shared with the speaker count; an item with a role after a dash or colon stays one person); "None", "TBD", "Nobody" are nobody; a name may have up to six words; "Dana Owner." in Settings is still the owner; Ask treats a one-word name that is an everyday word ("Will", "May", "Jo", "Pau") as the person only when it is written with its capital in the middle of a sentence; "I'm the CTO of Acme" is role CTO, organisation Acme; a page whose notes are gone sorts in the index by its own "last seen" day.

Rules added by the second review (2026-11-23):

- A merge or an undo that fails changes nothing: the page is moved first and moved back when the kept page cannot be written.
- Merges are undone last-first. After "A into B" and "B into C", undoing A is refused until B is undone, because B's set-aside page still carries A's spelling and text.
- A second file that says it is the other person (a Finder copy with the same `name:`) refuses the merge: it would become that person's page and take the meetings back.
- The undo is refused while another page lists the name as an alias, for the same reason.
- An `aliases:` list written as `- item` lines stays a list (comments and blank lines between the items are left alone); a page that had no `aliases:` line has none after the undo.
- What the owner wrote in the frontmatter of the other page is copied whole (a long LinkedIn address is not cut, a `notes: |` block is copied as one line).
- A named speaker counts as having spoken in a meeting only while a part of the transcript still carries the name (after Move to Speaker emptied them, or a Revert, they are no longer listed for that meeting; the name mapping itself is kept).
- "Anna E Smith" is one person (y / i / e join only in lower case); "Anna and Pere - sales" and "Anna from Acme and Pere from Beta" are two.

Transcript-window saves (a text edit or a move): every turn the save did not change stays in the clean transcript exactly as the pipeline wrote it (`TranscriptEditing.renderClean(_:previous:cachedClean:)`), so a replacement rule that spanned two segments and text the engine gave no times survive; only a turn the owner changed is rendered from its segments. Since the third review the merge is careful first: the turns of the segments must line up with the cached turns in exactly one way (same speaker line, same first and last letters; `aligned` compares the earliest and the latest placement), otherwise the plain render is written, which holds every timed word once. A cached-only turn (a speaker whose only segment had no times) stays next to an unchanged turn and between turns whose words changed but not their speakers; inside a stretch a Move joined or split it is left out. `TranscriptSaveMergeFuzzTests` pins it: no timed segment lost, doubled, reordered or under the wrong speaker. A save, move or revert is refused while that note is being re-summarised. The Merge People lists are read off the main thread.

Rules added by the third review (2026-11-24):
- Names are compared as `lowercased()` everywhere a merge looks for a page ("Strauß" and "Strauss" are two people, as in the pages themselves).
- Frontmatter reading: a comment line is nobody's value; the indented lines of a block value (`notes: |`) are not keys; a list item may be written `-<tab>Item` and may carry a trailing comment; the `]` that closes a flow list is the first one outside quotes; an alias may contain double quotes.
- "Anna from Marks and Spencer for the audit" is one person: a second person is read only after "and <Capital>" outside brackets when that part uses the same joining word as the first.
- A named speaker counts as having spoken while a segment OR a turn of the clean transcript still carries the name.
- Undo: when the copied section was edited since the merge it stays on the kept page and the notification says so (`Outcome.textLeft`); when the owner renamed the kept page, the one page listing the name is used.
- Roles: "I'm X, I'm the CTO" reads the second half; "owner of the budget" is not a role; a job after "of/de/del" needs a capitalised employer. Ask: Catalan l'/d', month names as names ("May" after in/of/by is a month), a name after a sentence break. Typed names lose invisible marks (bidi, zero-width).
- The activity log never carries the participants line or speaker names (counts only).

Not built: looking a person up on the web (it would send a name to a search engine: the owner's decision), "introduced by" ("Anna, this is Pere"), cutting one transcript paragraph between two speakers.

Rules added by the real-data rounds (2026-11-24, checked on a copy of the owner's data with `CopyDataLiveTests`):
- A remark typed in the participants answer is not a person ("He is", "Head of procurement in Vic", a sentence, "PN => Petra Novak"): `PeoplePages.isPersonName` refuses sentence punctuation, sentence words in lower case and more than one lower-case word that is no name particle. A page that already exists still names its person however it is written.
- Undo a Merge takes back exactly what the merge brought in: the record keeps which of the kept page's `role`/`organisation` were empty (`emptyFields`), what an update filled into them while merged (`filled`, written by `PeopleMerge.noteFilled`), and the kept page's meetings block (`block`). A value the owner typed while merged stays.
- Ask: the longest name in a question wins ("Anna Puig" does not also name the page "Anna").
- Brief: a task under the transcript's spelling of a name ("owner: Oscar Lind" for Oskar Lind, one letter off per word of four letters or more) is theirs, unless someone confirmed is called exactly that.
- Transcript save: a save that changes no turn keeps the cached text; files with the same speakers in the same order are taken turn for turn, and only where one speaker goes on in the next turn must both sides of that cut agree.

## A page made by a change that was undone (2026-11-27)

A page is never removed by "Update People Pages": when its person is in no meeting any more it stays, as history. One exception, in Review Voices only: renaming or correcting a voice writes the page of the new name, and Undo right after takes that page back (`PeoplePages.removeUnusedNewPages`) when all three hold: Distavo made it during that change, the name is in no meeting now, and nobody wrote in it (no line of text, no role, organisation, alias or LinkedIn address). The list of pages a change made is kept in memory only, so an undo after a relaunch leaves the page; delete it by hand.
