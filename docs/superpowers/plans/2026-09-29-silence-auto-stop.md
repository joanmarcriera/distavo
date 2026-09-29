# Silence auto-stop for the built-in recorder (Vikunja #2665)

## 1. Semantics
- **One sample per second.** On each 1 Hz `tickElapsed`, take the mean RMS of each output channel over the last second (L = mic, R = system audio, measured before loudness balancing).
- **A silent second**: both channels below `thresholdRMS` = 0.003 (~ -50 dBFS), the same value as `StereoBalancer.noiseGate`. A noisy room may never fall below it, which errs the safe way (never stops a live meeting).
- **Any loud second resets the timer** and ends the silence episode.
- **One side only has signal**: mic muted (L=0) while R>0 is not silent; system audio denied (R=0) => the mic alone decides. A second with no frames at all (device stalled) counts as silent.
- **Pause**: the recorder has no pause today (`isPaused` is the folder watcher's). If one is added, call `monitor.reset(at:)` on resume.
- **The two options are independent** (own toggle, own minutes 1-60). Suggest at N min: one notice per episode, never stops. Auto-stop at M min: stops with or without an earlier suggestion. If M <= N the auto-stop wins and no suggestion is sent; Settings shows a caption but does not block Save.
- **"Keep recording"** cancels suggestion + auto-stop for the current episode only; the next sound starts a new episode. Ignoring the notification is NOT "Keep recording".
- **Arming rule**: auto-stop only fires after at least one loud second was heard in this recording (a silent lobby is never auto-stopped). The suggestion is not subject to it.

## 2. Config (flat keys, like `ask_speakers_on_stop`)
| key | type | default |
|---|---|---|
| `suggest_stop_on_silence` | Bool | false |
| `suggest_stop_silence_minutes` | Int | 2 |
| `auto_stop_on_silence` | Bool | false |
| `auto_stop_silence_minutes` | Int | 5 |

Missing key => default (both OFF for old configs and fresh installs; `recommendedForThisMac` does not set them - "if selected"). 2 and 5 are pre-filled minutes, not enabled-by-default: an unwanted stop loses audio irrecoverably. Minutes clamp to 1...60; a wrong type falls back to the default via `try? decodeIfPresent`.

## 3. Architecture
New pure `DistavoCore/SilenceMonitor.swift` (time injected as monotonic `TimeInterval`):

    public struct SilencePolicy: Equatable, Sendable { suggestAfter: TimeInterval?; autoStopAfter: TimeInterval?; thresholdRMS: Float = StereoBalancer.noiseGate; maxSampleGap: TimeInterval = 5; init(config: Config) }
    public enum SilenceEvent: Equatable { case none, suggestStop(silentFor: TimeInterval), autoStop(silentFor: TimeInterval) }
    public struct SilenceMonitor { init(policy:now:); var policy; private(set) silentFor; private(set) suggestionActive
        mutating func ingest(mic: Float, system: Float, at now: TimeInterval) -> SilenceEvent
        mutating func keepRecording(); mutating func reset(at:) }

Each call adds `clamp(now-last, 0, maxSampleGap)` when silent; resets on sound; NaN/inf = sound; after `.autoStop` returns `.none` until reset.
- **Feeding**: in `MeetingRecorder.writeMixed` (recorder queue) after mixdown, `vDSP_svesq` on the two output channels into `micSumSq`/`tapSumSq` + `levelFrames`; `drainLevels() -> (mic, system)` via `queue.sync` (same pattern as `systemAudioHeardSoFar`), returns RMS and resets. No allocations/locks in the callback.
- **Driving**: `MeetingCaptureController.start()` creates the monitor (clock `ProcessInfo.systemUptime`); `tickElapsed()` refreshes `monitor.policy` from `configProvider()` (Settings apply live), drains, ingests, handles the event. `.autoStop` calls the same `stop()` the menu uses, refactored to `stop(reason: .manual | .silence(minutes:))`; the WAV is finalised exactly as a manual Stop (.part held -> speakers + language question -> finalizeDeferred -> StereoBalancer -> rename -> pipeline -> when-done actions). Differences: log line, notification title, one extra sentence in the speakers dialog, and `openPrivacyPane()` skipped.

## 4. Suggestion UX
- **Notification**: `Notifier` gains category `distavo.silence` with actions "Stop recording" / "Keep recording" and becomes the `UNUserNotificationCenterDelegate` (set in `WatcherController.start()`, `willPresent` -> `.banner`, `didReceive` forwarded on the main actor to `capture.stopFromSilence()` / `capture.keepRecording()`, no-ops if already stopped). Fixed identifier `distavo.silence` (never stacks); removed on sound, Keep, or any stop.
- **Menu bar** (always, and the fallback when notifications are denied): `@Published silenceNotice` turns Stop into "Stop recording (12:34 · silent 2 min)", adds "Keep recording", icon `IconState.recordingSilent` (orange). Cleared on sound / Keep.
- **After auto-stop**: "Recording stopped after 5 min of silence" / "<file> saved - Distavo will transcribe it shortly." Existing no-system-audio / silent-mic warnings keep priority.

## 5. Settings (Recordings section, inside `if MeetingCaptureController.isSupported`, below "Ask who was in the meeting")
- `Toggle("Suggest stopping after silence")` + `Stepper("\(n) min", 1...60)` (disabled when off) + help text.
- `Toggle("Stop recording automatically after silence")` + Stepper + help text.
- Caption when both on and M <= N: "This stops the recording before the suggestion would appear."

## 6. Tests
`SilenceMonitorTests` (1 Hz fake clock): (1) both off -> `.none` for 3600 s; (2) suggest 2 min: none at 119 s, suggest at 120 s, then none; (3) loud sample at 90 s delays to 210 s; (4) new episode re-suggests; (5) auto 5 min fires at 300 s, no suggestion; (6) both 2/5: suggest at 120, auto at 300, once each; (7) `keepRecording()` at 130 s: no auto-stop that episode, new silence fires again; (8) M=N=3: autoStop at 180, no suggestion; (9) threshold strictly `<` (either channel above = sound; both exactly 0.003 = sound); (10) one channel zero + other speech = never silent; (11) time gap 0->600 s => silentFor <= 5, no auto-stop; (12) not armed: 10 min silence suggests but no auto-stop; after one loud sample, 300 s -> autoStop; (13) backwards time = delta 0; NaN/inf = sound; (14) enabling suggest via `policy` at silentFor=150 -> suggest next sample; (15) after autoStop always `.none` until reset.
`ConfigMigrationTests`: golden configs -> both off, 2 and 5; round-trip; 0/-3/999 clamp to 1/1/60; string `"5"` -> default/5 and rest decodes; `recommendedForThisMac()` leaves both off.
Manual (recorder can't run in CI): add checks to `docs/meeting-capture-verification.md` - notification actions, menu fallback with notifications denied, sound clears notice, auto-stop reaches speakers dialog, WAV finalised.

## 7. Risks
Real quiet spells (off by default, arming rule, Keep recording, up to 60 min). Bluetooth/AirPods route change: mic zero while system audio continues is not silent; a full device death -> both silent -> auto-stop saves what exists. Noisy rooms never trip it (safe direction; threshold is a policy field). Modal blocking main thread: gap clamp. Trailing silence reaching Whisper can hallucinate - follow-up: trim trailing silence at finalise. App Store/Setapp: notification actions + delegate are sandbox-safe, no `#if EDITION_*`, no new entitlement.
