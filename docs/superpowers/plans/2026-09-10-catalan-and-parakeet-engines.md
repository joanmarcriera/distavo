# Catalan models and Parakeet engines — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Distavo 1.11 with BSC's Catalan / Languages-of-Spain Whisper models and NVIDIA Parakeet as built-in engines, automatic language routing, and a transcription deferral contract, all on-device and telemetry-free.

**Architecture:** DistavoCore (dependency-free) gains the engine catalog, a pure router, a pure word–speaker aligner and a retryable-error type through the existing `PipelineDeps` seam. DistavoEmbedded gains a Parakeet transcriber (FluidAudio), a whisper-tiny language detector and a model-download coordinator actor. The app target routes in `AppPipelineDeps` and exposes the new choices in Settings. Custom Whisper models are converted once with Argmax's tool and served from Marc's Hugging Face repo.

**Tech Stack:** Swift 5 language mode, SwiftPM tools 6.2 for DistavoEmbedded, WhisperKit + SpeakerKit (argmax-oss-swift 1.0.0), FluidAudio pinned by revision, XCTest, xcodegen, whisperkittools (Python 3.11 via uv).

**Spec:** `docs/superpowers/specs/2026-09-10-catalan-and-parakeet-engines-design.md` (v2) — read it first; the Codex review beside it explains every non-obvious rule.

## Global Constraints

- macOS deployment floor stays **14** for DistavoCore and DistavoEmbedded (`platforms: [.macOS(.v14)]`).
- DistavoEmbedded manifest: **`// swift-tools-version: 6.2`** with `swiftLanguageModes: [.v5]` on every target. DistavoCore stays at 5.9 and dependency-free (no imports beyond Foundation).
- FluidAudio pin: **revision `41540ea237350afe5117a082b5c28eda642d0612`**, added with **`traits: []`**. No `NemoTextProcessing.xcframework` may appear in any built product.
- Custom model repo: **`Joanmarcriera/distavo-whisperkit-coreml`**; folder names **`BSC-LT_whisper-large-v3-LoS`** and **`BSC-LT_whisper-large-v3-ca-punctuated-3370h`**.
- Catalog ids: `large-v3-turbo`, `small`, `parakeet-tdt-v3`, `bsc-los`, `bsc-ca-3370h`; literal `"auto"` for model and language; `preferred_catalan_model` default `"bsc-los"`.
- **Only** `Config.recommendedForThisMac()` may produce `"auto"`. Existing files keep historical defaults.
- Never pass `"auto"` to WhisperKit or FluidAudio. Router hints are real codes or `nil`.
- Retryable conditions throw `RetryableDependencyError`; the pipeline must never write `.failed` for them.
- BSC models: `minimumMemoryGB = 16` until measured (spec §6).
- Every `.swift` file added or removed → `cd apple && xcodegen generate` before building the app.
- **Never commit `apple/DistavoEmbedded/Package.resolved` changes made by a local `swift build`** except in Task 6 where the pin is intentional (see the `distavo-native-verify` skill).
- Commits: Conventional Commits, trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_013hYkCTQqKtjweeqo6vzMtk`.
- Run `cd apple/DistavoCore && swift test` after every DistavoCore task; `cd apple/DistavoEmbedded && swift build` after every DistavoEmbedded task.
- Never print `HF_TOKEN`; load it with `eval "$(grep '^export HF_TOKEN=' ~/.tokens)"`.

## File map

| File | Responsibility |
|---|---|
| `apple/DistavoCore/Sources/DistavoCore/Pipeline.swift` | `RetryableDependencyError`, `ProcessStatus.deferred`, catch branch |
| `apple/DistavoCore/Sources/DistavoCore/EmbeddedSupport.swift` | catalog with engine/repo/languages/memory |
| `apple/DistavoCore/Sources/DistavoCore/Config.swift` | `preferredCatalanModel`, auto defaults for fresh installs |
| `apple/DistavoCore/Sources/DistavoCore/EngineRouter.swift` (new) | pure routing rules |
| `apple/DistavoCore/Sources/DistavoCore/WordSpeakerAligner.swift` (new) | pure word→speaker→WhisperX dict |
| `apple/DistavoEmbedded/Package.swift` | tools 6.2, FluidAudio pin |
| `apple/DistavoEmbedded/Sources/DistavoEmbedded/ModelCoordinator.swift` (new) | download/readiness/exclusion actor |
| `apple/DistavoEmbedded/Sources/DistavoEmbedded/LanguageDetector.swift` (new) | whisper-tiny three-window detection |
| `apple/DistavoEmbedded/Sources/DistavoEmbedded/ParakeetTranscriber.swift` (new) | FluidAudio + SpeakerKit + aligner |
| `apple/DistavoEmbedded/Sources/DistavoEmbedded/EmbeddedTranscriber.swift` | custom repo, retryable mapping, model release before SpeakerKit |
| `apple/Sources/Distavo/Core/AppPipelineDeps.swift` | detect → route → dispatch |
| `apple/Sources/Distavo/Core/WatcherController.swift` | `.deferred` status, coordinator progress |
| `apple/Sources/Distavo/Settings/SettingsView.swift` | grouped picker, Automatic, Download now |
| `tools/whisperkit-models/` (new) | conversion + manifest |
| `NOTICES.md`, `apple/metadata/whats-new/en-GB.txt`, `apple/project.yml` | credits, release |

---

### Task 1: Retryable transcription errors defer instead of failing

**Files:**
- Modify: `apple/DistavoCore/Sources/DistavoCore/Pipeline.swift:3-8` (enum) and `:241-246` (catch)
- Test: `apple/DistavoCore/Tests/DistavoCoreTests/PipelineTests.swift`

**Interfaces:**
- Produces: `public struct RetryableDependencyError: Error, Equatable { public let message: String; public init(_ message: String) }`, `ProcessStatus.deferred = "deferred"`.

- [ ] **Step 1: Write the failing test** (append inside `PipelineTests`)

```swift
    /// A model download that fails because the Mac is offline must leave the
    /// recording pending: no `.failed` marker, retried on the next scan.
    func testRetryableTranscribeErrorDefersAndRetriesOnNextScan() async throws {
        let (cfg, input) = try makeEnv()
        final class Counter: @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        }
        let calls = Counter()
        let d = deps(transcribe: { _, _ in
            if calls.next() == 1 { throw RetryableDependencyError("No internet connection") }
            return ["segments": [["speaker": "SPEAKER_00", "text": "hello world"]]]
        })
        let first = try await Pipeline.processOne(path: input, config: cfg, deps: d)
        XCTAssertEqual(first.status, .deferred)
        XCTAssertEqual(first.message, "No internet connection")
        let state = try DistavoState(config: cfg)
        let base = DistavoState.baseFor(input, recordingsDir: cfg.recordingsURL)
        XCTAssertFalse(state.isFailed(base), "retryable errors must not write .failed")
        XCTAssertFalse(state.isProcessing(base), ".processing must be cleared so the next scan retries")

        let second = try await Pipeline.processOne(path: input, config: cfg, deps: d)
        XCTAssertEqual(second.status, .done)
    }
```

Check how existing tests construct `DistavoState` and derive `base` (see `testSuccessWritesNoteAndMarksDone` at `PipelineTests.swift:64`) and copy that exact form if it differs from the two lines above.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd apple/DistavoCore && swift test --filter PipelineTests/testRetryableTranscribeErrorDefersAndRetriesOnNextScan`
Expected: compile error `cannot find 'RetryableDependencyError' in scope`.

- [ ] **Step 3: Implement**

In `Pipeline.swift`, replace the status enum:

```swift
public enum ProcessStatus: String, Equatable {
    case done
    case skipped
    case deferredNeedLocal = "deferred_need_local"
    /// A dependency was temporarily unavailable (offline model download,
    /// interrupted download, busy model folder). The recording stays pending
    /// and is retried on the next scan — never marked failed.
    case deferred
    case failed
}

/// Thrown by any `PipelineDeps.transcribe` implementation for a condition that
/// resolves on its own (no internet for a one-time model download, a download
/// interrupted mid-way, a model folder busy with removal). `Pipeline.processOne`
/// clears the `.processing` marker and returns `.deferred` instead of writing a
/// permanent `.failed` marker, which `iterPending` would skip forever.
public struct RetryableDependencyError: Error, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
```

Replace the catch block at the end of `processOne`:

```swift
        } catch let retry as RetryableDependencyError {
            state.clearProcessing(base)
            return ProcessResult(status: .deferred, base: base, message: retry.message)
        } catch {
            let message = cleanMessage(error)
            state.markFailed(base, message)
            let np = FileManager.default.fileExists(atPath: notePath.path) ? notePath : nil
            return ProcessResult(status: .failed, base: base, message: message, notePath: np)
        }
```

Search `Pipeline.swift` and `Scanner` for `switch result.status` / exhaustive switches and add `case .deferred:` wherever the compiler demands (treat like `.deferredNeedLocal`).

- [ ] **Step 4: Run the suite**

Run: `cd apple/DistavoCore && swift test`
Expected: all pass, including the new test.

- [ ] **Step 5: Wire the app status.** In `apple/Sources/Distavo/Core/WatcherController.swift:326`, add before `case .failed:`:

```swift
        case .deferred:
            status = "Waiting to retry: \(result.base)"
            log("Deferred — \(result.message): \(result.base)")
```

Build: `cd apple && xcodegen generate && xcodebuild -project Distavo.xcodeproj -scheme Distavo -configuration Debug -derivedDataPath build-Distavo CODE_SIGNING_ALLOWED=NO build | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add apple/DistavoCore/Sources/DistavoCore/Pipeline.swift apple/DistavoCore/Tests/DistavoCoreTests/PipelineTests.swift apple/Sources/Distavo/Core/WatcherController.swift
git commit -m "fix(pipeline): defer, don't fail, when a transcription dependency is temporarily unavailable

Adds RetryableDependencyError through the PipelineDeps seam and a .deferred
status; the catch-all no longer writes .failed for it. Fixes Vikunja #2149."
```

---

### Task 2: Map the embedded transcriber's offline error to the retryable type

**Files:**
- Modify: `apple/DistavoEmbedded/Sources/DistavoEmbedded/EmbeddedTranscriber.swift:95-114`
- Test: `apple/DistavoEmbedded/Tests/DistavoEmbeddedTests/EmbeddedTranscriberErrorTests.swift` (new)

**Interfaces:**
- Consumes: `RetryableDependencyError` (Task 1), `EmbeddedTranscriber.modelError(_:model:)`.
- Produces: `static func pipelineError(_ error: Error, model: String) -> Error` returning `RetryableDependencyError` when offline, else `EmbeddedTranscriberError`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import DistavoCore
@testable import DistavoEmbedded

final class EmbeddedTranscriberErrorTests: XCTestCase {
    func testOfflineDownloadBecomesRetryable() {
        let offline = URLError(.notConnectedToInternet)
        let mapped = EmbeddedTranscriber.pipelineError(offline, model: "Best")
        guard let retry = mapped as? RetryableDependencyError else {
            return XCTFail("expected RetryableDependencyError, got \(mapped)")
        }
        XCTAssertTrue(retry.message.contains("No internet connection"))
    }

