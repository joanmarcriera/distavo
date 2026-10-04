import Foundation
import DistavoCore
import DistavoEmbedded

extension PipelineDeps {
    /// The app's live dependencies: `PipelineDeps.live()` with the transcribe
    /// and summarise steps routed per config — the built-in WhisperKit engine
    /// when `transcribe.backend == "embedded"`, and Apple Foundation Models
    /// when the pipeline picks `.embedded` as the summarise target; otherwise
    /// the WhisperX / Ollama server clients. Routing lives here (not in
    /// DistavoCore) so the core package stays dependency-free.
    static func appLive() -> PipelineDeps {
        var deps = PipelineDeps.live()

        let serverTranscribe = deps.transcribe
        deps.transcribe = { wavURL, rawTranscribeConfig in
            // Vikunja #2202: an explicit language the owner confirmed after
            // Stop overrides auto-detection — read before anything else, for
            // both backends (a fixed language is meaningful to the WhisperX
            // server too). `LanguageOverride.applying` only touches an
            // Automatic `language`, so a variant that already fixed its own
            // language (e.g. the #2205 retry-bigger action) is left alone,
            // and it strips a variant's `@<suffix>` itself to find the
            // plain recording's sidecar — pure DistavoCore logic, unit
            // tested in LanguageOverrideTests.
            let workDir = wavURL.deletingLastPathComponent()
            let wavBase = wavURL.deletingPathExtension().lastPathComponent
            let transcribeConfig = LanguageOverride.applying(to: rawTranscribeConfig, workDir: workDir, wavBase: wavBase)
            guard transcribeConfig.backend == "embedded" else {
                return try await serverTranscribe(wavURL, transcribeConfig)
            }
            // Spec §5.2/§5.9: detect whenever the language is automatic (also
            // with a pinned model, #2667), route in DistavoCore, then dispatch
            // on the engine. The "Using …" line is always shown, so the user
            // sees the engine and language the router picked. Retryable conditions surface
            // as RetryableDependencyError and defer.
            // I4: the detector is not the router — losing it must not fail the
            // whole recording. A RetryableDependencyError (offline detector
            // download, busy folder) still propagates and defers like any
            // other dependency failure; anything else (a corrupt detector
            // model, an unreadable WAV) is reported and swallowed so routing
            // falls through with no detections (rule 6: turbo/small), rather
            // than the recording ending up permanently failed over a detector
            // that was never load-bearing for correctness. No unit test here —
            // this closure only exists in the app target, which has no
            // DistavoEmbedded-free seam to fake the detector through; the
            // behaviour is exercised by EngineRouterTests (empty detections ->
            // rule 6) and EmbeddedTranscriberErrorTests (offline -> retryable).
            let needsDetection = EngineRouter.needsDetection(transcribeConfig)
            var detections: [LanguageDetection] = []
            if needsDetection {
                do {
                    detections = try await LanguageDetector.shared.detect(wavURL: wavURL)
                } catch let retry as RetryableDependencyError where EngineRouter.deferOnDetectorOutage(transcribeConfig) {
                    // Automatic model: no detection means no routing, so defer.
                    throw retry
                } catch {
                    // With a pinned model the detector is advisory (#2667): even an
                    // offline detector must not defer; the model detects itself.
                    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    let fallbackText = EngineRouter.deferOnDetectorOutage(transcribeConfig)
                        ? "using the default engine"
                        : "\(EmbeddedModelCatalog.model(id: transcribeConfig.embeddedModel).displayName) will detect the language itself"
                    await ModelCoordinator.shared.report(
                        "Language detection failed (\(message)) — \(fallbackText)")
                }
            }
            let decision = EngineRouter.choose(
                detections: detections, config: transcribeConfig,
                memoryBytes: HardwareProbe.physicalMemoryBytes)
            if let note = decision.note { await ModelCoordinator.shared.report(note) }
            // Always report the engine + language line (also for a pinned model),
            // plus the recommendation when the router has one (#2667).
            await ModelCoordinator.shared.report(decision.logLine)
            await ModelCoordinator.shared.report(
                EngineRouter.traceLine(config: transcribeConfig, detections: detections, decision: decision))
            if let recommendation = decision.recommendation {
                await ModelCoordinator.shared.report(recommendation)
            }
            var result: [String: Any]
            switch decision.model.engine {
            case .parakeet:
                result = try await ParakeetTranscriber.shared.transcribe(
                    wavURL: wavURL, languageHint: decision.languageHint, config: transcribeConfig)
            case .whisperKit:
                result = try await EmbeddedTranscriber.shared.transcribe(
                    wavURL: wavURL, model: decision.model,
                    languageHint: decision.languageHint, config: transcribeConfig)
            }
            // Provenance footer (Vikunja): tell the note which engine
            // transcribed it and, when the router ran the detector, what
            // language(s) it found. The server (WhisperX) path never sets
            // these, so it never gets a footer.
            result["engine"] = decision.model.displayName
            result["language_used"] = NoteProvenance.languageUsed(decision)
            if let recommendation = decision.recommendation { result["recommendation"] = recommendation }
            if needsDetection {
                result["detections"] = detections.map { ["code": $0.code, "probability": Double($0.probability)] }
            }
            return result
        }

        // The target is chosen by Pipeline.chooseSummariser, which only returns
        // .embedded when summarise.embeddedEnabled is on (Vikunja #336).
        let ollamaSummarise = deps.summarise
        deps.summarise = { transcript, target, options, context in
            if case .embedded(let model) = target {
                // Only Apple's model has an engine until the MLX generator lands
                // (Vikunja #2198 S4-S6); readiness below already refuses the rest.
                guard model == EmbeddedSummaryModelCatalog.appleID else {
                    throw EmbeddedSummariserError.failed("the \(model) summary model is not available in this build")
                }
                // Always the classic prompt on-device: the 4096-token window
                // cannot afford the facts-first template (Vikunja #2063).
                return try await EmbeddedSummariser.summarise(
                    transcript: transcript, noteOwner: context.noteOwner,
                    userSpeaker: context.userSpeaker, participants: context.participants)
            }
            return try await ollamaSummarise(transcript, target, options, context)
        }

        // Readiness of the on-device summariser, so chooseSummariser can DEFER a
        // recording (rather than fail it permanently) when Apple Intelligence is
        // merely still downloading or switched off — the on-device analogue of
        // "Ollama server offline". Conditions that can never resolve on this Mac
        // stay failures, pointing the user back at Ollama.
        deps.embeddedReadiness = { model in
            guard model == EmbeddedSummaryModelCatalog.appleID else {
                // No generator for downloaded models yet (S4-S6): can never
                // resolve on this build, so fail once rather than defer forever.
                return .unsupported("The \(model) summary model isn't available in this version — switch back to Apple Intelligence or Ollama in Settings.")
            }
            guard let reason = EmbeddedSummariser.unavailableReason() else { return .ready }
            let why = reason.errorDescription ?? "On-device summarisation is unavailable."
            switch reason {
            case .modelNotReady, .appleIntelligenceNotEnabled:
                return .temporarilyUnavailable(why)
            default:
                return .unsupported(why)
            }
        }

        return deps
    }
}
