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
# NetworkScope, AudioConverter, StereoBalancer, WhisperLanguageCatalog, IssueReport,
# EmbeddedSummary).

# Slower — builds WhisperKit/SpeakerKit (argmax-oss-swift) on first run.
cd apple/DistavoEmbedded && swift test

# Gated live tests (real servers/model download) — skipped by default:
DISTAVO_LIVE=1 WHISPERX_URL=... OLLAMA_URL=... OLLAMA_MODEL=... \
  DISTAVO_LIVE_AUDIO=/abs/path.m4a swift test --filter LiveE2ETests   # in DistavoCore
DISTAVO_EMBEDDED_LIVE=1 DISTAVO_EMBEDDED_LIVE_AUDIO=/abs/path.wav \
  swift test --filter EmbeddedLiveTests                               # in DistavoEmbedded, ~460MB model
# On-device summarisation (needs Apple Intelligence on; ~30s, no download):
DISTAVO_SUMMARY_LIVE=1 swift test --filter EmbeddedSummariserTests    # in DistavoEmbedded

# Per-edition unsigned build. Use the REAL scheme per edition and a SEPARATE
# derivedDataPath each — each target already maps Debug to its own xcconfig, so
# no -xcconfig flag is needed, and separate paths let you diff the products.
cd apple
for sch in Distavo Distavo-AppStore Distavo-Setapp; do
  xcodebuild -project Distavo.xcodeproj -scheme $sch -configuration Debug \
    -derivedDataPath "build-$sch" CODE_SIGNING_ALLOWED=NO build
done   # build-*/ is gitignored
```

## Proving an edition gate actually excluded something

Compiling is not evidence a `#if` worked. Inspect the built product:

```sh
for sch in Distavo Distavo-AppStore Distavo-Setapp; do
  DY="build-$sch/Build/Products/Debug/Distavo.app/Contents/MacOS/Distavo.debug.dylib"
  printf '%-18s ' "$sch"
  printf 'Sparkle:%s ' "$([ -d "build-$sch/Build/Products/Debug/Distavo.app/Contents/Frameworks/Sparkle.framework" ] && echo YES || echo no)"
  printf 'Donate:%s\n'  "$(strings -a "$DY" | grep -qF 'Support Distavo' && echo YES || echo no)"
done
```

**Gotcha — strings the app binary and you'll find nothing.** Xcode 16+ Debug builds put the
actual code in `Contents/MacOS/Distavo.debug.dylib`; `Contents/MacOS/Distavo` is a ~40 KB
launcher. Grepping the launcher makes every gate look "absent", including ones that are
present — check the `.debug.dylib` (or build Release).

**Gotcha — URL constants are NOT gated, only the UI is.** `Links.donateURLString` and
`Links.feedbackURLString` are plain `static let`s, so the strings appear in every edition's
binary as unreachable dead data. That is fine and already shipped: the App-Store-reviewed 1.9.1
binary contains the Lemon Squeezy URL. Assert on the **menu label** ("Support Distavo",
"Send Feedback"), not the URL.

**Gotcha — CI never fires automatically.** `.github/workflows/ci.yml` is `workflow_dispatch` only
(dev moved to Forgejo `git.riera.co.uk`; GitHub is a push-mirror, so push/PR triggers were removed
to stop burning Actions minutes on every mirror sync). Run the three loops above yourself, or
dispatch `ci.yml` manually — don't assume a green mirror push means it ran.

**Gotcha — CI's edition loop reuses one scheme.** `ci.yml` always builds `-scheme Distavo` and only
swaps `-xcconfig configs/$edition.xcconfig`; it does **not** archive the separate `Distavo-AppStore`
/ `Distavo-Setapp` schemes/targets. That's enough to catch `#if EDITION_*` compile breakage but not
target-specific settings (e.g. Setapp's hand-authored `Setapp-Info.plist`, `GENERATE_INFOPLIST_FILE:
NO`) — exercise those schemes directly before a release if you touched target-level settings.

## Environment gotchas that waste a build

- **Stale module cache after the repo moved.** The repo used to live at `/Users/marc/Distavo`.
  A `.build` carried over from then fails every target with `missing required module
  'SwiftShims'` and a "compiled with module cache path …" error. Fix:
  `rm -rf apple/DistavoCore/.build apple/DistavoEmbedded/.build`. Nothing to do with your change.
- **`xcodebuild` rewrites `apple/DistavoEmbedded/Package.resolved`.** Building the Xcode project
  injects the app's `Sparkle` pin into the *embedded package's* lockfile and downgrades its
  format (`"version": 3` → `2`). DistavoEmbedded does not depend on Sparkle — this is pollution,
  not a real change. `git checkout -- apple/DistavoEmbedded/Package.resolved` before committing.

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

- `DistavoCore` stays dependency-free (no `import DistavoEmbedded`, no `import FoundationModels`,
  no app-target types) — that's what keeps `swift test` fast/headless. On-device summarisation
  follows the transcriber's split: pure budgeting/chunking logic in `DistavoCore/EmbeddedSummary.swift`,
  the FoundationModels engine in `DistavoEmbedded/EmbeddedSummariser.swift`.
- **On-device summarisation is opt-in** via `summarise.embedded_enabled` (default false) and is
  gated `#if canImport(FoundationModels)` + `@available(macOS 26, *)` — the deployment target is
  still macOS 14. The flag is a kill switch: with it off, `backend == "embedded"` must fall back
  to Ollama, not fail. See `docs/embedded-summarisation-decision.md`.
- **Only the Ollama path may produce `deferredNeedLocal`.** `Pipeline.chooseSummariser` returns
  `.embedded` immediately (no network, so nothing to defer on). Don't let a refactor turn a
  deferral into a failure — `PipelineTests` covers all four selection cases.
- `PipelineDeps` (in `Pipeline.swift`) is the dependency-injection seam all tests use to avoid real
  servers — don't bypass it when editing the pipeline.
- No linter is configured in this repo.
- Version numbers live in `apple/project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`) —
  never in an Info.plist directly.
