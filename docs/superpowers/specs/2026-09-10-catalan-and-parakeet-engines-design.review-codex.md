# Codex design review — Catalan and Parakeet engines

**Reviewed:** 2026-09-10  
**Baseline:** commit `9961d59`  
**Scope:** feasibility and risk review only; no implementation changes

The product direction is sound, and a custom WhisperKit repository plus a Parakeet adapter are both feasible. The current design is not implementation-ready, however. Two claimed invariants are false against the code and current upstream packages: transient transcription/download errors cannot remain pending while `Pipeline.swift` is unchanged, and FluidAudio's current package does not expose a trait that removes `NemoTextProcessing`.

## Blockers

### 1. Transcription download failures are permanent failures in the current pipeline

The error-handling section says detector/model download failures use the existing `modelUnavailable(offline:)` path, stay pending, and retry on the next scan, while section 3.7 says `Pipeline.swift` and `PipelineDeps` remain unchanged. That is not how the current seam behaves.

`EmbeddedTranscriber` converts a WhisperKit load/download error into `EmbeddedTranscriberError.modelUnavailable` and throws it (`EmbeddedTranscriber.swift:103-114,148-154`). `Pipeline.processOne` has already written `.processing` before it calls `deps.transcribe`; its catch-all then writes a persistent `.failed` marker (`Pipeline.swift:206-216,241-245`). Only summariser selection has an explicit deferral path, and it runs before `.processing` is written (`Pipeline.swift:192-204`). A detector or Parakeet failure routed through the same closure will therefore also fail permanently. This directly violates the repository's durability rule.

**Recommendation:** revise the design so DistavoCore can distinguish retryable transcription unavailability from a permanent transcription defect without importing DistavoEmbedded. Prefer a typed outcome/error defined in DistavoCore and carried through `PipelineDeps.transcribe`; on retryable unavailability, clear `.processing`, return a deferred/retry status, and do not write `.failed`. Add an end-to-end test in which the first detector/model load throws a retryable offline error and the next scan succeeds without manual “Process now”. Do not approve “`Pipeline.swift` unchanged”.

### 2. The FluidAudio dependency plan does not match the current package or API

The spec does not name a FluidAudio version or revision. In the current latest tagged release inspected for this review, `v0.15.6`, `Package.swift` uses tools version 6.0, declares no package traits, and makes `NemoTextProcessing` an unconditional dependency of the `FluidAudio` target. SwiftPM's `traits: []` only disables traits that the dependency actually declares; it cannot remove an unconditional target dependency. The statement that the App Store build “gains no binary framework” is therefore unsupported.

The sample API is also not accurate for `v0.15.6`: `AsrModels.downloadAndLoad(to:)` exists, but `AsrManager.transcribe` requires an `inout TdtDecoderState`; output is `ASRResult.tokenTimings`, which must be converted with FluidAudio's `buildWordTimings(from:)`. There is no specified `[TimedWord]` API. These are normal integration details, but without a pin the design cannot be compiled as written.

Moving DistavoEmbedded to tools version 6.2 and declaring `swiftLanguageModes: [.v5]` is feasible with the installed Xcode 26.6 toolchain and will retain Swift 5 mode for the DistavoEmbedded target. It does not force dependency targets into Swift 5: FluidAudio controls its own language mode, and the pinned `argmax-oss-swift` checkout already has a Swift-6.2-specific manifest using Swift 6. The concurrency claim must be scoped to DistavoEmbedded itself.

**Recommendation:** pin an exact FluidAudio version/revision and replace the pseudocode with the API at that pin. If excluding `NemoTextProcessing` is a release requirement, use an upstream release that declares it behind a non-default trait, contribute that change upstream, or depend on a deliberately slim audited product/fork. Then resolve from a clean checkout, run `swift package show-traits`, build all three actual edition schemes, and inspect the App Store archive for embedded/static binary content. Record the pin in `Package.resolved` and the notices.

