# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **Note:** this file was not maintained after 1.1.0. For 1.2.0 onwards (current: 1.20.0)
> see the per-release notes on [GitHub Releases](https://github.com/joanmarcriera/distavo/releases)
> and the App Store "What's New" text in `apple/metadata/whats-new/en-GB.txt`.

## [Unreleased]

## [1.1.0] - 2026-06-29

### Changed

- Renamed the product from **Seshat** to **Distavo** (coined from *distil*). The exact name
  "Seshat" was already taken as an app name on the Mac App Store; "Distavo" is a distinctive,
  cleared coinage. Bundle IDs are now `uk.co.riera.distavo` / `uk.co.riera.distavo-setapp`,
  and the core package is `DistavoCore`. See `docs/trademark-assessment.md`.
- Hardened the App Store upload workflow so CI imports both signing certificates,
  verifies installer signing access before export, validates the export plist,
  pins the application and installer signing identities, checks the exported
  package signature, and caps signing/export/upload steps with timeouts.

## [1.0.0] - 2026-06-26

### Added

- Native **Swift/SwiftUI** rewrite shipping in three editions from one codebase —
  **Direct download, Setapp, and the Mac App Store** (`apple/`).
- UI-free `DistavoCore` package (config, state, transcript cleaning, validation,
  prompt, WhisperX/Ollama clients, AVFoundation audio conversion, pipeline) with
  a headless `swift test` suite.
- **"Report an Issue…"** menu item that opens a pre-filled GitHub issue with
  non-sensitive diagnostics (version, edition, macOS, hardware).
- Release automation: tag-triggered Developer ID notarized DMG → GitHub Release,
  and App Store Connect upload (`.github/workflows/release*.yml`).

### Changed

- Renamed the product to **Seshat** (from the original *Scribed*).
- Audio conversion uses **AVFoundation** instead of `ffmpeg` (no GPL dependency,
  which is what makes App Store distribution possible).
- Native Settings window replaces the localhost settings web page.

### Removed

- The original Python implementation (kept in git history as the behavioural spec).

## [0.1.0] - 2026-06-24

### Added

- Initial release: a macOS menu-bar app that watches a folder for new audio/video
  recordings.
- Automatic pipeline: local conversion to WAV → transcription on a
  user-configured **WhisperX** server → summarisation with a user-configured
  **Ollama** model → validation → Markdown note written to the notes folder.
- Settings page for configuring servers, folders, and the watch interval, with a
  **Test connection** button.
- Menu actions: Process now, Copy last transcript, Open last note, Watch
  interval, Use local Ollama, open folders, Settings…, Pause/Resume, Quit.
- Headless CLI to process all pending recordings once.

[Unreleased]: https://github.com/joanmarcriera/distavo/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/joanmarcriera/distavo/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/joanmarcriera/distavo/compare/v0.1.0...v1.0.0
[0.1.0]: https://github.com/joanmarcriera/distavo/releases/tag/v0.1.0
