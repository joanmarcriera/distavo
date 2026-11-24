# Voice profiles: implementation plan (Vikunja #2944, phase 2)

Status: **built on `feat/people-pages` (2026-11-23), not calibrated, not clicked through in a running app.**
What exists: steps 2 to 5 below with FluidAudio as the embedding source. Verified: 12 core tests on synthetic
vectors; `VoiceEmbedderLiveTests` (`DISTAVO_VOICE_LIVE=1`) on synthetic `say` voices: same voice 0.95, other
voices 0.18 to 0.35, so the 0.60 threshold and 0.10 margin separate them; Direct and App Store builds.
Differences from the plan: several samples per person (one per microphone path, best score wins) instead of
one running mean; the sample is taken from the source recording when the owner ticks the box, so no voiceprint
of an unnamed speaker is ever written. Recognition runs right after transcription and before the summary
(`VoiceRecognition.relabel`): the transcript, the timed transcript and the prompt carry the person's name, the
owner is found by their own remembered voice, the names are saved as an ordinary rename mapping (Rename
Speakers can reset them) and the note footer says which speakers were named by voice. Real recordings, no ground truth (`VoiceBenchLiveTests`, `DISTAVO_VOICE_BENCH=1`, numbers only, 2026-11-23): 15 recordings
with audio, 38 unnamed speakers with enough speech, 17 s to embed them all. Two speakers of the same meeting
(certainly different people) score -0.02 to 0.40, with one pair at 0.95 (the diariser split one person in two).
The best match in another meeting is either at most 0.49 or at least 0.63, nothing in between, so 0.60 sits in
the gap; it groups the 38 speakers into 22 voices, 10 of them in two to four meetings. "Name Voices…" (menu)
is the way to turn those into names. Still open: the real-audio 90% check and threshold
(Gates), the privacy wording for the App Store, the licence scope of the legacy model files (the model card
says the `pyannote_segmentation` / `wespeaker_v2` files are outside its stated licence scope; their upstreams
are MIT and CC-BY-4.0), and the manual checklist. Original plan follows (drive 2026-10-24). Read `docs/voice-profiles-feasibility.md` first: it records
what SpeakerKit and FluidAudio expose and the privacy analysis. This note turns it into an ordered,
edition-gated plan with the acceptance tests split into what CI can prove and what needs real audio.

## What is already shipped (phase 1, grep result)

* `DistavoCore/SpeakerRename.swift`: detect speakers, rename and merge across note, clean transcript and
  `.segments.json`, with a `.speaker-names.json` mapping and a `.prev-` backup. Runs under the scan lock.
* App side: Rename Speakers sheet inside the Notes window (`NotesWindow/`, `Speakers/`).
* The acceptance line "Rename rewrites all occurrences atomically and persists" is therefore met.
  Phase 2 ("remember voices, auto-label later") is the only open part of #2944.

## Edition gating

| Edition | Voice profiles | Why |
|---|---|---|
| Direct (`EDITION_DIRECT`) | first, behind the opt-in | fastest to verify on a signed build |
| Setapp (`EDITION_SETAPP`) | same code, same opt-in | no extra entitlement |
| App Store (`EDITION_APPSTORE`) | **ship last**, after the privacy answers are updated | the store has to be told about a voiceprint ("voice" data type, on device only); the store file lives in the Application Support container, so no new entitlement and no sandbox-prohibited call |

No `#if` is needed for the core types (pure, edition-neutral). The Settings section and the rename-sheet checkbox
are the only UI; gate the App Store one with a build flag until the privacy answer is submitted, so a binary
cannot reach review ahead of the declaration. Sparkle, donate link and "Run in Terminal" are untouched.

## Config (default off, inert for old configs)

`transcribe.voice_profiles`: `Bool`, **false** when the key is absent (migration rule), never set by
`Config.recommendedForThisMac()`. With it off, nothing is embedded, stored or matched, `Prompt.build` and the
note are byte-identical to today, and the `voice-profiles.json` file is never created.

Test to write with the key (the "default-off config test" of the task, deferred because this drive is docs only):

```swift
func testVoiceProfilesOffByDefaultAndForOldConfigs() throws {
    XCTAssertFalse(Config().transcribe.voiceProfiles)
    let old = try JSONDecoder().decode(Config.self, from: Data(#"{"transcribe":{"backend":"server"}}"#.utf8))
    XCTAssertFalse(old.transcribe.voiceProfiles)
    XCTAssertFalse(Config.recommendedForThisMac().transcribe.voiceProfiles)
}
```

## Steps, in order

1. **Measure, then pick the embedding source** (blocked on real audio; see Gates). Default recommendation:
   FluidAudio `extractSpeakerEmbedding` (already a dependency, public API, 256-d) over patching SpeakerKit.
2. **`VoiceProfiles` in DistavoCore (pure):** versioned store, cosine match with threshold plus margin over
   the runner-up, one profile per speaker per recording, running mean of L2-normalised samples, model-id
   check (embeddings of another model are ignored). Unit tests with **synthetic vectors only**: enrol,
   match above threshold, reject below, reject ambiguous (margin), two speakers cannot claim one profile,
   model mismatch ignored, delete one / delete all, file written 0600 and absent when empty.
3. **Embedding provider seam** in `PipelineDeps` (optional, default nil, like the other seams) with the
   engine in `DistavoEmbedded`. A fake provider returning fixed vectors drives pipeline tests.
4. **Apply through `SpeakerRename.apply`** so a match is an ordinary, undoable rename.
5. **Settings section** "Voice profiles" (one file in `Settings/Panes/Sections/`, plus the case in
   `SettingsPanes.swift` and `SettingsView.detail`): toggle, list, Delete / Delete all, plain-language
   consent copy. Rename sheet: per-speaker "Remember this voice", default unchecked.
6. **Docs and manual checks:** `docs/manual-checks-*.md` entry, privacy answers, `PRIVACY.md` line.

## Acceptance split

* CI-provable (steps 2-4): synthetic-vector tests above plus a pipeline test with the fake provider that
  proves (a) off means no file and an identical note, (b) on plus a matching profile renames, (c) a
  non-matching or ambiguous speaker keeps `SPEAKER_nn`.
* **Needs real audio (gate):** "2-person fixture auto-labelled >= 90% on a second recording". Enrol from
  recording 1, label recording 2, measure labelled-speech accuracy, pick the threshold from that data. The
  recordings must be consenting and synthetic or Marc's own; third-party interview audio must never be used.

## Gates for Marc

* Provide or record a consenting two-speaker pair (different rooms or mics if possible) for the 90% check.
* Approve the privacy-answer wording before the App Store build ships the feature.
* Decide SpeakerKit patch versus FluidAudio once the measurement exists.