Primary upstream evidence: [FluidAudio v0.15.6 manifest](https://github.com/FluidInference/FluidAudio/blob/v0.15.6/Package.swift), [FluidAudio v0.15.6 ASR types](https://github.com/FluidInference/FluidAudio/blob/v0.15.6/Sources/FluidAudio/ASR/Parakeet/AsrTypes.swift), [FluidAudio v0.15.6 transcriber](https://github.com/FluidInference/FluidAudio/blob/v0.15.6/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrManager.swift), and [SwiftPM trait semantics](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/addingdependencies/).

## High severity

### 3. First-30-second, single-label routing does not support the promised code-switched case

WhisperKit's `detectLanguage(audioPath:)` does inspect at most the first 30 seconds, but it returns one best language and a probability distribution for that window. A `0.5` confidence threshold only rejects uncertainty; it does not detect that later parts of the meeting switch language. A confident English introduction routes the entire Catalan meeting to Parakeet. A confident Catalan introduction can route the entire Catalan/Spanish/English meeting to the Catalan-only model. Choosing `bsc-ca-3370h` as the preferred Catalan model makes this sharper. The bake-off's 64-minute Catalan/Spanish/English recording therefore tests the exact case the proposed router cannot represent.

The design also does not define the effective language passed to the selected engine. Passing persisted `"auto"` through the current Whisper path would set `DecodingOptions.language = "auto"` (`EmbeddedTranscriber.swift:117-122`), which is not a Whisper language code. FluidAudio's language hint is a typed `Language?`, not the stored string.

**Recommendation:** make detection produce an explicit routing result containing the selected model and an engine-specific optional language hint; never pass `"auto"` to either SDK. For meeting routing, sample multiple speech-bearing windows (at least early/middle/late, not just byte/time zero), retain more than one confident language, and define a mixture policy. At minimum, route Catalan+Spanish to LoS; do not route any detected Catalan mixture to Parakeet. Decide the Catalan+English case by measured bake-off results rather than assumption. Test language-order permutations, leading silence/music, short clips, and low-confidence speech.

### 4. Custom WhisperKit loading is feasible, but the tokenizer rationale and supply-chain contract are wrong

Passing `modelRepo` into `WhisperKitConfig` is supported by the pinned `argmax-oss-swift` 1.0.0 checkout, and a converted large-v3-compatible model should be loadable from a custom repository. The folder name must uniquely match WhisperKit's model-download glob, so stable unambiguous names matter.

Tokenizer selection is not derived from the folder containing `large-v3`. In the pinned code, WhisperKit loads the Core ML decoder/encoder, detects the variant from output vocabulary and encoder dimensions, maps that to `openai/whisper-large-v3`, and then searches/downloads that tokenizer. The proposed names may work, but not for the reason stated. A bad conversion whose tensor signatures are wrong will select the wrong tokenizer regardless of its folder name.

The runtime also follows the custom repository's mutable `main`; the conversion README pinning the source revision does not pin what every installed app downloads. If the converted folder does not bundle tokenizer files, additional OpenAI Hugging Face repositories may be contacted, contradicting “no network beyond the two Hugging Face repos”.

**Recommendation:** change section 3.5 to describe tensor-signature-based tokenizer resolution and treat folder naming only as model glob/disambiguation. Before implementation, convert one model and prove: clean download from the custom repo, tokenizer resolution, cold load, offline warm reload, transcription, word timestamps, and relaunch. Publish an immutable model manifest containing source revision, conversion-tool revision, artifact sizes and SHA-256 hashes. Either bundle the tokenizer in each converted folder or document every repository/domain contacted. If WhisperKit cannot request an immutable HF revision, use immutable folder IDs plus application-side manifest/hash verification and never replace files in place.

Relevant pinned source: [WhisperKit model setup](https://github.com/argmaxinc/argmax-oss-swift/blob/25c62997041c134b03ca82731ce2f6fd2cae1eb9/Sources/WhisperKit/Core/WhisperKit.swift) and [tokenizer selection](https://github.com/argmaxinc/argmax-oss-swift/blob/25c62997041c134b03ca82731ce2f6fd2cae1eb9/Sources/WhisperKit/Utilities/ModelUtilities.swift).

### 5. The 8 GB memory claim is not established, and current object lifetimes compound peak use

`1.6 GB fp16` is a download/on-disk figure, not peak resident memory or first-load Core ML specialization memory. The current method keeps the WhisperKit instance alive while it creates and loads SpeakerKit and materializes the entire recording as `[Float]` (`EmbeddedTranscriber.swift:109-145`). A BSC large-v3 model, SpeakerKit, Core ML compilation/specialization, result arrays, and a long meeting can therefore overlap. “Per-call lifetime” prevents permanent retention but does not reduce this peak.

The spec also contradicts itself: the router “never returns a model the Mac cannot run”, but an automatic Catalan detection on an 8 GB Mac returns a 1.6 GB BSC model merely because the design says it “fits”. WhisperKit itself documents `prewarm` as the mechanism for reducing first-load peak, yet current Distavo does not enable it.

**Recommendation:** make BSC-on-8-GB a measured gate, not a design assertion. Explicitly release/unload the detector and transcription model before loading SpeakerKit where SDK/result ownership permits; evaluate `prewarm: true`; and measure peak RSS, memory pressure, swap, cold specialization time, warm time and completion on physical 8 GB and 16 GB Apple Silicon Macs using both a short file and the 64-minute meeting with diarization on/off. If 8 GB shows pressure/termination, do not offer or auto-route BSC there; keep `small`/server and explain the limitation. Derive catalog `ramGB` from measurements.

### 6. Parakeet-to-SpeakerKit alignment is possible, but the proposed algorithm is not parity with today's path

SpeakerKit currently returns `DiarizationResult.segments`; Distavo then calls SpeakerKit's `addSpeakerInfo(..., strategy: .subsegment)` (`EmbeddedTranscriber.swift:140-145`). That implementation groups Whisper words and selects the speaker turn with greatest intersection, carrying the previous speaker when no match exists. The proposed midpoint/nearest-turn algorithm is different. It always attributes an unmatched word to somebody, has no maximum-gap tolerance, and does not define ties when diarization turns overlap. Those cases are common around crosstalk and silence and can misattribute decisions/action items.

FluidAudio `v0.15.6` already exposes token timings and `buildWordTimings(from:)`; the adapter should preserve those word boundaries and spaces rather than inventing another token aggregation contract.

**Recommendation:** add an explicit DistavoEmbedded adapter from `DiarizationResult.segments` and FluidAudio `WordTiming` into dependency-free core structs. Define deterministic maximum-overlap assignment, an overlap tie rule, and an `unknown` result beyond a small configurable gap instead of unbounded nearest-turn attribution. If exact Whisper-path parity is required, port SpeakerKit's intersection/previous-speaker behavior and lock it down with shared contract tests. Include crosstalk, boundary-straddling words, leading/trailing gaps, long internal gaps, nil/empty timings, out-of-order timings, and punctuation/spacing cases.

## Medium severity

### 7. Config migration is plausible but the current test plan is too narrow to guarantee identical old behavior

Adding a defaulted `preferred_catalan_model` field through `decodeIfPresent` and setting `auto` only in `recommendedForThisMac()` can preserve old files: existing files decode through `Config.init(from:)`, while the recommended factory is used only when no file exists (`Config.swift:59-96,214-239`). Existing server users can therefore remain server users, and existing embedded users can retain `large-v3-turbo`/`small` plus their explicit language.

Plain strings alone do not prove behavioral compatibility. The router must distinguish the new literal `"auto"` from old empty, unknown or nonstandard language/model values. Current unknown embedded model IDs fall back to `large-v3-turbo`, and Settings deliberately keeps unknown language values visible (`EmbeddedSupport.swift:47-50`; `SettingsView.swift:28-38`). A broad “missing/invalid means automatic” normalization would silently change old behavior. Settings also currently calls catalog lookup directly for its RAM label; `"auto"` would fall through to the default unless the UI uses the router/recommendation deliberately.

**Recommendation:** add golden JSON fixtures representing pre-embedded, current server, current 8 GB embedded, current 16 GB embedded, empty-language, and unknown-value configs. Assert both decoded values and actual dispatch/model/language behavior before and after save/reload. Only a genuinely missing config gets `model=auto, language=auto`; missing newly added fields in an existing config must retain historical defaults. Define validation/fallback for an invalid `preferred_catalan_model` and ensure a saved old config is not rewritten into automatic behavior.

### 8. Sandbox storage/network access is feasible, but release verification and user-facing download semantics are incomplete

The App Store target already has App Sandbox, outgoing-network, and user-selected file entitlements. `FileManager.applicationSupportDirectory` is writable inside the sandbox container, so a `models/parakeet` subdirectory under the existing Distavo model root needs no new entitlement. Direct/Setapp and App Store editions will naturally have different physical container locations and will not share downloads. Downloading model data is not the same as downloading executable plug-in code, but the final artifacts must contain model data only.

Risks remain: Hugging Face downloads can involve redirects/CDN hosts; tokenizer fallback adds repositories; interrupted multi-gigabyte downloads need atomic/resumable handling and free-space checks; and “Remove downloaded models” can race an active transcription/download. The existing model-store state is only “any allocated bytes exist”, so one partial or unrelated model makes every later model look like a load rather than a first download (`EmbeddedTranscriber.swift:43-54,95-100`). The current Settings statement that deleting one folder removes “everything” is also too absolute because Core ML maintains specialization caches outside the app-managed folder.

**Recommendation:** retain one app-owned root but track readiness/size per engine and model with staging plus atomic promotion. Disable or cancel-and-await removal while an engine uses the directory. Add disk-space, cancellation, corruption and resume behavior to the design. Exercise a signed sandboxed App Store build downloading each engine, relaunching offline, removing models, and redownloading; inspect network destinations and the final archive. Update the copy to distinguish app-managed downloads from OS-managed Core ML caches. Apple's container model is documented in [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox).

### 9. Progress ownership and prefetch scope need an explicit concurrency design

The app currently wires progress only to `EmbeddedTranscriber.shared` and the summariser (`WatcherController.swift:112-125`). Separate detector and Parakeet actors will not automatically use that handler. “Download now” also introduces Settings-triggered model work that can overlap the watcher's scan, model removal, or another download. Automatic prefetch downloads detector + Parakeet + preferred BSC (roughly 2.1 GB before cache overhead), which is surprising unless the UI states the total and supports cancellation.

**Recommendation:** specify one model-download/engine coordinator actor shared by Settings and pipeline dispatch. It should serialize per-model work, coalesce duplicate requests, expose structured progress/cancellation, and arbitrate removal. Display the aggregate estimated and actual disk requirement before automatic prefetch; do not overload the current single transcriber callback.

## Test-plan additions required before tagging

- A retry-durability test across two scans: offline detector/model download first, successful retry second, with no `.failed` or stale `.processing` marker.
- Clean-resolution and compile tests at the exact FluidAudio/Argmax pins, including `swift package show-traits`; API compile tests for decoder state, typed language hints, token-to-word timings and cleanup.
- Real converted-artifact tests for both BSC models: cold download/load, tokenizer selection, offline warm reload, timestamps, diarization, corrupt/partial cache and immutable manifest/hash rejection.
- Router bake-offs with the same languages in different orders, multiple switches, leading silence/music, short audio, dominant/minority Catalan and detector confidence near the threshold. Record the chosen engine as a test artifact.
- Alignment fixtures for overlap/crosstalk, equal-overlap ties, a word crossing a turn boundary, long/no turn gaps, non-monotonic or empty timings, abbreviations and Unicode sentence punctuation.
- Peak-memory and memory-pressure measurements on physical 8 GB and 16 GB Macs, cold and warm, with long audio and diarization enabled; disk-free-space and first-load specialization measurements.
- Golden migration tests that assert end-to-end dispatch for old JSON, not only Codable round trips; include unknown and empty values and Settings save/reload.
- Signed App Store sandbox runtime tests for every download/remove/relaunch path and an archive scan for unexpected frameworks, static libraries, executables, privacy manifests and notices.
- Correct edition builds. The current CI loop labels three builds but always invokes `-scheme Distavo` (`.github/workflows/ci.yml:29-38`); it should invoke `Distavo`, `Distavo-AppStore`, and `Distavo-Setapp` so target dependencies and edition compliance are genuinely tested.
- Download cancellation, app quit/relaunch, concurrent automatic scan versus “Download now”, remove-during-use, HTTP redirect/failure, insufficient disk and model-repository outage tests.

## Verdict

**Rework.** The overall engine strategy is feasible and worth pursuing, but the spec should not retain “approved design” status until it adds a real transcription-deferral contract, pins and verifies a FluidAudio packaging/API shape that meets the no-binary claim, replaces first-window single-language routing with a measured mixture-aware policy, and turns the 8 GB/BSC claim into a hardware-tested gate. The custom WhisperKit and Parakeet alignment portions can then proceed as implementation spikes, with signed App Store download validation and golden config migration tests as release gates.
