# Scope and verification status: #2945 meeting detection, #2951 transcript viewer

Written by the 2026-10-25 drive. Both features are already on `main` (shipped in 1.17); nothing is left to build.

| Task | Code | Tests | Left open because |
|---|---|---|---|
| #2945 auto-detect meeting, offer to record | `DistavoCore/MeetingDetector.swift`, `apple/Sources/Distavo/Capture/MeetingDetectionController.swift`; config section `meeting_detection`, off by default | `MeetingDetectorTests`, `MeetingDetectorBrowserTests`, `MeetingDetectionConfigTests` | Prompt within 5 s of a real call, and App Store sandbox behaviour, need a signed build and a person on a call |
| #2951 audio-synced transcript viewer | `DistavoCore/TranscriptTimeline.swift`, `apple/Sources/Distavo/Capture/TranscriptViewer*.swift`, `TranscriptTextView.swift` | `TranscriptTimelineTests`, `TranscriptEditStore*`, `TranscriptRobustnessTests`, `TranscriptRevertRenameTests` | Click-to-seek within 0.3 s and the highlight cadence need a launched app with real audio |

Headless run on this branch (2026-10-25): `swift test --filter 'MeetingDetect|TranscriptTimeline|TranscriptEdit|TranscriptRobust|TranscriptRevert'` ran 65 tests, 0 failures.

Manual checks (human, signed build): see `docs/manual-checks-1.17.md`, section "Transcript viewer (Vikunja #2951)" and the meeting-detection items.
Marc's remaining step after 1.20.0 clears review: run those checklists on the signed Direct build, then close both tasks.
