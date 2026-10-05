# Voice profiles: feasibility (Vikunja #2944, phase 2)

Status: **investigated, not implemented.** Phase 1 (rename speakers) shipped in 1.17. Phase 2 is
"remember speaker embeddings locally to auto-label later meetings (deletable)", acceptance "a
2-person fixture is auto-labelled >= 90% on a second recording". That acceptance needs real
two-person audio and a model run, which could not be done in the build environment, so nothing
was built. This note records what the pinned diarisers expose and what the work would be.

## What the pinned diarisers expose

Checked in `apple/DistavoEmbedded/.build/checkouts/` at the revisions in `Package.resolved`.

### SpeakerKit (argmax-oss-swift 1.0.0, rev 25c6299) - the diariser Distavo uses today

`EmbeddedTranscriber` / `ParakeetTranscriber` diarise with SpeakerKit (pyannote).

* The pyannote pipeline computes per-speaker embeddings (`SpeakerEmbedderModel`, `SpeakerClustering`),
  but the type carrying them, `struct SpeakerEmbedding { embedding: [Float]; pldaEmbedding: [Float]? ... }`,
  is **internal** (`Sources/SpeakerKit/Pyannote/SpeakerEmbedderModel.swift:7`).
  `PyannoteDiarizer` consumes it inside `diarize(...)` and returns only `DiarizationResult`.
* `DiarizationResult` is public but exposes only `speakerCount`, `totalFrames`, `frameRate`, `segments`
  (`SpeakerSegment`: time range + speaker id) and timings. **No embeddings, no centroids.**
* Conclusion: with SpeakerKit as shipped, per-speaker embeddings are not reachable. Options: a fork or
  patch of argmax-oss-swift to make them public (maintenance burden, and `Package.resolved` pin
  becomes a fork), or running a second embedding model separately (below). Asking upstream to expose the
  clusterer's `speakerEmbeddings()` is the cleanest route but is outside our control.

### FluidAudio (pinned to rev 41540ea) - already a dependency (Parakeet)

FluidAudio's diariser *does* expose what a voice-profile feature needs, publicly:

* `DiarizerManager.extractSpeakerEmbedding(from: [Float]) -> [Float]` - L2-normalised 256-d WeSpeaker
  embedding from 16 kHz mono samples of one speaker (`Diarizer/Core/DiarizerManager.swift:92`).
* `DiarizerManager.initializeKnownSpeakers([Speaker])` and `SpeakerManager`
  (`findSpeaker(with:speakerThreshold:)`, `assignSpeaker`, `makeSpeakerPermanent`, `mergeSpeaker`,
  `removeSpeaker`, ...) - a built-in known-speaker database with cosine-distance matching.
* `Speaker` / `ChunkEmbedding` are `Codable`, `Sendable`.

So the matching half exists off the shelf; it needs FluidAudio's diarisation models (segmentation +
embedding Core ML, a separate download from the Parakeet model) and a way to line its output up with
SpeakerKit's speaker ids, or to switch the whole diarisation step to FluidAudio (a larger change that
affects every Whisper/Parakeet recording, with its own accuracy and speed trade-offs).

## Proposed design

1. **Capture.** After diarisation, for each speaker take the audio of that speaker's longest clean turns
   (e.g. up to 30 s of non-overlapping speech) from the 16 kHz work WAV and compute one embedding with
   `extractSpeakerEmbedding`. Do this only for speakers the user has *named* (phase 1's rename sheet is
   the natural trigger: a "Remember this voice" checkbox per named speaker, default off).
2. **Store.** `~/Library/Application Support/Distavo/voice-profiles.json`, versioned:
   `{ version, model: "<embedding model id>", profiles: [{ id, name, embedding: [256 floats],
   samples: n, created, updated }] }`. Same Application Support root as everything else, so it works
   under the App Store sandbox container with no new entitlement. Embeddings from a different model id
   are ignored (never mixed). Running mean of L2-normalised samples, re-normalised.
3. **Match.** On a new recording, embed each diarised speaker and compare by cosine similarity to every
   profile. Auto-label only above a conservative threshold with a margin over the runner-up; two
   speakers in one recording may not claim the same profile; below the threshold keep `SPEAKER_nn`.
   Apply through the existing `SpeakerRename.apply`, so the note, transcript, segments sidecar and the
   `.speaker-names.json` mapping stay consistent, and the result is a normal rename the user can undo.
4. **Delete.** Settings -> a "Voice profiles" list with per-profile Delete and "Delete all"; deleting
   removes the entry from the file (and the file when empty). No copy is kept in backups of notes: notes
   and sidecars carry names only, never embeddings.

## Privacy

A voice embedding is **biometric data** (UK GDPR / EU GDPR special category when used to identify a
person), even when it never leaves the Mac, and Distavo records other people (meeting participants),
not only the user. Requirements if built:

* **Opt-in, default off**, new config key (decodes to off for configs predating it, per the migration
  rule) plus a per-speaker "Remember this voice" choice. Nothing is computed or stored otherwise.
* **Local only**: never uploaded, synced, logged, exported, or included in issue reports
  (`IssueReport`) or the activity log. Exclude the file from any "share diagnostics" path.
* **Deletable** per person and in bulk, and removed by the app's reset/uninstall guidance.
* Settings copy must say that it stores a voiceprint of people who spoke in recordings and that the
  user is responsible for having their consent where the law requires it.
* File permissions 0600; embeddings stored in the Application Support container, not in the
  recordings/notes folders (which may be synced to iCloud/Drive).

## Work needed (estimate: 4-6 days plus real audio)

1. Decide the embedding source: patch SpeakerKit to expose cluster centroids (preferred accuracy-wise,
   since it is the diariser that produced the labels) or add FluidAudio's diarizer models (extra
   download, second diarisation-grade model on the Neural Engine). Measure before choosing.
2. `VoiceProfiles` (DistavoCore, pure): the store, cosine matching with threshold + margin, running-mean
   update, versioning; unit-tested with synthetic vectors.
3. An embedding provider seam in `PipelineDeps` (optional, default nil) with the engine in
   `DistavoEmbedded`.
4. Config key + Settings section (opt-in toggle, list, delete) and the "Remember this voice" control
   in the rename sheet.
5. **Acceptance test on real audio:** a 2-person fixture, enrol from recording 1, auto-label recording 2,
   measure >= 90% of labelled speech correct. Needs real, consenting two-speaker recordings (ideally
   different rooms/mics too, since embeddings drift with channel) and a run of the models; none of
   that is available in CI or in this environment. Pick the threshold from that data, not by guess.
6. Manual checklist entries; a privacy line in the App Store privacy answers review (the data is on
   device only, but the "voice" data type is worth declaring conservatively).
