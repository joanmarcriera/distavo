---
name: distavo-native-verify
description: Use whenever building, testing, or verifying Distavo (native Swift/SwiftUI macOS menu-bar app) after touching apple/DistavoCore, apple/DistavoEmbedded, or apple/Sources/Distavo — adding/removing a .swift file, running swift test, doing a per-edition xcodebuild, or checking the Direct/Setapp/App Store compliance gates (Sparkle, donate link, sandbox-prohibited automation) before a commit or release. Trigger phrases: "run the tests", "build Distavo", "xcodegen generate", "does this compile for all editions", "check the compliance gates", "verify the App Store build has no Sparkle".
---

# Distavo native verify

Distavo is ONE codebase, THREE editions (Direct / Setapp / App Store), selected at build time by
`apple/configs/{Direct,Setapp,AppStore}.xcconfig` via `SWIFT_ACTIVE_COMPILATION_CONDITIONS`. Verify
both "does it compile" and "does the right edition exclude the right code."

## Commands

```sh
# REQUIRED after adding/removing ANY .swift file — Distavo.xcodeproj is generated
# + gitignored; sources are referenced explicitly in apple/project.yml.
cd apple && xcodegen generate

# Fast, headless, dependency-free — this is the CI seam. Run this first on any
# Pipeline/Config/State/Cleaner/Validator change.
cd apple/DistavoCore && swift test
cd apple/DistavoCore && swift test --filter PipelineTests   # one suite
# Suite files: apple/DistavoCore/Tests/DistavoCoreTests/*.swift (Pipeline, State,
# Config, Cleaning, Validation, Prompt, WhisperXClient, OllamaClient, ActivityLog,
# NetworkScope, AudioConverter, StereoBalancer, WhisperLanguageCatalog, IssueReport).

# Slower — builds WhisperKit/SpeakerKit (argmax-oss-swift) on first run.
cd apple/DistavoEmbedded && swift test

# Gated live tests (real servers/model download) — skipped by default:
DISTAVO_LIVE=1 WHISPERX_URL=... OLLAMA_URL=... OLLAMA_MODEL=... \
  DISTAVO_LIVE_AUDIO=/abs/path.m4a swift test --filter LiveE2ETests   # in DistavoCore
DISTAVO_EMBEDDED_LIVE=1 DISTAVO_EMBEDDED_LIVE_AUDIO=/abs/path.wav \
  swift test --filter EmbeddedLiveTests                               # in DistavoEmbedded, ~460MB model

# Per-edition unsigned build — same scheme, different xcconfig overrides the #if flags:
cd apple
xcodebuild -project Distavo.xcodeproj -scheme Distavo -configuration Debug \
  -xcconfig configs/Direct.xcconfig   CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Distavo.xcodeproj -scheme Distavo -configuration Debug \
  -xcconfig configs/Setapp.xcconfig   CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Distavo.xcodeproj -scheme Distavo -configuration Debug \
  -xcconfig configs/AppStore.xcconfig CODE_SIGNING_ALLOWED=NO build
```

**Gotcha — CI never fires automatically.** `.github/workflows/ci.yml` is `workflow_dispatch` only
(dev moved to Forgejo `git.riera.co.uk`; GitHub is a push-mirror, so push/PR triggers were removed
to stop burning Actions minutes on every mirror sync). Run the three loops above yourself, or
dispatch `ci.yml` manually — don't assume a green mirror push means it ran.

**Gotcha — CI's edition loop reuses one scheme.** `ci.yml` always builds `-scheme Distavo` and only
swaps `-xcconfig configs/$edition.xcconfig`; it does **not** archive the separate `Distavo-AppStore`
/ `Distavo-Setapp` schemes/targets. That's enough to catch `#if EDITION_*` compile breakage but not
target-specific settings (e.g. Setapp's hand-authored `Setapp-Info.plist`, `GENERATE_INFOPLIST_FILE:
NO`) — exercise those schemes directly before a release if you touched target-level settings.

## Scheme / target / bundle-ID map (from `apple/project.yml`)

| Edition | Scheme/target | Config | Bundle ID | Sparkle |
|---|---|---|---|---|
| Direct | `Distavo` | Release, `configs/Direct.xcconfig` | `uk.co.riera.distavo` | **yes** (only target depending on the `Sparkle` package) |
| App Store | `Distavo-AppStore` | Release-AppStore | `uk.co.riera.distavo` | no |
| Setapp | `Distavo-Setapp` | Release | `uk.co.riera.distavo-setapp` | no |

All three ship as `Distavo.app` (`PRODUCT_NAME` pinned in the shared `DistavoApp` target template) —
don't be surprised the target name differs from the product name.

## Compliance gates to check before any commit/release touching editions

```sh
grep -rn "EDITION_APPSTORE\|EDITION_DIRECT\|EDITION_SETAPP\|DONATE_ENABLED\|import Sparkle" \
  apple/Sources/Distavo/
```

- **No Sparkle outside Direct**: `apple/Sources/Distavo/Core/SparkleUpdater.swift` is wrapped in
  `#if EDITION_DIRECT` around the `import Sparkle`; the `Sparkle` SwiftPM package in `project.yml`
  is only listed as a dependency of the `Distavo` target. Never add it to `DistavoApp`'s shared
  template deps.
- **No external-payment/donate link outside Direct**: the "Support Distavo…" menu item
  (`Menu/StatusMenu.swift:90`) is `#if DONATE_ENABLED`, set only in `Direct.xcconfig`.
  `AppStore.xcconfig` documents why in a comment (Guideline 3.1.1 — no steering to outside payment);
  Setapp excludes it by its own store rules.
- **No sandbox-prohibited automation in App Store**: the "Run in Terminal" helper
  (`Settings/SettingsHelp.swift`) is `#if !EDITION_APPSTORE`.
- **Flags must be absolute, not `$(inherited)`**: `Direct.xcconfig` sets
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS` without `$(inherited)` on purpose — it's the target's base
  config, so a command-line `-xcconfig configs/{Setapp,AppStore}.xcconfig` override must fully
  *replace* it. Adding `$(inherited)` anywhere would leak `EDITION_DIRECT DONATE_ENABLED` into the
  other editions.

## Other things to preserve

- `DistavoCore` stays dependency-free (no `import DistavoEmbedded` or app-target types) — that's
  what keeps `swift test` fast/headless.
- `PipelineDeps` (in `Pipeline.swift`) is the dependency-injection seam all tests use to avoid real
  servers — don't bypass it when editing the pipeline.
- No linter is configured in this repo.
- Version numbers live in `apple/project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`) —
  never in an Info.plist directly.
