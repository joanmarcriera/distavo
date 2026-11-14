# Contributing to Distavo

Thanks for your interest in improving Distavo! This guide covers how to set up,
test, and submit changes. By participating you agree to follow our
[Code of Conduct](CODE_OF_CONDUCT.md).

## Prerequisites

- macOS 14+ (the `deploymentTarget` in `apple/project.yml`) with a recent Xcode / Swift toolchain
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Setup

```sh
cd apple && xcodegen generate
```

`Distavo.xcodeproj` is generated from `apple/project.yml` and is gitignored —
re-run `xcodegen generate` whenever you add or remove a `.swift` file.

## Running the tests

```sh
cd apple/DistavoCore && swift test
```

The core pipeline is covered by unit tests in `apple/DistavoCore/Tests/` (no
Xcode host or servers required). Please keep them green.

### Test-driven development

We expect a **TDD** workflow: write or update a failing test that captures the
behaviour you want, then implement the change until it passes. New features and
bug fixes should come with tests. The `DistavoCore` package is deliberately
UI-free so it can be tested without launching the app.

## Coding conventions

- **Small, focused modules.** Keep each file doing one thing.
- **Keep `DistavoCore` UI-free and testable.** No SwiftUI/AppKit imports in the
  core package — only the `apple/Sources/Distavo/` app target touches the UI.
- **Main-thread UI.** All menu/AppKit mutation must happen on the main thread;
  background work (scanning, processing) runs off the main actor and hands
  results back without mutating UI off-thread.
- Prefer pure functions for logic so they can be unit-tested directly (see how
  the pipeline takes its effects via `PipelineDeps`, and how `TranscriptCleaner`
  and `SummaryValidator` are pure and tested without servers).

## Running the app locally

```sh
cd apple
xcodegen generate
xcodebuild -project Distavo.xcodeproj -scheme Distavo -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
# then open apple/build/Build/Products/Debug/Distavo.app
```

On first run, open **Settings…** from the menu bar to configure your WhisperX
and Ollama endpoints.

## Pull request process

1. Fork and create a feature branch.
2. Make your change with accompanying tests (TDD).
3. Ensure `cd apple/DistavoCore && swift test` passes and the app builds
   (`xcodegen generate` + `xcodebuild`).
4. Update docs (`README.md`, etc.) if behaviour changed.
5. **Do not commit any private data** — no recordings, notes, transcripts,
   real server IPs, or tokens (see `.gitignore`).
6. Open a PR using the template; fill in the checklist.

We review for correctness, test coverage, and that the core stays UI-free and
main-thread-safe.