    func testOtherLoadFailuresStayPermanent() {
        struct Boom: Error {}
        let mapped = EmbeddedTranscriber.pipelineError(Boom(), model: "Best")
        XCTAssertTrue(mapped is EmbeddedTranscriberError)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd apple/DistavoEmbedded && swift test --filter EmbeddedTranscriberErrorTests`
Expected: `type 'EmbeddedTranscriber' has no member 'pipelineError'`.

- [ ] **Step 3: Implement** — in `EmbeddedTranscriber.swift` add below `modelError`:

```swift
    /// The error the pipeline should see: an offline download is a
    /// `RetryableDependencyError` (the recording stays pending), everything
    /// else keeps the typed, permanent `EmbeddedTranscriberError`.
    static func pipelineError(_ error: Error, model: String) -> Error {
        let typed = modelError(error, model: model)
        if case let .modelUnavailable(_, offline, _) = typed, offline {
            return RetryableDependencyError(typed.errorDescription ?? "No internet connection")
        }
        return typed
    }
```

Then change both `throw Self.modelError(error, model: …)` sites in `transcribe(wavURL:config:)` to `throw Self.pipelineError(error, model: …)`.

- [ ] **Step 4: Run** `cd apple/DistavoEmbedded && swift test --filter EmbeddedTranscriberErrorTests` → PASS. Then `git checkout apple/DistavoEmbedded/Package.resolved` if the build touched it.

- [ ] **Step 5: Commit**

```bash
git add apple/DistavoEmbedded/Sources/DistavoEmbedded/EmbeddedTranscriber.swift apple/DistavoEmbedded/Tests/DistavoEmbeddedTests/EmbeddedTranscriberErrorTests.swift
git commit -m "fix(transcribe): an offline model download now defers the recording instead of failing it"
```

---

### Task 3: Engine catalog with engine, repo, languages and memory floor

**Files:**
- Modify: `apple/DistavoCore/Sources/DistavoCore/EmbeddedSupport.swift`
- Test: `apple/DistavoCore/Tests/DistavoCoreTests/EmbeddedSupportTests.swift`

**Interfaces:**
- Produces:
  - `public enum EmbeddedEngine: String, Sendable { case whisperKit, parakeet }`
  - `public enum LanguageCoverage: Equatable, Sendable { case whisper; case parakeet; case only(Set<String>); public func covers(_ code: String) -> Bool }`
  - `EmbeddedModel` fields: `engine`, `whisperKitRepo: String?`, `languages`, `minimumMemoryGB: Int`; existing fields unchanged. `whisperKitName` is `""` for Parakeet.
  - `EmbeddedModelCatalog.automaticID = "auto"`, `.languageDetectorName = "openai_whisper-tiny"`, `.parakeetLanguages: Set<String>`, `.catalanFamily: Set<String> = ["ca", "gl", "eu"]`, `.languagesOfSpain: Set<String> = ["ca", "es", "gl", "eu"]`, `.isAutomatic(_:)`, `.model(id:)` unchanged semantics, `.selectable(memoryBytes:) -> [EmbeddedModel]`.

- [ ] **Step 1: Write the failing tests** (append to `EmbeddedSupportTests`)

```swift
    func testNewCatalogEntriesExist() {
        XCTAssertEqual(EmbeddedModelCatalog.model(id: "parakeet-tdt-v3").engine, .parakeet)
        XCTAssertEqual(EmbeddedModelCatalog.model(id: "bsc-los").whisperKitRepo,
                       "Joanmarcriera/distavo-whisperkit-coreml")
        XCTAssertEqual(EmbeddedModelCatalog.model(id: "bsc-los").whisperKitName,
                       "BSC-LT_whisper-large-v3-LoS")
        XCTAssertEqual(EmbeddedModelCatalog.model(id: "bsc-ca-3370h").whisperKitName,
                       "BSC-LT_whisper-large-v3-ca-punctuated-3370h")
        XCTAssertNil(EmbeddedModelCatalog.model(id: "large-v3-turbo").whisperKitRepo)
    }

    func testLanguageCoverage() {
        XCTAssertTrue(EmbeddedModelCatalog.model(id: "bsc-los").languages.covers("gl"))
        XCTAssertFalse(EmbeddedModelCatalog.model(id: "bsc-los").languages.covers("en"))
        XCTAssertTrue(EmbeddedModelCatalog.model(id: "parakeet-tdt-v3").languages.covers("de"))
        XCTAssertFalse(EmbeddedModelCatalog.model(id: "parakeet-tdt-v3").languages.covers("ca"))
        XCTAssertTrue(EmbeddedModelCatalog.model(id: "large-v3-turbo").languages.covers("ca"))
    }

    func testMemoryFloorGatesBSCModels() {
        let gb: UInt64 = 1024 * 1024 * 1024
        let on8 = EmbeddedModelCatalog.selectable(memoryBytes: 8 * gb).map(\.id)
        XCTAssertFalse(on8.contains("bsc-los"))
        XCTAssertTrue(on8.contains("parakeet-tdt-v3"))
        let on16 = EmbeddedModelCatalog.selectable(memoryBytes: 16 * gb).map(\.id)
        XCTAssertTrue(on16.contains("bsc-los") && on16.contains("bsc-ca-3370h"))
    }

    func testAutomaticIsNotACatalogModel() {
        XCTAssertTrue(EmbeddedModelCatalog.isAutomatic("auto"))
        XCTAssertEqual(EmbeddedModelCatalog.model(id: "auto").id, EmbeddedModelCatalog.defaultModelID)
    }
```

- [ ] **Step 2: Run** `cd apple/DistavoCore && swift test --filter EmbeddedSupportTests` → compile errors for the missing members.

- [ ] **Step 3: Implement** — replace the `EmbeddedModel` struct and catalog in `EmbeddedSupport.swift`:

```swift
/// Which runtime executes a catalog entry.
public enum EmbeddedEngine: String, Equatable, Sendable {
    case whisperKit   // WhisperKit Core ML (Argmax repo or a custom repo)
    case parakeet     // NVIDIA Parakeet TDT via FluidAudio
}

/// Which spoken languages an entry can transcribe. Used by the router only;
/// a fixed, explicit model choice is always honoured.
public enum LanguageCoverage: Equatable, Sendable {
    case whisper                 // all 99 Whisper languages
    case parakeet                // Parakeet TDT v3's 25 European languages
    case only(Set<String>)       // a fine-tune's languages

    public func covers(_ code: String) -> Bool {
        switch self {
        case .whisper: return WhisperLanguageCatalog.language(forCode: code) != nil
        case .parakeet: return EmbeddedModelCatalog.parakeetLanguages.contains(code)
        case .only(let set): return set.contains(code)
        }
    }
}

/// One selectable on-device transcription model. `id` is what
/// `TranscribeConfig.embeddedModel` stores; `whisperKitName` is the variant
/// folder inside `whisperKitRepo` (or Argmax's `argmaxinc/whisperkit-coreml`
/// when the repo is nil). Parakeet entries have an empty `whisperKitName`.
public struct EmbeddedModel: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let engine: EmbeddedEngine
    public let whisperKitRepo: String?
    public let whisperKitName: String
    public let languages: LanguageCoverage
    public let downloadMB: Int
    public let ramGB: Double
    /// Physical memory below which the model is neither offered nor
    /// auto-routed (spec §6: 16 GB for the fp16 large-v3 fine-tunes until
    /// measured; 0 = no floor).
    public let minimumMemoryGB: Int
    public let detail: String

    public var downloadLabel: String { "\(downloadMB) MB download" }
    public var ramLabel: String {
        ramGB == ramGB.rounded() ? "~\(Int(ramGB)) GB memory while transcribing"
                                 : "~\(ramGB) GB memory while transcribing"
    }
}

public enum EmbeddedModelCatalog {
    public static let defaultModelID = "large-v3-turbo"
    /// Stored in `embedded_model` (and `language`) to mean "let Distavo choose".
    public static let automaticID = "auto"
    /// The variant used only for language detection (77 MB, Argmax repo).
    public static let languageDetectorName = "openai_whisper-tiny"
    public static let customRepo = "Joanmarcriera/distavo-whisperkit-coreml"

    public static let catalanFamily: Set<String> = ["ca", "gl", "eu"]
    public static let languagesOfSpain: Set<String> = ["ca", "es", "gl", "eu"]
    /// NVIDIA Parakeet TDT 0.6B v3's languages (model card, 25 European).
    public static let parakeetLanguages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    public static let models: [EmbeddedModel] = [
        EmbeddedModel(
            id: "large-v3-turbo", displayName: "Best (Whisper large-v3 turbo)",
            engine: .whisperKit, whisperKitRepo: nil,
            whisperKitName: "openai_whisper-large-v3-v20240930_turbo_632MB",
            languages: .whisper, downloadMB: 632, ramGB: 2, minimumMemoryGB: 0,
            detail: "Highest accuracy across 99 languages; recommended for Macs with 16 GB memory or more."),
        EmbeddedModel(
            id: "small", displayName: "Compact (Whisper small)",
            engine: .whisperKit, whisperKitRepo: nil, whisperKitName: "openai_whisper-small",
            languages: .whisper, downloadMB: 463, ramGB: 1, minimumMemoryGB: 0,
            detail: "Lighter and faster; recommended for Macs with 8 GB memory."),
        EmbeddedModel(
            id: "parakeet-tdt-v3", displayName: "Fast (Parakeet, 25 languages)",
            engine: .parakeet, whisperKitRepo: nil, whisperKitName: "",
            languages: .parakeet, downloadMB: 460, ramGB: 1.5, minimumMemoryGB: 0,
            detail: "Transcribes an hour in seconds on the Neural Engine. English, Spanish, French, German and 21 more European languages — not Catalan."),
        EmbeddedModel(
            id: "bsc-los", displayName: "Català · Castellà · Galego · Euskara (BSC Languages of Spain)",
            engine: .whisperKit, whisperKitRepo: customRepo,
            whisperKitName: "BSC-LT_whisper-large-v3-LoS",
            languages: .only(languagesOfSpain), downloadMB: 1600, ramGB: 4, minimumMemoryGB: 16,
            detail: "Whisper large-v3 fine-tuned by the Barcelona Supercomputing Center on 8,110 hours. Best for Catalan, Spanish and mixed meetings."),
        EmbeddedModel(
            id: "bsc-ca-3370h", displayName: "Català (BSC, 3,370 hours)",
            engine: .whisperKit, whisperKitRepo: customRepo,
            whisperKitName: "BSC-LT_whisper-large-v3-ca-punctuated-3370h",
            languages: .only(["ca"]), downloadMB: 1600, ramGB: 4, minimumMemoryGB: 16,
            detail: "Whisper large-v3 fine-tuned by the Barcelona Supercomputing Center on 3,370 hours of Catalan, with punctuation. Catalan-only meetings."),
    ]

    public static func isAutomatic(_ id: String) -> Bool { id == automaticID }

    /// Look up by config id, falling back to the default so an unknown value in
    /// a hand-edited config (or "auto", which is not a model) degrades gracefully.
    public static func model(id: String) -> EmbeddedModel {
        models.first { $0.id == id } ?? models.first { $0.id == defaultModelID }!
    }

    /// Entries this Mac may run (spec §6 memory gate).
    public static func selectable(
        memoryBytes: UInt64 = HardwareProbe.physicalMemoryBytes
    ) -> [EmbeddedModel] {
        let gb = Int(memoryBytes / (1024 * 1024 * 1024))
        return models.filter { $0.minimumMemoryGB <= gb }
    }

