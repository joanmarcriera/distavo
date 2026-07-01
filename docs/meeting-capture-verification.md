# Meeting capture — manual verification checklist

The Core Audio tap + TCC permission flow cannot run in CI (TCC prompts require
a signed, interactively-approved build). Run this once per release on real
hardware (macOS 14.4+). Takes ~5 minutes.

## Setup

```sh
cd apple && xcodegen generate
xcodebuild -project Distavo.xcodeproj -scheme Distavo -configuration Debug \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" build   # ad-hoc signed (TCC needs a signature)
open build/Build/Products/Debug/Distavo.app
```

To re-test the first-run experience:

```sh
tccutil reset SystemAudioCaptureRequests uk.co.riera.distavo
tccutil reset Microphone uk.co.riera.distavo
defaults delete uk.co.riera.distavo distavo.didExplainCapture
```

## Checklist

1. **Menu item** — "● Record meeting (system audio + mic)" appears in the menu
   (hidden on macOS < 14.4).
2. **Pre-flight** — first click shows the explanation dialog (two permissions,
   purple indicator, headphones tip, cleanup). Cancel aborts; nothing prompts.
3. **Permission prompts** — on Continue: Microphone prompt, then on tap
   creation the System Audio Recording prompt. Approve both.
4. **While recording** — menu shows "⏹ Stop recording (m:ss)" with a live
   counter; macOS shows the purple/recording indicator. Play known speech:
   `afplay /System/Library/Sounds/Glass.aiff` (any audio) or better a speech
   clip; also say a few words near the mic.
5. **Audio MIDI Setup** — open it while recording: **no** Distavo aggregate
   device is visible (it's private).
6. **Stop** — notification "Meeting recording saved"; a
   `Meeting YYYY-MM-DD HH.mm.ss.wav` appears in the recordings folder; within a
   scan interval the pipeline picks it up and (with an engine configured)
   produces a note. Open the WAV: left channel = mic, right = system audio.
7. **Zoom/Meet concurrency** — start a test meeting (e.g. meet.google.com with
   yourself), record 30 s: both your voice and the meeting audio are captured
   while the meeting app is actively using mic + speakers.
8. **Denied system audio** — reset TCC (above), record again but **deny** the
   System Audio Recording prompt: recording still completes, and on stop the
   "no system audio was captured" warning appears and System Settings opens at
   the right pane.
9. **Cleanup** — after quitting Distavo: no aggregate devices in Audio MIDI
   Setup, no leftover processes; the only traces are the two toggles in
   System Settings → Privacy & Security.

## Known caveats (documented, not bugs)

- Loudspeakers (no headphones): the mic also hears the remote participants, so
  their words can appear twice in the transcript. The pre-flight says this.
- Bluetooth headsets drop to call quality (HFP) during meetings — capture
  works, fidelity is lower.
- Apps using exclusive-mode (hog) audio can't be tapped (rare pro-audio tools;
  not the mainstream meeting apps).
- Pre-14.4: the menu item is hidden; users can still record with any external
  tool (QuickTime, or BlackHole for DIYers) into the watched folder.
