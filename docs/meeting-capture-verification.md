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
7a. **Mic-only preamble** — with **no** system audio playing at all, start a
   recording, speak immediately for ~10 s, then play any audio, then stop.
   Your speech must be present **from the first seconds** of the WAV (a
   regression here means the aggregate waited for the tap — see the
   `kAudioAggregateDeviceTapAutoStartKey` comment in `MeetingRecorder`).
   While recording, a `Meeting … .wav.part` file exists; on stop it becomes
   the final `.wav`.
7b. **Channel balance** — speak quietly while loud meeting/media audio plays.
   In the saved WAV both channels come out at comparable loudness (the quiet
   mic side is boosted, up to +24 dB, never clipped). A channel that was
   truly silent stays silent.
8. **Denied system audio** — reset TCC (above), record again but **deny** the
   System Audio Recording prompt: recording still completes, and on stop the
   "no system audio was captured" warning appears and System Settings opens at
   the right pane.
9. **Cleanup** — after quitting Distavo: no aggregate devices in Audio MIDI
   Setup, no leftover processes; the only traces are the two toggles in
   System Settings → Privacy & Security.
10. **Silence handling (Vikunja #2665)** — in Settings → Recordings turn on
   "Suggest stopping after silence" (1 min) and "Stop recording automatically
   after silence" (3 min); with a play-something-then-stop setup:
   - Play audio for a few seconds, then stay silent with the mic quiet. After
     ~1 min a notification "Still recording — no sound for 1 min" appears with
     **Stop recording** / **Keep recording** actions; the menu Stop item reads
     "Stop recording (m:ss · silent 1 min)", a "Keep recording" item appears and
     the icon turns orange.
   - Make a sound: the notification and the menu notice disappear, icon back
     to red.
   - Repeat, choose **Keep recording** (notification or menu): no auto-stop
     happens in that stretch of silence; after a sound and another silence the
     suggestion returns.
   - Repeat and ignore it: at 3 min the recording stops by itself, the
     "Recording stopped after 3 min of silence" notification shows, **no** "Who
     was in this meeting?" dialog appears (nobody is there to answer), and the
     WAV is finalised and transcribed straight away with no speaker hints and
     no language override, as if Skip had been pressed (no System Settings
     window even if no system audio was captured). While it stops, other
     Distavo work (scans, progress) is not frozen.
   - Choosing **Stop recording** on the notification (or the menu) is a manual
     stop: the "Who was in this meeting?" dialog does appear, and the menu
     keeps updating while it is open.
   - Turn "Suggest stopping" off while a suggestion is showing: the notice,
     the orange icon and the delivered notification go away.
   - **Notifications denied** (System Settings → Notifications → Distavo off):
     the menu notice, "Keep recording" item and orange icon still appear.
   - Start a recording in silence and never make a sound: auto-stop must NOT
     fire (nothing was heard yet); the suggestion still may.
   - Mic muted but the call audio playing (and the reverse) is never "silence".
   - The recorder cannot run in CI; this section is the only end-to-end check.

## Meeting detection (Vikunja #2945) — UNVERIFIED until run on signed builds

Unit tests cover the policy (`MeetingDetectorTests`, `MeetingDetectionConfigTests`).
Everything below needs a real Mac and a real call. **Run it on BOTH a Direct build
and a sandboxed App Store (TestFlight / Release-AppStore, signed) build** — the
open questions are (a) whether Core Audio's per-process objects
(`kAudioHardwarePropertyProcessObjectList`, then per process
`kAudioProcessPropertyIsRunningInput` / `…BundleID` / `…PID`, macOS 14.2+) return
real values, with no TCC prompt, under the App Sandbox, and (b) whether each call
app captures under its own bundle id or a helper's. The signal is "WHICH process
captures input", not the device-level "running somewhere" flag (that is also true
while music plays on a headset). It is a read-only query: no stream, tap or
aggregate device. No entitlement or usage string was added. If the App Store build
never prompts while Direct does, report it (the reading is then `nil`; step 9).

Setup: Settings → Recording → Meeting detection → turn ON "Offer to record when a
call starts" (default list: Zoom, Teams, FaceTime, Webex, Slack, Discord). Allow
notifications for Distavo. Do not launch a second Distavo build while your real
one runs (shared config).