    /// Marc's rule: recommend a model the user's Mac can actually run.
    /// ≥ 16 GB physical memory → large-v3-turbo; below that → small.
    public static func recommended(
        memoryBytes: UInt64 = HardwareProbe.physicalMemoryBytes
    ) -> EmbeddedModel {
        let sixteenGB: UInt64 = 16 * 1024 * 1024 * 1024
        return model(id: memoryBytes >= sixteenGB ? "large-v3-turbo" : "small")
    }
}
```

Keep `HardwareProbe` unchanged. Fix the existing `EmbeddedTranscriber.swift` call site (it uses `model.whisperKitName` and `model.displayName` only — still valid).

- [ ] **Step 4: Run** `cd apple/DistavoCore && swift test` → all pass (Settings still compiles because it only reads `displayName`, `downloadLabel`, `ramLabel`, `id`).

- [ ] **Step 5: Commit**

```bash
git add apple/DistavoCore/Sources/DistavoCore/EmbeddedSupport.swift apple/DistavoCore/Tests/DistavoCoreTests/EmbeddedSupportTests.swift
git commit -m "feat(catalog): add Parakeet and the two BSC Catalan models with engine, repo, language coverage and memory floor"
```

---

### Task 4: Config gains `preferred_catalan_model` and automatic defaults for fresh installs only

**Files:**
- Modify: `apple/DistavoCore/Sources/DistavoCore/Config.swift:59-96` and `:214-227`
- Test: `apple/DistavoCore/Tests/DistavoCoreTests/ConfigMigrationTests.swift` (new)

**Interfaces:**
- Produces: `TranscribeConfig.preferredCatalanModel: String` (JSON `preferred_catalan_model`, default `"bsc-los"`), `TranscribeConfig.effectivePreferredCatalanModel` (validated: `bsc-los` or `bsc-ca-3370h`), `Config.recommendedForThisMac()` → `embeddedModel = "auto"`, `language = "auto"` on Apple Silicon.

- [ ] **Step 1: Write the failing golden-fixture tests**

```swift
import XCTest
@testable import DistavoCore

/// Golden configs from every era must decode AND dispatch exactly as before
/// 1.11 (spec §5.1 / Codex finding 7). Only a missing file gets "auto".
final class ConfigMigrationTests: XCTestCase {
    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: json.data(using: .utf8)!)
    }

    func testPreEmbeddedServerConfigStaysServer() throws {
        let cfg = try decode(#"{"transcribe": {"whisperx_url": "http://10.0.0.5:9000", "model": "medium", "language": "en"}}"#)
        XCTAssertEqual(cfg.transcribe.backend, "server")
        XCTAssertEqual(cfg.transcribe.embeddedModel, "large-v3-turbo")
        XCTAssertEqual(cfg.transcribe.language, "en")
        XCTAssertEqual(cfg.transcribe.preferredCatalanModel, "bsc-los")
    }

    func testCurrent16GBEmbeddedConfigKeepsExplicitModelAndLanguage() throws {
        let cfg = try decode(#"{"transcribe": {"backend": "embedded", "embedded_model": "large-v3-turbo", "language": "es"}}"#)
        XCTAssertEqual(cfg.transcribe.embeddedModel, "large-v3-turbo")
        XCTAssertEqual(cfg.transcribe.language, "es")
        XCTAssertFalse(EmbeddedModelCatalog.isAutomatic(cfg.transcribe.embeddedModel))
    }

    func testCurrent8GBEmbeddedConfigKeepsSmall() throws {
        let cfg = try decode(#"{"transcribe": {"backend": "embedded", "embedded_model": "small"}}"#)
        XCTAssertEqual(cfg.transcribe.embeddedModel, "small")
        XCTAssertEqual(cfg.transcribe.language, "en")
    }

    func testEmptyAndUnknownValuesAreKeptVerbatim() throws {
        let cfg = try decode(#"{"transcribe": {"backend": "embedded", "embedded_model": "no-such", "language": ""}}"#)
        XCTAssertEqual(cfg.transcribe.embeddedModel, "no-such")   // stored as-is …
        XCTAssertEqual(EmbeddedModelCatalog.model(id: cfg.transcribe.embeddedModel).id, "large-v3-turbo") // … resolves as before
        XCTAssertEqual(cfg.transcribe.language, "")
    }

    func testInvalidPreferredCatalanModelFallsBackToLoS() throws {
        let cfg = try decode(#"{"transcribe": {"preferred_catalan_model": "bogus"}}"#)
        XCTAssertEqual(cfg.transcribe.effectivePreferredCatalanModel, "bsc-los")
        let ok = try decode(#"{"transcribe": {"preferred_catalan_model": "bsc-ca-3370h"}}"#)
        XCTAssertEqual(ok.transcribe.effectivePreferredCatalanModel, "bsc-ca-3370h")
    }

    func testFreshInstallOnAppleSiliconIsAutomatic() {
        let cfg = Config.recommendedForThisMac(embeddedSupported: true, memoryBytes: 16 << 30)
        XCTAssertEqual(cfg.transcribe.backend, "embedded")
        XCTAssertEqual(cfg.transcribe.embeddedModel, "auto")
        XCTAssertEqual(cfg.transcribe.language, "auto")
    }

    func testFreshInstallOnIntelStaysServerAndEnglish() {
        let cfg = Config.recommendedForThisMac(embeddedSupported: false, memoryBytes: 16 << 30)
        XCTAssertEqual(cfg.transcribe.backend, "server")
        XCTAssertEqual(cfg.transcribe.language, "en")
    }

    func testSaveReloadDoesNotIntroduceAuto() throws {
        let cfg = try decode(#"{"transcribe": {"backend": "embedded", "embedded_model": "small", "language": "en"}}"#)
        let data = try JSONEncoder().encode(cfg)
        let again = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(again.transcribe.embeddedModel, "small")
        XCTAssertEqual(again.transcribe.language, "en")
    }
}
```

- [ ] **Step 2: Run** `cd apple/DistavoCore && swift test --filter ConfigMigrationTests` → compile error on `preferredCatalanModel`.

- [ ] **Step 3: Implement** in `Config.swift`:

Add to `TranscribeConfig` (property, CodingKey `preferredCatalanModel = "preferred_catalan_model"`, init parameter `preferredCatalanModel: String = "bsc-los"`, decode line `preferredCatalanModel = try c.decodeIfPresent(String.self, forKey: .preferredCatalanModel) ?? d.preferredCatalanModel`) and:

```swift
    /// Which BSC model automatic routing uses for Catalan; an unknown value
    /// falls back to Languages of Spain rather than failing the pipeline.
    public var effectivePreferredCatalanModel: String {
        ["bsc-los", "bsc-ca-3370h"].contains(preferredCatalanModel) ? preferredCatalanModel : "bsc-los"
    }
```

Change `recommendedForThisMac` body:

```swift
        var cfg = Config()
        if embeddedSupported {
            cfg.transcribe.backend = "embedded"
            // Fresh installs let Distavo pick the engine per meeting (spec §5.2).
            // Existing files never pass through here, so nobody is switched.
            cfg.transcribe.embeddedModel = EmbeddedModelCatalog.automaticID
            cfg.transcribe.language = EmbeddedModelCatalog.automaticID
        }
        return cfg
```

Update the existing `ConfigTests.testRecommendedForThisMac…` / `EmbeddedSupportTests.testRecommendationFollowsMemory` expectations only if they assert the old `recommended().id` value for fresh installs (the `memoryBytes` parameter stays, `recommended(memoryBytes:)` is still used by the router in Task 5).

- [ ] **Step 4: Run** `cd apple/DistavoCore && swift test` → all pass.

- [ ] **Step 5: Commit**

```bash
git add apple/DistavoCore/Sources/DistavoCore/Config.swift apple/DistavoCore/Tests/DistavoCoreTests/ConfigMigrationTests.swift apple/DistavoCore/Tests/DistavoCoreTests/ConfigTests.swift apple/DistavoCore/Tests/DistavoCoreTests/EmbeddedSupportTests.swift
git commit -m "feat(config): preferred Catalan model, and automatic engine/language for fresh installs only"
```

---

### Task 5: EngineRouter (pure)

**Files:**
- Create: `apple/DistavoCore/Sources/DistavoCore/EngineRouter.swift`
- Test: `apple/DistavoCore/Tests/DistavoCoreTests/EngineRouterTests.swift`

**Interfaces:**
- Produces:
  - `public struct LanguageDetection: Equatable, Sendable { public let code: String; public let probability: Float; public init(code:probability:) }`
  - `public struct RoutingDecision: Equatable, Sendable { public let model: EmbeddedModel; public let languageHint: String?; public let note: String? }`
  - `public enum EngineRouter { public static let confidenceFloor: Float = 0.5; public static func choose(detections: [LanguageDetection], config: TranscribeConfig, memoryBytes: UInt64) -> RoutingDecision }`
  - `public static func needsDetection(_ config: TranscribeConfig) -> Bool` — true when model is auto **and** language is auto.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import DistavoCore

final class EngineRouterTests: XCTestCase {
    private let gb16: UInt64 = 16 << 30
    private let gb8: UInt64 = 8 << 30
    private func auto(_ preferred: String = "bsc-los") -> TranscribeConfig {
        TranscribeConfig(backend: "embedded", embeddedModel: "auto", language: "auto",
                         preferredCatalanModel: preferred)
    }
    private func d(_ code: String, _ p: Float = 0.9) -> LanguageDetection { .init(code: code, probability: p) }

    func testExplicitModelIsAlwaysHonoured() {
        let cfg = TranscribeConfig(backend: "embedded", embeddedModel: "small", language: "auto")
        let r = EngineRouter.choose(detections: [d("ca")], config: cfg, memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "small")
        XCTAssertEqual(r.languageHint, "ca")
    }

    func testFixedLanguageWithAutoModelNeedsNoDetection() {
        let cfg = TranscribeConfig(backend: "embedded", embeddedModel: "auto", language: "de")
        XCTAssertFalse(EngineRouter.needsDetection(cfg))
        let r = EngineRouter.choose(detections: [], config: cfg, memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "parakeet-tdt-v3")
        XCTAssertEqual(r.languageHint, "de")
    }

    func testCatalanOnlyUsesPreferredCatalanModel() {
        let r = EngineRouter.choose(detections: [d("ca"), d("ca"), d("ca")], config: auto("bsc-ca-3370h"), memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "bsc-ca-3370h")
        XCTAssertEqual(r.languageHint, "ca")
    }

    func testCatalanSpanishMixUsesLanguagesOfSpain() {
        let r = EngineRouter.choose(detections: [d("ca"), d("es"), d("ca")], config: auto("bsc-ca-3370h"), memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "bsc-los")
    }

    func testCatalanEnglishMixNeverGoesToParakeet() {
        for order in [[d("en"), d("ca"), d("en")], [d("ca"), d("en"), d("en")]] {
            let r = EngineRouter.choose(detections: order, config: auto(), memoryBytes: gb16)
            XCTAssertEqual(r.model.id, "bsc-los")
            XCTAssertEqual(r.languageHint, "ca")
        }
    }

    func testSpanishOnlyUsesLanguagesOfSpain() {
        XCTAssertEqual(EngineRouter.choose(detections: [d("es"), d("es")], config: auto(), memoryBytes: gb16).model.id, "bsc-los")
    }

    func testParakeetLanguagesUseParakeetWithDominantHint() {
        let r = EngineRouter.choose(detections: [d("en", 0.9), d("de", 0.7), d("en", 0.8)], config: auto(), memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "parakeet-tdt-v3")
        XCTAssertEqual(r.languageHint, "en")
    }

    func testUnsupportedOrLowConfidenceFallsBackToWhisper() {
        XCTAssertEqual(EngineRouter.choose(detections: [d("ja")], config: auto(), memoryBytes: gb16).model.id, "large-v3-turbo")
        let low = EngineRouter.choose(detections: [d("ca", 0.3), d("en", 0.4)], config: auto(), memoryBytes: gb16)
        XCTAssertEqual(low.model.id, "large-v3-turbo")
        XCTAssertNil(low.languageHint)
        XCTAssertEqual(EngineRouter.choose(detections: [], config: auto(), memoryBytes: gb8).model.id, "small")
    }

    func testMemoryGateFallsBackWithNote() {
        let r = EngineRouter.choose(detections: [d("ca")], config: auto(), memoryBytes: gb8)
        XCTAssertEqual(r.model.id, "small")
        XCTAssertEqual(r.languageHint, "ca")
        XCTAssertNotNil(r.note)
    }
}
```

- [ ] **Step 2: Run** `cd apple/DistavoCore && swift test --filter EngineRouterTests` → `cannot find 'EngineRouter'`.

- [ ] **Step 3: Implement** `EngineRouter.swift`:

```swift
import Foundation

/// One language-identification result from one audio window.
public struct LanguageDetection: Equatable, Sendable {
    public let code: String
    public let probability: Float
    public init(code: String, probability: Float) { self.code = code; self.probability = probability }
}

/// What the app should run: which catalog model, and the language to tell it
/// (a real code or nil — never "auto"). `note` explains a fallback to the user.
public struct RoutingDecision: Equatable, Sendable {
    public let model: EmbeddedModel
    public let languageHint: String?
    public let note: String?
}

/// Spec §5.2. Pure: no I/O, no SDK types. The app layer feeds it detections
/// from the whisper-tiny detector and dispatches on `model.engine`.
public enum EngineRouter {
    public static let confidenceFloor: Float = 0.5

    public static func needsDetection(_ config: TranscribeConfig) -> Bool {
        EmbeddedModelCatalog.isAutomatic(config.embeddedModel)
            && EmbeddedModelCatalog.isAutomatic(config.language)
    }

    public static func choose(detections: [LanguageDetection], config: TranscribeConfig,
                              memoryBytes: UInt64) -> RoutingDecision {
        let fixedLanguage = EmbeddedModelCatalog.isAutomatic(config.language) ? nil
            : (config.language.isEmpty ? nil : config.language)
        let confident = fixedLanguage.map { [$0] }
            ?? detections.filter { $0.probability >= confidenceFloor }.map(\.code)
        let set = Set(confident)
        let dominant = fixedLanguage ?? dominantCode(detections)

        // Rule 1: an explicit model is always honoured.
        if !EmbeddedModelCatalog.isAutomatic(config.embeddedModel) {
            return RoutingDecision(model: EmbeddedModelCatalog.model(id: config.embeddedModel),
                                   languageHint: dominant, note: nil)
        }

        let fallback = EmbeddedModelCatalog.recommended(memoryBytes: memoryBytes)
        let catalan = set.intersection(EmbeddedModelCatalog.catalanFamily)

        var chosen: EmbeddedModel
        var hint: String? = dominant
        if !catalan.isEmpty {
            // Rules 3–4: any confident Catalan/Galician/Basque → a BSC model, never Parakeet.
            let onlyCatalan = set == ["ca"]
            chosen = EmbeddedModelCatalog.model(id: onlyCatalan
                ? config.effectivePreferredCatalanModel : "bsc-los")
            hint = catalan.contains("ca") ? "ca" : (catalan.contains("gl") ? "gl" : "eu")
        } else if set == ["es"] {
            chosen = EmbeddedModelCatalog.model(id: "bsc-los")          // rule 5a
            hint = "es"
        } else if !set.isEmpty, set.isSubset(of: EmbeddedModelCatalog.parakeetLanguages) {
            chosen = EmbeddedModelCatalog.model(id: "parakeet-tdt-v3")  // rule 5b
        } else {
            chosen = fallback                                           // rule 6
            hint = set.isEmpty ? nil : dominant
        }

        // Rule 7: memory gate.
        let gb = Int(memoryBytes / (1024 * 1024 * 1024))
        if chosen.minimumMemoryGB > gb {
            return RoutingDecision(
                model: fallback, languageHint: hint,
                note: "\(chosen.displayName) needs \(chosen.minimumMemoryGB) GB of memory; using \(fallback.displayName) on this Mac.")
        }
        return RoutingDecision(model: chosen, languageHint: hint, note: nil)
    }

    /// The code with the highest summed probability, or nil when nothing was detected.
    static func dominantCode(_ detections: [LanguageDetection]) -> String? {
        var score: [String: Float] = [:]
        for d in detections { score[d.code, default: 0] += d.probability }
        return score.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key
    }
}
```

- [ ] **Step 4: Run** `cd apple/DistavoCore && swift test` → all pass. If `testUnsupportedOrLowConfidenceFallsBackToWhisper` expects `nil` hint for low confidence, confirm rule 6 sets `hint = nil` when `set` is empty (it does).

- [ ] **Step 5: Commit**

```bash
git add apple/DistavoCore/Sources/DistavoCore/EngineRouter.swift apple/DistavoCore/Tests/DistavoCoreTests/EngineRouterTests.swift
git commit -m "feat(router): pure engine routing with Catalan-first mixture rules and the 16 GB gate"
```

---

### Task 6: WordSpeakerAligner (pure, ports SpeakerKit's subsegment semantics)

**Files:**
- Create: `apple/DistavoCore/Sources/DistavoCore/WordSpeakerAligner.swift`
- Test: `apple/DistavoCore/Tests/DistavoCoreTests/WordSpeakerAlignerTests.swift`

**Interfaces:**
- Produces:
  - `public struct TimedWord: Equatable, Sendable { public let text: String; public let start: Double; public let end: Double }`
  - `public struct SpeakerTurn: Equatable, Sendable { public let speaker: Int; public let start: Double; public let end: Double }`
  - `public enum WordSpeakerAligner { public static let betweenWordGap = 0.15; public static let carryGap = 1.0; public static func whisperXDictionary(words: [TimedWord], turns: [SpeakerTurn]) -> [String: Any] }`
  - Output shape identical to `EmbeddedResultMapper`: `["segments": [["text": …, "start": …, "end": …, "speaker": "SPEAKER_00"?]]]`.

Semantics (spec §5.5): words are first grouped into subsegments split where the gap to the previous word exceeds `betweenWordGap` = 0.15 s (SpeakerKit's default `betweenWordThreshold`); each subsegment takes the turn with the **largest intersection** (ties → earlier-starting turn); a subsegment with zero intersection **inherits the previous subsegment's speaker** when the silence before it is ≤ `carryGap` = 1.0 s, otherwise it has **no speaker** (`SPEAKER_UNKNOWN` downstream). Consecutive same-speaker subsegments merge; merged text is split into segments at sentence-final punctuation.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import DistavoCore

final class WordSpeakerAlignerTests: XCTestCase {
    private func w(_ t: String, _ s: Double, _ e: Double) -> TimedWord { .init(text: t, start: s, end: e) }
    private func turn(_ id: Int, _ s: Double, _ e: Double) -> SpeakerTurn { .init(speaker: id, start: s, end: e) }
    private func segs(_ d: [String: Any]) -> [[String: Any]] { d["segments"] as? [[String: Any]] ?? [] }

    func testTwoSpeakersProduceTwoLabelledSegments() {
        let words = [w("Hello", 0, 0.4), w("there.", 0.5, 0.9), w("Hi!", 1.2, 1.5)]
        let turns = [turn(0, 0, 1.0), turn(1, 1.0, 2.0)]
        let s = segs(WordSpeakerAligner.whisperXDictionary(words: words, turns: turns))
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0]["speaker"] as? String, "SPEAKER_00")
        XCTAssertEqual(s[0]["text"] as? String, "Hello there.")
        XCTAssertEqual(s[0]["start"] as? Double, 0)
        XCTAssertEqual(s[0]["end"] as? Double, 0.9)
        XCTAssertEqual(s[1]["speaker"] as? String, "SPEAKER_01")
        XCTAssertEqual(s[1]["text"] as? String, "Hi!")
    }

    func testLargestIntersectionWinsAndTiesGoToEarlierTurn() {
        // word 1.0–2.0 overlaps turn 0 by 0.3 and turn 1 by 0.7
        let words = [w("word", 1.0, 2.0)]
        let turns = [turn(0, 0.0, 1.3), turn(1, 1.3, 3.0)]
        XCTAssertEqual(segs(WordSpeakerAligner.whisperXDictionary(words: words, turns: turns))[0]["speaker"] as? String, "SPEAKER_01")
        let tie = [turn(0, 0.5, 1.5), turn(1, 1.5, 2.5)]   // 0.5 each
        XCTAssertEqual(segs(WordSpeakerAligner.whisperXDictionary(words: words, turns: tie))[0]["speaker"] as? String, "SPEAKER_00")
    }

    func testGapWithinThresholdCarriesPreviousSpeaker() {
        let words = [w("Yes", 0, 0.3), w("indeed", 0.9, 1.2)]     // second word in silence, gap 0.6 s
        let turns = [turn(0, 0, 0.5)]
        let s = segs(WordSpeakerAligner.whisperXDictionary(words: words, turns: turns))
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0]["speaker"] as? String, "SPEAKER_00")
        XCTAssertEqual(s[0]["text"] as? String, "Yes indeed")
    }

    func testLongGapWithNoTurnIsUnknown() {
        let words = [w("Yes", 0, 0.3), w("later", 5.0, 5.3)]
        let turns = [turn(0, 0, 0.5)]
        let s = segs(WordSpeakerAligner.whisperXDictionary(words: words, turns: turns))
        XCTAssertEqual(s.count, 2)
        XCTAssertNil(s[1]["speaker"])
    }

    func testNoTurnsYieldsUnlabelledSegments() {
        let s = segs(WordSpeakerAligner.whisperXDictionary(words: [w("a", 0, 1), w("b", 1, 2)], turns: []))
        XCTAssertEqual(s.count, 1)
        XCTAssertNil(s[0]["speaker"])
    }

    func testSentencePunctuationSplitsSameSpeaker() {
        let words = [w("One.", 0, 0.2), w("Two?", 0.3, 0.5), w("Three…", 0.6, 0.8), w("four", 0.9, 1.0)]
        let s = segs(WordSpeakerAligner.whisperXDictionary(words: words, turns: [turn(0, 0, 2)]))
        XCTAssertEqual(s.map { $0["text"] as? String }, ["One.", "Two?", "Three…", "four"])
    }

    func testEmptyAndOutOfOrderInputsAreHandled() {
        XCTAssertEqual(segs(WordSpeakerAligner.whisperXDictionary(words: [], turns: [])).count, 0)
        let words = [w("b", 1, 2), w("a", 0, 1), w("", 2, 3)]
        let s = segs(WordSpeakerAligner.whisperXDictionary(words: words, turns: [turn(0, 0, 3)]))
        XCTAssertEqual(s[0]["text"] as? String, "a b")
    }
}
```

- [ ] **Step 2: Run** `cd apple/DistavoCore && swift test --filter WordSpeakerAlignerTests` → `cannot find 'WordSpeakerAligner'`.

- [ ] **Step 3: Implement** `WordSpeakerAligner.swift`:

```swift
import Foundation

/// A transcribed word with timestamps in seconds (engine-neutral).
public struct TimedWord: Equatable, Sendable {
    public let text: String
    public let start: Double
    public let end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

/// One diarisation turn: speaker index and its time span in seconds.
public struct SpeakerTurn: Equatable, Sendable {
    public let speaker: Int
    public let start: Double
    public let end: Double
    public init(speaker: Int, start: Double, end: Double) { self.speaker = speaker; self.start = start; self.end = end }
}

/// Labels words with speakers and emits the WhisperX `segments` dictionary the
/// rest of the pipeline consumes. Ports SpeakerKit's `.subsegment` strategy
/// (group words by silence gap → largest-intersection turn → carry the previous
/// speaker when nothing overlaps) so the Parakeet path labels exactly like the
/// WhisperKit path does today. Pure; unit-tested with fixtures.
public enum WordSpeakerAligner {
    /// Silence between two words above which they start a new subsegment —
    /// SpeakerKit's default `betweenWordThreshold` (0.15 s), kept for parity.
    public static let betweenWordGap = 0.15
    /// A subsegment that overlaps no diarisation turn inherits the previous
    /// subsegment's speaker when the silence before it is at most this long;
    /// beyond it the speaker is unknown (spec §5.5).
    public static let carryGap = 1.0

    public static func whisperXDictionary(words rawWords: [TimedWord], turns rawTurns: [SpeakerTurn]) -> [String: Any] {
        let words = rawWords
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        let turns = rawTurns.sorted { $0.start < $1.start }
        guard !words.isEmpty else { return ["segments": [[String: Any]]()] }

        // 1. Subsegments split on silence.
        var groups: [[TimedWord]] = [[words[0]]]
        for i in 1..<words.count {
            if words[i].start - words[i - 1].end > betweenWordGap { groups.append([words[i]]) }
            else { groups[groups.count - 1].append(words[i]) }
        }

        // 2. Speaker per subsegment: largest intersection. A subsegment that
        // overlaps no turn inherits the previous subsegment's speaker if the
        // silence before it is ≤ carryGap (SpeakerKit carries unconditionally;
        // spec §5.5 bounds it), otherwise it is `unknown`.
        var labelled: [(speaker: Int?, words: [TimedWord])] = []
        var previous: (speaker: Int?, end: Double)? = nil
        for group in groups {
            let start = group.first!.start, end = group.last!.end
            var best: (speaker: Int, score: Double)? = nil
            for t in turns {
                let overlap = min(end, t.end) - max(start, t.start)
                guard overlap > 0 else { continue }
                if best == nil || overlap > best!.score { best = (t.speaker, overlap) }
            }
            var speaker = best?.speaker
            if speaker == nil, let prev = previous, start - prev.end <= carryGap { speaker = prev.speaker }
            labelled.append((speaker, group))
            previous = (speaker, end)
        }

        // 3. Merge consecutive same-speaker groups, then split at sentence ends.
        var out: [[String: Any]] = []
        var current: [TimedWord] = []
        var currentSpeaker: Int? = nil
        func flush() {
            guard !current.isEmpty else { return }
            var entry: [String: Any] = [
                "text": current.map(\.text).joined(separator: " "),
                "start": current.first!.start,
                "end": current.last!.end,
            ]
            if let s = currentSpeaker { entry["speaker"] = String(format: "SPEAKER_%02d", s) }
            out.append(entry)
            current = []
        }
        for (speaker, group) in labelled {
            if speaker != currentSpeaker { flush(); currentSpeaker = speaker }
            for word in group {
                current.append(word)
                if endsSentence(word.text) { flush() }
            }
        }
        flush()
        return ["segments": out]
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last else { return false }
        return ".?!…。？！".unicodeScalars.contains(last)
    }
}
```

Note the tie rule: `overlap > best.score` keeps the earlier turn on equal overlap because turns are iterated in start order.

- [ ] **Step 4: Run** `cd apple/DistavoCore && swift test` → all pass.

- [ ] **Step 5: Commit**

```bash
git add apple/DistavoCore/Sources/DistavoCore/WordSpeakerAligner.swift apple/DistavoCore/Tests/DistavoCoreTests/WordSpeakerAlignerTests.swift
git commit -m "feat(core): word-to-speaker aligner with SpeakerKit's subsegment semantics"
```

---

### Task 7: Pin FluidAudio and move DistavoEmbedded to tools-version 6.2

**Files:**
- Modify: `apple/DistavoEmbedded/Package.swift`
- Modify: `apple/DistavoEmbedded/Package.resolved` (intentional this once)

**Interfaces:**
- Produces: `import FluidAudio` available in `DistavoEmbedded`.

- [ ] **Step 1: Rewrite the manifest**

```swift
// swift-tools-version: 6.2
import PackageDescription

// On-device engines for Distavo, kept OUT of DistavoCore so the core package
// stays dependency-free and `cd DistavoCore && swift test` stays fast.
//
// - argmax-oss-swift: WhisperKit (Core ML Whisper, incl. the BSC Catalan
//   fine-tunes from Marc's Hugging Face repo) + SpeakerKit (pyannote), MIT.
// - FluidAudio: NVIDIA Parakeet TDT v3 on the Neural Engine, Apache-2.0.
//   Pinned by REVISION: the `NemoTextProcessing` trait (which lets us drop its
//   prebuilt text-normalisation xcframework) landed on main on 2026-09-09 and is
//   in no tag yet. `traits: []` requires this manifest to be tools 6.2, hence
//   the bump; `swiftLanguageModes: [.v5]` keeps our own targets in Swift 5 mode
//   (dependencies keep theirs). Move to the first tag containing commit 6b90a08.
let package = Package(
    name: "DistavoEmbedded",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DistavoEmbedded", targets: ["DistavoEmbedded"]),
    ],
    dependencies: [
        .package(path: "../DistavoCore"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "41540ea237350afe5117a082b5c28eda642d0612",
                 traits: []),
    ],
    targets: [
        .target(
            name: "DistavoEmbedded",
            dependencies: [
                .product(name: "DistavoCore", package: "DistavoCore"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DistavoEmbeddedTests",
            dependencies: ["DistavoEmbedded"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

- [ ] **Step 2: Resolve and prove the trait is off**

Run:
```bash
cd apple/DistavoEmbedded && rm -rf .build && swift package resolve 2>&1 | tail -3
swift package show-traits --package-id fluidaudio 2>&1 | head -10
swift build 2>&1 | tail -3
```
Expected: resolve succeeds; the trait listing shows `NemoTextProcessing` **disabled**; build succeeds. If `show-traits` does not accept `--package-id`, run `swift package show-traits` and read the FluidAudio block.

- [ ] **Step 3: Prove no binary target is linked**

Run: `ls .build/checkouts/FluidAudio/ && find .build -name "NemoTextProcessing.xcframework" | head -2`
Expected: no xcframework directory anywhere under `.build` (SwiftPM does not fetch a binary target that no enabled trait references).

- [ ] **Step 4: App still builds** — `cd apple && xcodegen generate && xcodebuild -project Distavo.xcodeproj -scheme Distavo-AppStore -configuration Debug -derivedDataPath build-Distavo-AppStore CODE_SIGNING_ALLOWED=NO build | tail -3` → `** BUILD SUCCEEDED **`. Then `find build-Distavo-AppStore/Build/Products -name "*.xcframework" -o -name "NemoTextProcessing*" | head` → nothing.

- [ ] **Step 5: Commit** (this is the one commit where `Package.resolved` changes are intended)

```bash
git add apple/DistavoEmbedded/Package.swift apple/DistavoEmbedded/Package.resolved
git commit -m "build(embedded): add FluidAudio (Parakeet) pinned by revision with its text-normalisation binary disabled; tools 6.2, Swift 5 mode"
```

---

### Task 8: ModelCoordinator actor (readiness, exclusion, progress)

**Files:**
- Create: `apple/DistavoEmbedded/Sources/DistavoEmbedded/ModelCoordinator.swift`
- Modify: `apple/DistavoEmbedded/Sources/DistavoEmbedded/EmbeddedTranscriber.swift:33-66` (`EmbeddedModelStore` gains per-model paths)
- Test: `apple/DistavoEmbedded/Tests/DistavoEmbeddedTests/ModelCoordinatorTests.swift`

**Interfaces:**
- Produces:
  - `EmbeddedModelStore.parakeetDirectory: URL` (= `modelsDirectory/parakeet`), `EmbeddedModelStore.whisperKitDirectory(repo: String?, variant: String) -> URL` (= `modelsDirectory/models/<repo with "/" → "_">/<variant>`, which is where WhisperKit's `downloadBase` puts them), `EmbeddedModelStore.isDownloaded(_ model: EmbeddedModel) -> Bool`, `EmbeddedModelStore.isDetectorDownloaded() -> Bool`, `EmbeddedModelStore.freeSpaceBytes() -> Int64`.
  - `public enum ModelReadiness: Equatable, Sendable { case absent, downloading(fraction: Double), ready }`
  - `public actor ModelCoordinator { public static let shared; public func readiness(of id: String) async -> ModelReadiness; public func setProgressHandler(_:); public func withExclusiveAccess<T>(_ body: () async throws -> T) async throws -> T; public func cancelDownloads(); public func removeAllModels() async throws; public func ensureFreeSpace(forMB mb: Int) throws }`
  - `ensureFreeSpace(forMB:)` throws `RetryableDependencyError` directly (free space can change, so the recording defers).

The coordinator does **not** download by itself; the engines download via their SDKs while holding `withExclusiveAccess`. It serialises: one engine operation at a time (transcription or download), and removal waits for the current operation.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import DistavoCore
@testable import DistavoEmbedded

final class ModelCoordinatorTests: XCTestCase {
    func testExclusiveAccessSerialisesWork() async throws {
        let c = ModelCoordinator()
        actor Log { var events: [String] = []; func add(_ s: String) { events.append(s) } }
        let log = Log()
        async let a: Void = c.withExclusiveAccess {
            await log.add("a-start"); try await Task.sleep(nanoseconds: 100_000_000); await log.add("a-end")
        }
        async let b: Void = c.withExclusiveAccess {
            await log.add("b-start"); await log.add("b-end")
        }
        _ = try await (a, b)
        let events = await log.events
        // b must not start while a is running, whichever runs first.
        XCTAssertTrue(events == ["a-start", "a-end", "b-start", "b-end"] || events == ["b-start", "b-end", "a-start", "a-end"], "\(events)")
    }

    func testFreeSpaceCheckIsRetryable() {
        let c = ModelCoordinator()
        XCTAssertThrowsError(try c.ensureFreeSpace(forMB: 100_000_000)) { error in   // 100 TB
            XCTAssertTrue(error is RetryableDependencyError)
        }
        XCTAssertNoThrow(try c.ensureFreeSpace(forMB: 1))
    }

    func testStorePathsLiveUnderTheSingleModelsFolder() {
        let root = EmbeddedModelStore.modelsDirectory.path
        XCTAssertTrue(EmbeddedModelStore.parakeetDirectory.path.hasPrefix(root))
        let custom = EmbeddedModelStore.whisperKitDirectory(repo: "Joanmarcriera/distavo-whisperkit-coreml", variant: "BSC-LT_whisper-large-v3-LoS")
        XCTAssertTrue(custom.path.hasPrefix(root))
        XCTAssertTrue(custom.path.hasSuffix("models/Joanmarcriera/distavo-whisperkit-coreml/BSC-LT_whisper-large-v3-LoS"))
    }
}
```

- [ ] **Step 2: Run** `cd apple/DistavoEmbedded && swift test --filter ModelCoordinatorTests` → compile errors.

- [ ] **Step 3: Implement.** Add to `EmbeddedModelStore` in `EmbeddedTranscriber.swift`:

```swift
    /// FluidAudio's Parakeet model folder, inside the same root as everything
    /// else. FluidAudio's `download(to:)` / `downloadAndLoad(to:)` take the MODEL
    /// directory itself (its default is `…/FluidAudio/Models/parakeet-tdt-0.6b-v3`),
    /// so this path ends in the model name.
    public static var parakeetDirectory: URL {
        modelsDirectory.appendingPathComponent("parakeet", isDirectory: true)
            .appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
    }

    /// Where WhisperKit stores `variant` when `downloadBase` is `modelsDirectory`
    /// (verified on disk 2026-09-10): `<base>/models/<org>/<repo>/<variant>`,
    /// e.g. `models/argmaxinc/whisperkit-coreml/openai_whisper-small`.
    public static func whisperKitDirectory(repo: String?, variant: String) -> URL {
        var url = modelsDirectory.appendingPathComponent("models", isDirectory: true)
        for part in (repo ?? "argmaxinc/whisperkit-coreml").split(separator: "/") {
            url.appendPathComponent(String(part), isDirectory: true)
        }
        return url.appendingPathComponent(variant, isDirectory: true)
    }

    public static func isDownloaded(_ model: EmbeddedModel) -> Bool {
        switch model.engine {
        case .parakeet:
            // Same check FluidAudio runs before deciding to download (public API).
            return AsrModels.modelsExist(at: parakeetDirectory)
        case .whisperKit:
            // A complete variant folder holds config.json plus the compiled models
            // (AudioEncoder.mlmodelc, TextDecoder.mlmodelc, MelSpectrogram.mlmodelc).
            let dir = whisperKitDirectory(repo: model.whisperKitRepo, variant: model.whisperKitName)
            return ["config.json", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"].allSatisfy {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
        }
    }

    public static func isDetectorDownloaded() -> Bool {
        let dir = whisperKitDirectory(repo: nil, variant: EmbeddedModelCatalog.languageDetectorName)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path)
    }

    public static func freeSpaceBytes() -> Int64 {
        let values = try? modelsDirectory.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
```

`EmbeddedTranscriber.swift` must now `import FluidAudio` for `AsrModels.modelsExist(at:)` (public, `AsrModels.swift:613`). Layout verified on this Mac: `~/Library/Application Support/Distavo/models/models/argmaxinc/whisperkit-coreml/openai_whisper-small/{config.json,AudioEncoder.mlmodelc,TextDecoder.mlmodelc,MelSpectrogram.mlmodelc,…}`.

Create `ModelCoordinator.swift`:

```swift
import Foundation
import DistavoCore

public enum ModelReadiness: Equatable, Sendable {
    case absent
    case downloading(fraction: Double)
    case ready
}

/// One owner for every model operation on disk (spec §5.8): serialises
/// downloads, transcriptions and "Remove downloaded models" so a timer scan and
/// "Download now" can never run the same download twice or delete a folder an
/// engine is reading, and funnels progress into one handler.
public actor ModelCoordinator {
    public static let shared = ModelCoordinator()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var progressHandler: (@Sendable (String) -> Void)?
    private var downloading: [String: Double] = [:]
    private var cancelRequested = false

    public init() {}

    public func setProgressHandler(_ handler: (@Sendable (String) -> Void)?) { progressHandler = handler }
    public func report(_ message: String) { progressHandler?(message) }

    public func readiness(of id: String) -> ModelReadiness {
        if let f = downloading[id] { return .downloading(fraction: f) }
        if id == EmbeddedModelCatalog.automaticID { return .ready }
        return EmbeddedModelStore.isDownloaded(EmbeddedModelCatalog.model(id: id)) ? .ready : .absent
    }

    public func noteDownload(id: String, fraction: Double?) {
        if let f = fraction { downloading[id] = f } else { downloading[id] = nil }
    }

    public func cancelDownloads() { cancelRequested = true }
    public func consumeCancel() -> Bool { defer { cancelRequested = false }; return cancelRequested }

    /// Run `body` as the only model operation in flight.
    public func withExclusiveAccess<T>(_ body: @Sendable () async throws -> T) async throws -> T {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }

    /// Refuse to start a download the disk cannot hold twice over (staging +
    /// final). Free space changes, so the error is retryable.
    public nonisolated func ensureFreeSpace(forMB mb: Int) throws {
        let need = Int64(mb) * 2 * 1024 * 1024
        if EmbeddedModelStore.freeSpaceBytes() < need {
            throw RetryableDependencyError("Not enough free disk space to download \(mb) MB of models — free some space and Distavo will retry.")
        }
    }

    /// Delete every downloaded model once nothing is using them.
    public func removeAllModels() async throws {
        try await withExclusiveAccess { try EmbeddedModelStore.removeAll() }
    }
}
```

- [ ] **Step 4: Run** `cd apple/DistavoEmbedded && swift test --filter ModelCoordinatorTests` → PASS. `git checkout apple/DistavoEmbedded/Package.resolved` if it changed.

- [ ] **Step 5: Commit**

```bash
git add apple/DistavoEmbedded/Sources/DistavoEmbedded/ModelCoordinator.swift apple/DistavoEmbedded/Sources/DistavoEmbedded/EmbeddedTranscriber.swift apple/DistavoEmbedded/Tests/DistavoEmbeddedTests/ModelCoordinatorTests.swift
git commit -m "feat(embedded): model coordinator actor — per-model readiness, exclusive access, free-space check"
```

---

### Task 9: EmbeddedTranscriber loads custom repos, releases the model before SpeakerKit, uses the coordinator

**Files:**
- Modify: `apple/DistavoEmbedded/Sources/DistavoEmbedded/EmbeddedTranscriber.swift:88-146`

**Interfaces:**
- Consumes: `EmbeddedModel.whisperKitRepo`, `ModelCoordinator.shared`, `RetryableDependencyError`.
- Produces: `EmbeddedTranscriber.transcribe(wavURL:model:languageHint:config:)` — new primary entry; the old `transcribe(wavURL:config:)` stays and forwards with `model: EmbeddedModelCatalog.model(id: config.embeddedModel)` and `languageHint: config.language.isEmpty || isAutomatic ? nil : config.language`.

- [ ] **Step 1: Implement** — replace the body of `transcribe`:

```swift
    public func transcribe(wavURL: URL, config: TranscribeConfig) async throws -> [String: Any] {
        let model = EmbeddedModelCatalog.model(id: config.embeddedModel)
        let hint = (config.language.isEmpty || EmbeddedModelCatalog.isAutomatic(config.language)) ? nil : config.language
        return try await transcribe(wavURL: wavURL, model: model, languageHint: hint, config: config)
    }

    /// Transcribe with an explicit catalog model (the router's choice) and a
    /// real language code or nil — never "auto".
    public func transcribe(wavURL: URL, model: EmbeddedModel, languageHint: String?,
                           config: TranscribeConfig) async throws -> [String: Any] {
        guard HardwareProbe.supportsEmbeddedTranscription else {
            throw EmbeddedTranscriberError.unsupportedHardware
        }
        precondition(model.engine == .whisperKit, "EmbeddedTranscriber only runs WhisperKit models")
        let coordinator = ModelCoordinator.shared
        return try await coordinator.withExclusiveAccess {
            let firstRun = !EmbeddedModelStore.isDownloaded(model)
            if firstRun {
                try coordinator.ensureFreeSpace(forMB: model.downloadMB)
                await coordinator.noteDownload(id: model.id, fraction: 0)
                self.report("Downloading \(model.displayName) — \(model.downloadLabel), one-time…")
            } else {
                self.report("Loading \(model.displayName)…")
            }
            defer { Task { await coordinator.noteDownload(id: model.id, fraction: nil) } }

            let whisperConfig = WhisperKitConfig(
                model: model.whisperKitName,
                downloadBase: EmbeddedModelStore.modelsDirectory,
                modelRepo: model.whisperKitRepo,
                verbose: false,
                load: true,
                download: true)
            let results: [TranscriptionResult]
            do {
                let whisper = try await WhisperKit(whisperConfig)
                self.report("Transcribing on this Mac…")
                var options = DecodingOptions()
                options.language = languageHint
                options.wordTimestamps = true
                options.chunkingStrategy = .vad
                results = try await whisper.transcribe(audioPath: wavURL.path, decodeOptions: options)
                // `whisper` goes out of scope here: the 1–4 GB model is released
                // before SpeakerKit loads (spec §6 peak-memory rule).
            } catch {
                throw Self.pipelineError(error, model: model.displayName)
            }

            guard config.diarize else {
                return EmbeddedResultMapper.whisperXDictionary(segments: results.flatMap(\.segments))
            }
            self.report("Identifying speakers…")
            let groups = try await Self.diarize(wavURL: wavURL, results: results, numSpeakers: config.numSpeakers)
            return EmbeddedResultMapper.whisperXDictionary(speakerGroups: groups)
        }
    }

    /// SpeakerKit diarisation of a WhisperKit result (shared with the detector-free path).
    static func diarize(wavURL: URL, results: [TranscriptionResult], numSpeakers: Int) async throws -> [[SpeakerSegment]] {
        let speakerConfig = PyannoteConfig(
            downloadBase: EmbeddedModelStore.modelsDirectory.path,
            download: true, load: true, verbose: false)
        let speakerKit: SpeakerKit
        do { speakerKit = try await SpeakerKit(speakerConfig) }
        catch { throw pipelineError(error, model: "speaker identification") }
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: wavURL.path)
        let diarization = try await speakerKit.diarize(
            audioArray: audio, options: PyannoteDiarizationOptions(numberOfSpeakers: numSpeakers))
        return diarization.addSpeakerInfo(to: results, strategy: .subsegment)
    }

    /// SpeakerKit turns for an engine that brings its own words (Parakeet).
    static func speakerTurns(wavURL: URL, numSpeakers: Int) async throws -> [SpeakerTurn] {
        let speakerConfig = PyannoteConfig(
            downloadBase: EmbeddedModelStore.modelsDirectory.path,
            download: true, load: true, verbose: false)
        let speakerKit: SpeakerKit
        do { speakerKit = try await SpeakerKit(speakerConfig) }
        catch { throw pipelineError(error, model: "speaker identification") }
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: wavURL.path)
        let diarization = try await speakerKit.diarize(
            audioArray: audio, options: PyannoteDiarizationOptions(numberOfSpeakers: numSpeakers))
        return diarization.segments.compactMap { seg in
            guard let id = seg.speaker.speakerId else { return nil }
            return SpeakerTurn(speaker: id, start: Double(seg.startTime), end: Double(seg.endTime))
        }
    }
```

`WhisperKitConfig.init(model:downloadBase:modelRepo:…)` has exactly these leading labels at the 1.0.0 pin (`Configurations.swift:82-84`), so the call above compiles as written. `withExclusiveAccess` runs its closure outside this actor, so calls to `self.report(…)` inside it need `await`. `TranscriptionResult` is the element type of `whisper.transcribe(audioPath:decodeOptions:)`.

- [ ] **Step 2: Build** `cd apple/DistavoEmbedded && swift build 2>&1 | grep -E "error|warning: unused" ; echo exit=$?` → no errors. `git checkout Package.resolved` if touched.

- [ ] **Step 3: Run existing tests** `swift test --filter "EmbeddedResultMapperTests|EmbeddedTranscriberErrorTests"` → PASS.

- [ ] **Step 4: Commit**

```bash
git add apple/DistavoEmbedded/Sources/DistavoEmbedded/EmbeddedTranscriber.swift
git commit -m "feat(transcribe): WhisperKit engine takes the router's model and language, loads custom repos, and frees the model before diarisation"
```

---

### Task 10: LanguageDetector (whisper-tiny, three speech windows)

**Files:**
- Create: `apple/DistavoEmbedded/Sources/DistavoEmbedded/LanguageDetector.swift`
- Test: `apple/DistavoEmbedded/Tests/DistavoEmbeddedTests/LanguageDetectorWindowTests.swift`

**Interfaces:**
- Produces: `public actor LanguageDetector { public static let shared; public func detect(wavURL: URL) async throws -> [LanguageDetection] }` and the pure helper `static func windowStarts(totalSeconds: Double, samples: [Float], sampleRate: Int, window: Double = 30, silenceRMS: Float = 0.01) -> [Double]`.

- [ ] **Step 1: Write the failing test for the pure window picker**

```swift
import XCTest
@testable import DistavoEmbedded

final class LanguageDetectorWindowTests: XCTestCase {
    /// 200 s of "audio": silence except 60–80 s and 150–200 s.
    private func samples() -> [Float] {
        let rate = 100  // coarse fake rate keeps the array small
        var s = [Float](repeating: 0, count: 200 * rate)
        for i in (60 * rate)..<(80 * rate) { s[i] = 0.5 }
        for i in (150 * rate)..<(200 * rate) { s[i] = 0.5 }
        return s
    }

    /// A window "has speech" when the RMS over its 30 s exceeds the floor, so
    /// the probe stops at the first 5 s step whose window touches speech.
    func testWindowsSkipSilenceAndStayInside() {
        let starts = LanguageDetector.windowStarts(totalSeconds: 200, samples: samples(), sampleRate: 100)
        XCTAssertEqual(starts.count, 3)
        // 10 % = 20 s: windows 20–50, 25–55, 30–60 are silent; 35–65 touches speech at 60 → 35
        XCTAssertEqual(starts[0], 35, accuracy: 0.01)
        // 50 % = 100 s: silent until 125–155 touches speech at 150 → 125
        XCTAssertEqual(starts[1], 125, accuracy: 0.01)
        // 90 % = 180 s, but a 30 s window must end ≤ 200 → clamped to 170 (speech there)
        XCTAssertEqual(starts[2], 170, accuracy: 0.01)
    }

    func testShortFileYieldsOneWindowAtZero() {
        let starts = LanguageDetector.windowStarts(totalSeconds: 20, samples: [Float](repeating: 0.5, count: 2000), sampleRate: 100)
        XCTAssertEqual(starts, [0])
    }
}
```

- [ ] **Step 2: Run** `cd apple/DistavoEmbedded && swift test --filter LanguageDetectorWindowTests` → `cannot find 'LanguageDetector'`.

- [ ] **Step 3: Implement**

```swift
import Foundation
import WhisperKit
import DistavoCore

/// Spec §5.3: identifies the spoken language(s) with Whisper tiny (77 MB) on
/// three 30-second windows spread across the recording, each nudged forward to
/// the next stretch with speech so leading silence or hold music does not vote.
public actor LanguageDetector {
    public static let shared = LanguageDetector()
    public init() {}

    /// Three window start times (seconds). Pure, unit-tested.
    static func windowStarts(totalSeconds: Double, samples: [Float], sampleRate: Int,
                             window: Double = 30, silenceRMS: Float = 0.01) -> [Double] {
        guard totalSeconds > window else { return [0] }
        let latest = totalSeconds - window
        func hasSpeech(at start: Double) -> Bool {
            let lo = Int(start * Double(sampleRate))
            let hi = min(samples.count, lo + Int(window * Double(sampleRate)))
            guard hi > lo else { return false }
            var sum: Float = 0
            for i in lo..<hi { sum += samples[i] * samples[i] }
            return (sum / Float(hi - lo)).squareRoot() > silenceRMS
        }
        return [0.1, 0.5, 0.9].map { fraction in
            var start = min(latest, totalSeconds * fraction)
            var probe = start
            while probe <= latest, !hasSpeech(at: probe) { probe += 5 }
            if probe <= latest { start = probe }
            return start
        }
    }

    public func detect(wavURL: URL) async throws -> [LanguageDetection] {
        let coordinator = ModelCoordinator.shared
        return try await coordinator.withExclusiveAccess {
            if !EmbeddedModelStore.isDetectorDownloaded() {
                try coordinator.ensureFreeSpace(forMB: 77)
                await coordinator.report("Downloading language detector — 77 MB, one-time…")
            }
            let config = WhisperKitConfig(
                model: EmbeddedModelCatalog.languageDetectorName,
                downloadBase: EmbeddedModelStore.modelsDirectory,
                verbose: false, load: true, download: true)
            let whisper: WhisperKit
            do { whisper = try await WhisperKit(config) }
            catch { throw EmbeddedTranscriber.pipelineError(error, model: "language detector") }

            await coordinator.report("Detecting language…")
            let full = try AudioProcessor.loadAudioAsFloatArray(fromPath: wavURL.path)
            let rate = 16_000
            let total = Double(full.count) / Double(rate)
            var out: [LanguageDetection] = []
            for start in Self.windowStarts(totalSeconds: total, samples: full, sampleRate: rate) {
                let lo = Int(start * Double(rate))
                let hi = min(full.count, lo + 30 * rate)
                guard hi > lo else { continue }
                let (code, probs) = try await whisper.detectLangauge(audioArray: Array(full[lo..<hi]))
                out.append(LanguageDetection(code: code, probability: probs[code] ?? 0))
            }
            return out
        }
    }
}
```

`detectLangauge` (sic) is WhisperKit's spelling at the 1.0.0 pin (`WhisperKit.swift:540`); `loadAudioAsFloatArray` returns 16 kHz mono, which is what the pipeline's WAV already is.

- [ ] **Step 4: Run** `swift test --filter LanguageDetectorWindowTests` → PASS; `swift build` clean.

- [ ] **Step 5: Commit**

```bash
git add apple/DistavoEmbedded/Sources/DistavoEmbedded/LanguageDetector.swift apple/DistavoEmbedded/Tests/DistavoEmbeddedTests/LanguageDetectorWindowTests.swift
git commit -m "feat(embedded): whisper-tiny language detector over three speech windows"
```

---

### Task 11: ParakeetTranscriber (FluidAudio + SpeakerKit + aligner)

**Files:**
- Create: `apple/DistavoEmbedded/Sources/DistavoEmbedded/ParakeetTranscriber.swift`
- Test: `apple/DistavoEmbedded/Tests/DistavoEmbeddedTests/ParakeetAdapterTests.swift`

**Interfaces:**
- Consumes: `AsrModels.downloadAndLoad(to:…progressHandler:)`, `AsrManager(config:models:)`, `asrManager.transcribe(_ url: URL, decoderState: inout TdtDecoderState, language: Language?)`, `TdtDecoderState.make()`, `buildWordTimings(from:)`, `EmbeddedTranscriber.speakerTurns(wavURL:numSpeakers:)`, `WordSpeakerAligner`.
- Produces: `public actor ParakeetTranscriber { public static let shared; public func transcribe(wavURL: URL, languageHint: String?, config: TranscribeConfig) async throws -> [String: Any] }` and pure `static func timedWords(_ words: [WordTiming]) -> [TimedWord]`.

- [ ] **Step 1: Failing test for the adapter**

```swift
import XCTest
import FluidAudio
import DistavoCore
@testable import DistavoEmbedded

final class ParakeetAdapterTests: XCTestCase {
    func testWordTimingsBecomeTimedWords() {
        let words = [WordTiming(word: "Hello", startTime: 0.1, endTime: 0.4),
                     WordTiming(word: "there.", startTime: 0.5, endTime: 0.9)]
        let timed = ParakeetTranscriber.timedWords(words)
        XCTAssertEqual(timed, [TimedWord(text: "Hello", start: 0.1, end: 0.4),
                               TimedWord(text: "there.", start: 0.5, end: 0.9)])
    }

    func testLanguageHintMapsToFluidAudioOrNil() {
        XCTAssertEqual(ParakeetTranscriber.fluidLanguage("de"), .german)
        XCTAssertNil(ParakeetTranscriber.fluidLanguage("ca"))
        XCTAssertNil(ParakeetTranscriber.fluidLanguage(nil))
    }
}
```

- [ ] **Step 2: Run** `swift test --filter ParakeetAdapterTests` → compile error.

- [ ] **Step 3: Implement**

```swift
import Foundation
import AVFoundation
import FluidAudio
import DistavoCore

/// NVIDIA Parakeet TDT 0.6B v3 through FluidAudio (spec §5.4): the "Fast"
/// engine for 25 European languages. Words come from FluidAudio's token
/// timings; speakers from SpeakerKit (the same diariser as the Whisper path);
/// the pure `WordSpeakerAligner` joins them into the WhisperX shape.
/// Per-call lifetime: nothing model-sized outlives `transcribe`.
public actor ParakeetTranscriber {
    public static let shared = ParakeetTranscriber()
    public init() {}

    static func timedWords(_ words: [WordTiming]) -> [TimedWord] {
        words.map { TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime) }
    }

    /// FluidAudio's typed hint for a Whisper code; nil when Parakeet has no such language.
    static func fluidLanguage(_ code: String?) -> Language? {
        guard let code else { return nil }
        return Language(rawValue: code)
    }

    public func transcribe(wavURL: URL, languageHint: String?, config: TranscribeConfig) async throws -> [String: Any] {
        guard HardwareProbe.supportsEmbeddedTranscription else {
            throw EmbeddedTranscriberError.unsupportedHardware
        }
        let model = EmbeddedModelCatalog.model(id: "parakeet-tdt-v3")
        let coordinator = ModelCoordinator.shared
        return try await coordinator.withExclusiveAccess {
            let firstRun = !EmbeddedModelStore.isDownloaded(model)
            if firstRun {
                try coordinator.ensureFreeSpace(forMB: model.downloadMB)
                await coordinator.report("Downloading \(model.displayName) — \(model.downloadLabel), one-time…")
            } else {
                await coordinator.report("Loading \(model.displayName)…")
            }

            let words: [TimedWord]
            do {
                let models = try await AsrModels.downloadAndLoad(
                    to: EmbeddedModelStore.parakeetDirectory,
                    progressHandler: { progress in
                        Task { await coordinator.noteDownload(id: model.id, fraction: progress.fractionCompleted) }
                    })
                let asr = AsrManager(config: .default, models: models)   // AsrManager.swift:74
                await coordinator.report("Transcribing on this Mac…")
                var state = TdtDecoderState.make()                        // TdtDecoderState.swift:52
                let result = try await asr.transcribe(wavURL, decoderState: &state,
                                                      language: Self.fluidLanguage(languageHint))
                asr.cleanup()
                words = Self.timedWords(buildWordTimings(from: result.tokenTimings ?? []))
            } catch {
                throw EmbeddedTranscriber.pipelineError(error, model: model.displayName)
            }
            await coordinator.noteDownload(id: model.id, fraction: nil)
            guard !words.isEmpty else { throw EmbeddedTranscriberError.emptyResult }

            guard config.diarize else {
                return WordSpeakerAligner.whisperXDictionary(words: words, turns: [])
            }
            await coordinator.report("Identifying speakers…")
            let turns = try await EmbeddedTranscriber.speakerTurns(wavURL: wavURL, numSpeakers: config.numSpeakers)
            return WordSpeakerAligner.whisperXDictionary(words: words, turns: turns)
        }
    }
}
```

Verified at the pin: `AsrManager(config:models:)` takes the models directly (no separate initialise call); `TdtDecoderState.make()` is the non-throwing factory; `cleanup()` is synchronous; `AsrModels.downloadAndLoad(to:…)` takes the model directory itself, which is why `parakeetDirectory` ends in `parakeet-tdt-0.6b-v3`.

- [ ] **Step 4: Run** `swift test --filter ParakeetAdapterTests` → PASS; `swift build` clean; `git checkout Package.resolved` if touched.

- [ ] **Step 5: Commit**

```bash
git add apple/DistavoEmbedded/Sources/DistavoEmbedded/ParakeetTranscriber.swift apple/DistavoEmbedded/Tests/DistavoEmbeddedTests/ParakeetAdapterTests.swift
git commit -m "feat(embedded): Parakeet transcriber via FluidAudio with SpeakerKit speakers"
```

---

### Task 12: Route in AppPipelineDeps and wire coordinator progress

**Files:**
- Modify: `apple/Sources/Distavo/Core/AppPipelineDeps.swift:15-23`
- Modify: `apple/Sources/Distavo/Core/WatcherController.swift:112-125`

**Interfaces:**
- Consumes: `EngineRouter`, `LanguageDetector.shared`, `EmbeddedTranscriber.shared.transcribe(wavURL:model:languageHint:config:)`, `ParakeetTranscriber.shared`, `ModelCoordinator.shared`.

- [ ] **Step 1: Replace the transcribe closure**

```swift
        let serverTranscribe = deps.transcribe
        deps.transcribe = { wavURL, transcribeConfig in
            guard transcribeConfig.backend == "embedded" else {
                return try await serverTranscribe(wavURL, transcribeConfig)
            }
            // Spec §5.9: detect only when both model and language are automatic,
            // route in DistavoCore, then dispatch on the engine. Retryable
            // conditions surface as RetryableDependencyError and defer.
            let detections = EngineRouter.needsDetection(transcribeConfig)
                ? try await LanguageDetector.shared.detect(wavURL: wavURL) : []
            let decision = EngineRouter.choose(
                detections: detections, config: transcribeConfig,
                memoryBytes: HardwareProbe.physicalMemoryBytes)
            if let note = decision.note { await ModelCoordinator.shared.report(note) }
            if EngineRouter.needsDetection(transcribeConfig) {
                await ModelCoordinator.shared.report(
                    "Using \(decision.model.displayName)" + (decision.languageHint.map { " (\($0))" } ?? ""))
            }
            switch decision.model.engine {
            case .parakeet:
                return try await ParakeetTranscriber.shared.transcribe(
                    wavURL: wavURL, languageHint: decision.languageHint, config: transcribeConfig)
            case .whisperKit:
                return try await EmbeddedTranscriber.shared.transcribe(
                    wavURL: wavURL, model: decision.model,
                    languageHint: decision.languageHint, config: transcribeConfig)
            }
        }
```

- [ ] **Step 2: Progress.** In `WatcherController.wireEmbeddedProgress()` add, next to the existing transcriber handler:

```swift
        Task {
            await ModelCoordinator.shared.setProgressHandler { [weak self] message in
                self?.reportEmbeddedProgress(message)
            }
        }
```

and extend the icon heuristic in `reportEmbeddedProgress` so `"Detecting"` and `"Using "` map to `.loading`.

- [ ] **Step 3: Build all three schemes**

```bash
cd apple && xcodegen generate && for sch in Distavo Distavo-AppStore Distavo-Setapp; do xcodebuild -project Distavo.xcodeproj -scheme $sch -configuration Debug -derivedDataPath "build-$sch" CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -1; done
```
Expected: three `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add apple/Sources/Distavo/Core/AppPipelineDeps.swift apple/Sources/Distavo/Core/WatcherController.swift
git commit -m "feat(app): detect, route and dispatch between WhisperKit, the BSC models and Parakeet"
```

---

### Task 13: Settings — grouped picker, Automatic, preferred Catalan model, Download now

**Files:**
- Modify: `apple/Sources/Distavo/Settings/SettingsView.swift:18-45` (state) and `:78-136` (Transcription section)
- Create: `apple/Sources/Distavo/Settings/ModelDownloadButton.swift`

**Interfaces:**
- Consumes: `EmbeddedModelCatalog.selectable()`, `.automaticID`, `ModelCoordinator.shared.readiness(of:)`, `EmbeddedModelStore.isDownloaded(_:)`, `EmbeddedTranscriber`/`ParakeetTranscriber`/`LanguageDetector` for prefetch.
- Produces: `struct ModelDownloadButton: View { let modelIDs: [String]; let totalMB: Int }` — runs each engine's download path on a silent 1-second fixture (see Step 2) or, simpler and preferred, calls a new `ModelCoordinator.prefetch(ids:)` you add here that downloads via the SDKs' own download-only entry points: `WhisperKit.download(variant:downloadBase:from:)` (`WhisperKit.swift:250`) and `AsrModels.download(to:…)`.

- [ ] **Step 1: Add `prefetch` to `ModelCoordinator`** (in `ModelCoordinator.swift`):

```swift
    /// Download (without loading) the detector and the given catalog models.
    /// Used by Settings' "Download now" so the first meeting never waits.
    public func prefetch(ids: [String], includeDetector: Bool,
                         download: @Sendable (EmbeddedModel?) async throws -> Void) async throws {
        try await withExclusiveAccess {
            if includeDetector, !EmbeddedModelStore.isDetectorDownloaded() { try await download(nil) }
            for id in ids {
                let model = EmbeddedModelCatalog.model(id: id)
                guard !EmbeddedModelStore.isDownloaded(model) else { continue }
                try self.ensureFreeSpace(forMB: model.downloadMB)
                if self.consumeCancel() { return }
                // Prime tracking (Task 11 ruling: fractions for untracked ids are ignored),
                // report, download, and always reset — on throw too.
                self.beginDownload(id: model.id)
                self.report("Downloading \(model.displayName) — \(model.downloadLabel)…")
                do { try await download(model) } catch { self.noteDownload(id: model.id, fraction: nil); throw error }
                self.noteDownload(id: model.id, fraction: nil)
            }
        }
    }
```

and in the app target a `ModelPrefetcher` (in `ModelDownloadButton.swift`) that implements the `download` closure: `nil` → `try await WhisperKit.download(variant: EmbeddedModelCatalog.languageDetectorName, downloadBase: EmbeddedModelStore.modelsDirectory, from: "argmaxinc/whisperkit-coreml")`; `.whisperKit` → same with `variant: model.whisperKitName, from: model.whisperKitRepo ?? "argmaxinc/whisperkit-coreml"`; `.parakeet` → `_ = try await AsrModels.download(to: EmbeddedModelStore.parakeetDirectory)`. Check each label against the pinned sources before compiling; the plan names the functions, the pin defines the labels.

- [ ] **Step 2: Rewrite the Transcription section** (embedded branch) in `SettingsView.swift`:

```swift
                if draft.transcribe.backend == "embedded" && embeddedSupported {
                    Picker("Model", selection: $draft.transcribe.embeddedModel) {
                        Text("Automatic (recommended)").tag(EmbeddedModelCatalog.automaticID)
                        Divider()
                        ForEach(EmbeddedModelCatalog.models) { m in
                            Text("\(m.displayName) — \(m.downloadLabel)")
                                .tag(m.id)
                                .disabled(!selectableIDs.contains(m.id))
                        }
                    }
                    if EmbeddedModelCatalog.isAutomatic(draft.transcribe.embeddedModel) {
                        Text("Distavo listens to three short windows, picks the engine for the language it hears — Catalan, Spanish and their mix on the Barcelona models, 25 other European languages on the fast Parakeet engine, everything else on Whisper — and downloads what it needs once.")
                            .font(.caption).foregroundStyle(.secondary)
                        if selectableIDs.contains("bsc-ca-3370h") {
                            Picker("Preferred Catalan model", selection: $draft.transcribe.preferredCatalanModel) {
                                Text("Català · Castellà · Galego · Euskara (Languages of Spain)").tag("bsc-los")
                                Text("Català only (3,370 hours)").tag("bsc-ca-3370h")
                            }
                        }
                    } else {
                        let m = EmbeddedModelCatalog.model(id: draft.transcribe.embeddedModel)
                        Text("\(m.detail) \(m.ramLabel).").font(.caption).foregroundStyle(.secondary)
                    }
                    ModelDownloadButton(modelIDs: downloadSet, totalMB: downloadTotalMB)
                    HStack {
                        if let usage = modelsOnDisk {
                            Text("Models on disk: \(usage)").font(.callout)
                            Button("Remove downloaded models") {
                                Task { try? await ModelCoordinator.shared.removeAllModels(); modelsOnDisk = nil }
                            }
                        } else {
                            Text("No models downloaded yet. Distavo keeps every model it downloads in Application Support/Distavo/models; removing that folder removes all of them (macOS keeps its own small Core ML caches separately).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
```

Add computed helpers near the state:

```swift
    private var selectableIDs: Set<String> { Set(EmbeddedModelCatalog.selectable().map(\.id)) }
    /// What "Download now" fetches for the current choice (spec §5.10).
    private var downloadSet: [String] {
        if EmbeddedModelCatalog.isAutomatic(draft.transcribe.embeddedModel) {
            var ids = ["parakeet-tdt-v3"]
            if selectableIDs.contains("bsc-los") { ids.append(draft.transcribe.effectivePreferredCatalanModel) }
            return ids
        }
        return [draft.transcribe.embeddedModel]
    }
    private var downloadTotalMB: Int {
        downloadSet.map { EmbeddedModelCatalog.model(id: $0).downloadMB }.reduce(0, +)
            + (EmbeddedModelCatalog.isAutomatic(draft.transcribe.embeddedModel) ? 77 : 0)
    }
```

Language picker: insert `Text("Automatic (detect)").tag(EmbeddedModelCatalog.automaticID)` as the first entry and make `languageChoices` treat `"auto"` as recognised (no synthetic "not a standard code" row).

- [ ] **Step 3: `ModelDownloadButton`**

```swift
import SwiftUI
import DistavoCore
import DistavoEmbedded
import WhisperKit
import FluidAudio

/// "Download now" with a total, a progress line and Cancel (spec §5.10).
struct ModelDownloadButton: View {
    let modelIDs: [String]
    let totalMB: Int
    @State private var running = false
    @State private var status: String?

    var body: some View {
        HStack {
            Button(running ? "Downloading…" : "Download now (\(totalMB) MB)") { start() }
                .disabled(running || modelIDs.isEmpty)
            if running { Button("Cancel") { Task { await ModelCoordinator.shared.cancelDownloads() } } }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func start() {
        running = true; status = "Starting…"
        Task {
            await ModelCoordinator.shared.setProgressHandler { message in
                Task { @MainActor in status = message }
            }
            do {
                try await ModelCoordinator.shared.prefetch(ids: modelIDs, includeDetector: true) { model in
                    try await ModelPrefetcher.download(model)
                }
                await MainActor.run { status = "Ready"; running = false }
            } catch {
                await MainActor.run { status = error.localizedDescription; running = false }
            }
        }
    }
}

enum ModelPrefetcher {
    static func download(_ model: EmbeddedModel?) async throws {
        guard let model else {
            _ = try await WhisperKit.download(variant: EmbeddedModelCatalog.languageDetectorName,
                                              downloadBase: EmbeddedModelStore.modelsDirectory,
                                              from: "argmaxinc/whisperkit-coreml")
            return
        }
        switch model.engine {
        case .whisperKit:
            _ = try await WhisperKit.download(variant: model.whisperKitName,
                                              downloadBase: EmbeddedModelStore.modelsDirectory,
                                              from: model.whisperKitRepo ?? "argmaxinc/whisperkit-coreml")
        case .parakeet:
            _ = try await AsrModels.download(to: EmbeddedModelStore.parakeetDirectory)
        }
    }
}
```

Note the Settings progress handler replaces the watcher's; restore it when the button finishes by calling the watcher's `wireEmbeddedProgress()` again (make that method `internal` and call it via the `controller` the view already holds), or route both through one fan-out closure in `WatcherController`. Pick the fan-out: `WatcherController` keeps the coordinator handler and exposes `@Published var modelProgress: String?` that this view reads. Whichever you choose, only one `setProgressHandler` call may exist in the app at runtime.

- [ ] **Step 4: Build** all three schemes (`xcodegen generate` first) → `** BUILD SUCCEEDED **` ×3. Launch a Debug build? **No** — the live app shares config and data (memory: `distavo-shared-config-no-isolation`). Verify the UI in Task 16's signed build.

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/Distavo/Settings/SettingsView.swift apple/Sources/Distavo/Settings/ModelDownloadButton.swift apple/DistavoEmbedded/Sources/DistavoEmbedded/ModelCoordinator.swift apple/project.yml
git commit -m "feat(settings): grouped engine picker with Automatic, preferred Catalan model and Download now"
```

---

### Task 14: Convert and publish the BSC models (spike first, then both)

**Status 2026-09-10 (controller, out of band):** Steps 1, 2, 3 and 5 are DONE — `convert.sh` and
`manifest.py` exist (commits a57c791, d91823a, 4c9bb80: repo creation and a safetensors re-save
step were needed, see the script's comments), and both models are published under
`Joanmarcriera/distavo-whisperkit-coreml` with manifests: `BSC-LT_whisper-large-v3-LoS` (source
revision e562381fff61707117dffb9de6d699905d78f8ef) and `BSC-LT_whisper-large-v3-ca-punctuated-3370h`
(source 5a5fb60f977e349e9d8d1fac1ecbb945c1e81b0a), 3.10 GB / 21 files each, ~40 min per model on
the M5 Pro. **What remains: Step 4 (prove the artefact through the app engine) and Step 6 (README).**

**Files:**
- Exists: `tools/whisperkit-models/convert.sh`, `tools/whisperkit-models/manifest.py`
- Create: `tools/whisperkit-models/README.md`
- Modify: `apple/DistavoEmbedded/Tests/DistavoEmbeddedTests/EmbeddedPipelineLiveTests.swift` (env vars for model and language)

**Interfaces:**
- Produces: Hugging Face repo `Joanmarcriera/distavo-whisperkit-coreml` with folders `BSC-LT_whisper-large-v3-LoS/` and `BSC-LT_whisper-large-v3-ca-punctuated-3370h/`, each containing the WhisperKit Core ML files plus `manifest.json`.

- [ ] **Step 1: `convert.sh`**

```bash
#!/usr/bin/env bash
# Convert a Hugging Face Whisper checkpoint to WhisperKit Core ML and publish it to
# Marc's repo. Usage:  tools/whisperkit-models/convert.sh BSC-LT/whisper-large-v3-LoS
# Needs: uv, ~10 GB free, HF_TOKEN in ~/.tokens (write scope). Never prints the token.
set -euo pipefail
model="${1:?hf model id, e.g. BSC-LT/whisper-large-v3-LoS}"
repo="Joanmarcriera/distavo-whisperkit-coreml"
tools_commit="${WHISPERKITTOOLS_COMMIT:-main}"
here="$(cd "$(dirname "$0")" && pwd)"
work="$here/.work"; mkdir -p "$work"
eval "$(grep '^export HF_TOKEN=' ~/.tokens)"; export HF_TOKEN
[ -d "$work/venv" ] || uv venv --python 3.11 "$work/venv"
# shellcheck disable=SC1091
source "$work/venv/bin/activate"
uv pip install -q "git+https://github.com/argmaxinc/whisperkittools.git@${tools_commit}" huggingface_hub
src_rev="$(python -c "from huggingface_hub import HfApi; print(HfApi().model_info('$model').sha)")"
out="$work/out"; mkdir -p "$out"
MODEL_REPO_ID="$repo" whisperkit-generate-model --model-version "$model" --output-dir "$out" --upload-results
folder="$(echo "$model" | tr '/' '_')"
python "$here/manifest.py" "$out/$folder" "$model" "$src_rev" "$tools_commit" > "$out/$folder/manifest.json"
python - <<EOF
from huggingface_hub import HfApi
HfApi().upload_file(path_or_fileobj="$out/$folder/manifest.json", path_in_repo="$folder/manifest.json", repo_id="$repo")
EOF
echo "published $repo/$folder (source $src_rev)"
```

- [ ] **Step 2: `manifest.py`**

```python
#!/usr/bin/env python3
"""Emit manifest.json for a converted WhisperKit folder: source revision, tool
revision, and size + SHA-256 per file, so the app can verify a download and a
later conversion never silently replaces this one (spec §5.6)."""
import hashlib, json, os, sys
folder, source, source_rev, tools_rev = sys.argv[1:5]
files = {}
for root, _, names in os.walk(folder):
    for n in sorted(names):
        if n == "manifest.json": continue
        p = os.path.join(root, n); rel = os.path.relpath(p, folder)
        h = hashlib.sha256()
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""): h.update(chunk)
        files[rel] = {"bytes": os.path.getsize(p), "sha256": h.hexdigest()}
print(json.dumps({"source_model": source, "source_revision": source_rev,
                  "whisperkittools": tools_rev, "files": files}, indent=2))
```

- [x] **Step 3: Spike on LoS** — done by the controller (see Status above; log in `tools/whisperkit-models/.work/convert-LoS.log`).

- [ ] **Step 4: Prove the artefact** with the app's own engine, from a clean folder. Extend `EmbeddedPipelineLiveTests` to honour `DISTAVO_PIPELINE_MODEL` (catalog id, default `large-v3-turbo`) and `DISTAVO_PIPELINE_LANGUAGE` (Whisper code or `auto`, default `en`) by building the `TranscribeConfig` it passes to `EmbeddedTranscriber.shared.transcribe(wavURL:model:languageHint:config:)` from them (model via `EmbeddedModelCatalog.model(id:)`, hint nil for `auto`), and print — metrics only, never transcript text — the model id, the folder it loaded from (`EmbeddedModelStore.whisperKitDirectory(repo:variant:)`), wall-clock, word count and whether word timestamps were present. Then run it on the 2026-07-23 recording:
```bash
cd apple/DistavoEmbedded && DISTAVO_PIPELINE_LIVE=1 DISTAVO_PIPELINE_AUDIO="$HOME/Library/Application Support/Distavo/work/Meeting_2026-07-23_10.58.50.wav" DISTAVO_PIPELINE_OUT=/private/tmp/claude-501/bsc-spike swift test --filter EmbeddedPipelineLiveTests 2>&1 | tail -15
```
with `DISTAVO_PIPELINE_MODEL=bsc-los DISTAVO_PIPELINE_LANGUAGE=ca` and `DISTAVO_PIPELINE_OLLAMA` unset (skip summarising if the test supports it; otherwise point it at `http://127.0.0.1:11434` with `gemma4:26b`, which is running on this Mac). Expected: cold download from the custom repo into `~/Library/Application Support/Distavo/models/models/Joanmarcriera/distavo-whisperkit-coreml/BSC-LT_whisper-large-v3-LoS`, tokenizer resolved to `openai/whisper-large-v3` (folder `models/openai/whisper-large-v3` appears), transcript written to `DISTAVO_PIPELINE_OUT`, word timestamps present, and a second run with Wi-Fi off (`networksetup -setairportpower en0 off`, then back on) loads from disk without any download. Record wall-clock, model load time and the transcript word count (today's WhisperKit-turbo transcript of the same file has 7,144 words) in the README. Never paste transcript text anywhere.

- [x] **Step 5: Convert the second model** — done by the controller (log in `tools/whisperkit-models/.work/convert-ca3370h.log`).

- [ ] **Step 6: README** (`tools/whisperkit-models/README.md`): usage, the two source revisions and publish date, the whisperkittools commit actually installed (read it from `tools/whisperkit-models/.work/venv` — `pip show whisperkittools` or the git URL in `pip freeze`), sizes (3.10 GB / 21 files each), the two traps the script handles (repo must exist; `.bin` → safetensors because torch 2.5 refuses `.bin`), and the Step 4 verification numbers. Commit:

```bash
git add tools/whisperkit-models
git commit -m "tools(models): convert BSC Catalan Whisper fine-tunes to WhisperKit Core ML and publish with manifests"
```

---

### Task 15: Manifest verification after download

**Files:**
- Modify: `apple/DistavoEmbedded/Sources/DistavoEmbedded/EmbeddedTranscriber.swift` (after the WhisperKit init for custom-repo models)
- Create: `apple/DistavoEmbedded/Sources/DistavoEmbedded/ModelManifest.swift`
- Test: `apple/DistavoEmbedded/Tests/DistavoEmbeddedTests/ModelManifestTests.swift`

**Interfaces:**
- Produces: `struct ModelManifest: Decodable { let files: [String: Entry]; struct Entry: Decodable { let bytes: Int64; let sha256: String } }`, `enum ModelManifestCheck { static func verify(folder: URL) throws }` throwing `ModelManifestError.mismatch(file:)` / `.missing(file:)`.

- [ ] **Step 1: Failing test** — write two files into a temp folder, a matching `manifest.json`, assert `verify` passes; tamper one byte, assert it throws `.mismatch`.

```swift
import XCTest
@testable import DistavoEmbedded

final class ModelManifestTests: XCTestCase {
    func testVerifyPassesThenFailsOnTamper() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: dir.appendingPathComponent("a.bin"))
        let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try Data(#"{"files": {"a.bin": {"bytes": 3, "sha256": "\#(sha)"}}}"#.utf8)
            .write(to: dir.appendingPathComponent("manifest.json"))
        XCTAssertNoThrow(try ModelManifestCheck.verify(folder: dir))
        try Data("abd".utf8).write(to: dir.appendingPathComponent("a.bin"))
        XCTAssertThrowsError(try ModelManifestCheck.verify(folder: dir))
    }
}
```

- [ ] **Step 2: Run** → compile error. **Step 3: Implement** with `CryptoKit.SHA256` streaming over `FileHandle` in 1 MB chunks; `verify` is a no-op (returns) when `manifest.json` is absent (Argmax's repo has none). In `EmbeddedTranscriber.transcribe`, after `WhisperKit(whisperConfig)` succeeds and only when `model.whisperKitRepo != nil`, call `try ModelManifestCheck.verify(folder: EmbeddedModelStore.whisperKitDirectory(repo: model.whisperKitRepo, variant: model.whisperKitName))`; on failure delete that folder and throw `RetryableDependencyError("The \(model.displayName) download was incomplete — Distavo will download it again.")`. **Step 4:** tests pass, build clean. **Step 5: Commit** `feat(embedded): verify custom model downloads against their manifest`.

---

### Task 16: Credits, notices, What's New, version, compliance gates, bake-off

**Files:**
- Modify: `NOTICES.md`, `apple/metadata/whats-new/en-GB.txt`, `apple/project.yml:26-27`, `CLAUDE.md` (pipeline description line)

- [ ] **Step 1: NOTICES.md** — add sections:

```markdown
## FluidAudio (Parakeet runtime)

- Source: https://github.com/FluidInference/FluidAudio
- License: Apache-2.0 — Copyright © Fluid Inference
- Used for: running NVIDIA Parakeet TDT 0.6B v3 on the Neural Engine (the "Fast"
  built-in engine). Linked without its text-normalisation binary.

## NVIDIA Parakeet TDT 0.6B v3 (model, downloaded at runtime)

- Source: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 (Core ML conversion:
  https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)
- License: CC-BY-4.0 — © NVIDIA Corporation. Attribution: "Parakeet TDT 0.6B v3 by NVIDIA".

## Barcelona Supercomputing Center — Catalan Whisper models (downloaded at runtime)

- Source: https://huggingface.co/BSC-LT/whisper-large-v3-LoS and
  https://huggingface.co/BSC-LT/whisper-large-v3-ca-punctuated-3370h, converted to
  Core ML by Distavo (https://huggingface.co/Joanmarcriera/distavo-whisperkit-coreml).
- License: Apache-2.0 — © Language Technologies Unit, Barcelona Supercomputing Center,
  within Projecte AINA (Generalitat de Catalunya).
```

Update the "Models downloaded at runtime" list and the closing sentence to mention `openai/whisper-tiny` (detector) and that the tokenizer is fetched from `openai/whisper-large-v3`.

- [ ] **Step 2: What's New** (`en-GB.txt`, replace):

```
• Meeting notes in Catalan, Spanish — and meetings that switch between them. Two new built-in models from the Barcelona Supercomputing Center (Languages of Spain: Catalan, Spanish, Galician, Basque; and a Catalan-only model) transcribe entirely on your Mac. No other Mac app does this on-device.
• A new "Fast" engine (NVIDIA Parakeet) transcribes an hour-long meeting in seconds for English, French, German, Italian, Portuguese and 20 other European languages.
• "Automatic" model and language: Distavo listens to three short windows, picks the right engine for what it hears, and downloads it once. Fresh installs start on Automatic; your existing choice is untouched.
• "Download now" in Settings fetches the models ahead of your first meeting, with progress and Cancel.
• If a model can't be downloaded because you're offline, the recording now waits and retries automatically instead of being marked failed.
• If your Language setting is "English" but your meetings aren't, Whisper was quietly translating them. Switch Language to "Automatic — pick the engine by language" in Settings to transcribe them as spoken.
```

- [ ] **Step 3: Version and measured sizes** — `MARKETING_VERSION: "1.11.0"`, `CURRENT_PROJECT_VERSION: "14"` in `apple/project.yml`. Update the CLAUDE.md "What this is" line to mention Parakeet and the BSC models. Correct the two BSC catalog entries in `EmbeddedSupport.swift` to the published size, `downloadMB: 3100` (each folder measured 3.10 GB on the Hub, 21 files), and re-run `swift test` in DistavoCore.

- [ ] **Step 4: Gates** — run the `distavo-native-verify` skill's three-scheme build and the gate inspection; additionally:
```bash
cd apple && for sch in Distavo Distavo-AppStore Distavo-Setapp; do find "build-$sch/Build/Products/Debug/Distavo.app" -name "*.xcframework" -o -name "*NemoText*" -o -name "*.dylib" | grep -v "Distavo.debug.dylib\|Sparkle" ; done
```
Expected: nothing printed (no unexpected binaries).

- [ ] **Step 5: Bake-off** — **finding from Task 14 (2026-09-10):** today's transcript of the 2026-07-23 meeting (`Meeting_2026-07-23_10.58.50.transcript.clean.txt`, 7,144 words) is 98 % English because the config's `language = "en"` made Whisper *translate* a Catalan/Spanish meeting; it is not a baseline. Compare like with like using the live test (Task 14's env vars), on the 2026-07-23 recording: (a) `DISTAVO_PIPELINE_MODEL=large-v3-turbo DISTAVO_PIPELINE_LANGUAGE=auto` (Whisper's own detection, no translation), (b) `bsc-los` with `ca`, (c) `bsc-los` with `auto`, and on the 2026-09-09 English call: (d) `parakeet-tdt-v3` with `en` and (e) `large-v3-turbo` with `en`. Record per run: wall-clock, model load, word count, language mix of the output (the chunk tagger in the session scratch is fine: en/ca/es/mixed percentages), and summary quality of the resulting note (read the note, not the transcript, and score it on the 14-point rubric from Vikunja #2063). Rule 4 of the router (ca+en → LoS) stays only if (b) or (c) beats (a) on the Catalan note. Write `docs/superpowers/plans/2026-09-10-bakeoff-results.md` with the numbers (no transcript text). Go/no-go per spec §8.

- [ ] **Step 6: Commit**

```bash
git add NOTICES.md apple/metadata/whats-new/en-GB.txt apple/project.yml CLAUDE.md docs/superpowers/plans/2026-09-10-bakeoff-results.md
git commit -m "chore(release): 1.11.0 — credits for FluidAudio, NVIDIA Parakeet and BSC; What's New; bake-off results"
```

Then hand over to the `distavo-release` skill for tag, appcast and the App Store gate (Vikunja https://familia.riera.co.uk/tasks/2146).

---

## Self-review

- **Spec coverage:** §3 pins → Task 7; §4 deferral → Tasks 1–2 (+ 8, 10, 11, 15 throw the retryable type); §5.1 catalog → Task 3; §5.1 config → Task 4; §5.2 router → Task 5; §5.3 detector → Task 10; §5.4 Parakeet → Task 11; §5.5 aligner → Task 6; §5.6 custom repo + manifest → Tasks 9, 14, 15; §5.7 tool → Task 14; §5.8 coordinator → Task 8 (+ prefetch in 13); §5.9 wiring → Task 12; §5.10 Settings → Task 13; §5.11 credits → Task 16; §6 memory gate → Tasks 3, 5 (measurement itself is the release checklist in Task 16 / Vikunja 2146); §7 error handling → Tasks 1, 8, 15; §8 tests → each task, live/bake-off in 14 and 16.
- **Placeholders:** none; every step has code or an exact command. Three places say "check the label at the pin" (Tasks 9, 11, 13) — that is deliberate: the plan names the API, the pinned source is authoritative.
- **Type consistency:** `RetryableDependencyError(_:)`, `ProcessStatus.deferred`, `EmbeddedModel.engine/.whisperKitRepo/.languages/.minimumMemoryGB`, `EmbeddedModelCatalog.automaticID/.languageDetectorName/.selectable(memoryBytes:)`, `TranscribeConfig.preferredCatalanModel/.effectivePreferredCatalanModel`, `LanguageDetection(code:probability:)`, `RoutingDecision.model/.languageHint/.note`, `EngineRouter.choose(detections:config:memoryBytes:)/.needsDetection(_:)`, `TimedWord(text:start:end:)`, `SpeakerTurn(speaker:start:end:)`, `WordSpeakerAligner.whisperXDictionary(words:turns:)`, `ModelCoordinator.shared.withExclusiveAccess/report/readiness(of:)/noteDownload/prefetch/removeAllModels/ensureFreeSpace(forMB:)`, `EmbeddedModelStore.parakeetDirectory/.whisperKitDirectory(repo:variant:)/.isDownloaded(_:)/.isDetectorDownloaded()`, `EmbeddedTranscriber.pipelineError/.transcribe(wavURL:model:languageHint:config:)/.speakerTurns(wavURL:numSpeakers:)`, `LanguageDetector.shared.detect(wavURL:)`, `ParakeetTranscriber.shared.transcribe(wavURL:languageHint:config:)` — used with the same names in every task.