1. **Off by default** — fresh config (or delete the `meeting_detection` block):
   toggle is OFF; start a Zoom/FaceTime call: no prompt, ever. With it off, Activity
   Monitor shows no extra wake-ups from Distavo (the timer exists only while on).
2. **Prompt within 5 s** — ON; join/start a Zoom call (or FaceTime call to
   yourself/another device) with the mic live. A notification "Zoom is using the
   microphone — Record this call?" with **Record** and **Not now** buttons appears
   within 5 s of the mic going live (debounce is 2 s) and names the app that is
   actually capturing, even with other listed apps (Slack, Discord) open in the
   background. Repeat for FaceTime and Teams if installed; note which bundle id
   (see the log line "Meeting offer: … (<id>)") fired, especially for Teams/Zoom
   helpers.
3. **Record** — click Record: the normal pre-flight/permission flow (first time) then
   the menu shows "Stop recording"; the recording works exactly as via the menu.
   Nothing was recorded before the click (no purple indicator beforehand).
4. **One prompt per call** — stay on the call for 2 min: no second prompt. Hang up,
   start a new call: prompted again.
5. **Not now** — end the call, start another, click Not now: no prompt for that app
   for the snooze time (default 30 min; check a short value like 1 min and that the
   next call after it expires prompts again). Other listed apps still prompt.
6. **No prompt while recording** — start Record from the menu BEFORE the call
   starts, then join: no prompt. Stop the recording mid-call: no prompt for the same
   call and none for 30 s afterwards.
7. **Notifications denied** (System Settings → Notifications → Distavo off): on a
   call, open the menu-bar menu: "📞 Zoom is using the microphone" with **Record this
   call** / **Not now** is shown instead. It disappears when the app stops capturing,
   when a recording starts by any route, and when the feature is switched off.
8. **Non-listed / idle / headset music** — a non-listed app capturing the mic (voice
   memo, dictation) while Zoom/Slack/Discord are merely open: no prompt. Listed app
   open, no call: no prompt. **Play music through a Bluetooth/USB headset with Slack
   or Discord open: no prompt.** A call in app X while Keynote is frontmost: the offer
   names X, and Not now snoozes X only.
9. **Sandbox diagnosis (App Store build)** — if step 2 fails only in the sandboxed
   build, check `~/Library/Logs/Distavo/distavo.log` ("Meeting detection on", and on
   a call "Meeting offer: …"). Run `log stream --predicate 'process == "Distavo"'`
   during a call to see sandbox denials, and note whether any TCC prompt appeared
   (none is expected; if one does, stop and report). Report whether the process list
   or the per-process flags fail. With the reading `nil`, only the optional frontmost
   fallback (`meeting_detection.allow_frontmost_fallback`, no UI, default false)
   remains; it says "A call may be in progress" and names no app.
10. **Record start-only** — click Record while the pre-flight dialog is still open
    from an earlier click: it never turns into a stop.
11. **Browser caveat** — add your browser's id (`com.google.Chrome`, …) and open
    meet.google.com with the mic on. Chrome and other Chromium/Electron apps often
    capture from a helper process (e.g. `com.google.Chrome.helper`); helpers match
    their listed app by dotted prefix, but whether the Core Audio process object
    reports the helper's or the parent's id is unconfirmed - check the log line.
    Any other mic use in that browser (a voice message) also prompts (documented).
    Remove it again afterwards.
12. **Sleep/wake** — enable, sleep the Mac with a call app open, wake mid-call: no
    prompt storm; a call that is still live prompts once after about 2 s.

Unconfirmed without a real call: that Zoom/Teams/FaceTime/Slack/Discord capture under
their listed bundle id (or a dot-prefixed helper); that the per-process API works with
no prompt in the sandbox. Webex `com.cisco.webexmeetingsapp` is unverified; Webex's
main app is `Cisco-Systems.Spark`.

## Known caveats (documented, not bugs)

- Loudspeakers (no headphones): the mic also hears the remote participants, so
  their words can appear twice in the transcript. The pre-flight says this.
- Bluetooth headsets drop to call quality (HFP) during meetings — capture
  works, fidelity is lower.
- Apps using exclusive-mode (hog) audio can't be tapped (rare pro-audio tools;
  not the mainstream meeting apps).
- Pre-14.4: the menu item is hidden; users can still record with any external
  tool (QuickTime, or BlackHole for DIYers) into the watched folder.
