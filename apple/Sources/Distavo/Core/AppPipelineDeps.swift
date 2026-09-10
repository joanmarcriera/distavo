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
        deps.transcribe = { wavURL, transcribeConfig in
            guard transcribeConfig.backend == "embedded" else {
                return try await serverTranscribe(wavURL, transcribeConfig)
            }
            // Spec §5.2/§5.9: detect only when both model and language are
            // automatic, route in DistavoCore, then dispatch on the engine.
            // The "Using …" engine line is shown whenever the MODEL is
            // automatic (even with a fixed language, so the user still sees
            // which engine the router picked). Retryable conditions surface
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
                } catch let retry as RetryableDependencyError {
                    throw retry
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    await ModelCoordinator.shared.report(
                        "Language detection failed (\(message)) — using the default engine")
                }
            }
            let decision = EngineRouter.choose(
                detections: detections, config: transcribeConfig,
                memoryBytes: HardwareProbe.physicalMemoryBytes)
            if let note = decision.note { await ModelCoordinator.shared.report(note) }
            if EmbeddedModelCatalog.isAutomatic(transcribeConfig.embeddedModel) {
                await ModelCoordinator.shared.report(
                    "Using \(decision.model.displayName)" + (decision.languageHint.map { " (\($0))" } ?? ""))
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
            if needsDetection {
                result["detections"] = detections.map { ["code": $0.code, "probability": Double($0.probability)] }
            }
            return result
        }

        // The target is chosen by Pipeline.chooseSummariser, which only returns
        // .embedded when summarise.embeddedEnabled is on (Vikunja #336).
        let ollamaSummarise = deps.summarise
        deps.summarise = { transcript, target, options, owner, speaker in
            if case .embedded = target {
                return try await EmbeddedSummariser.summarise(
                    transcript: transcript, noteOwner: owner, userSpeaker: speaker)
            }
            return try await ollamaSummarise(transcript, target, options, owner, speaker)
        }

        // Readiness of the on-device summariser, so chooseSummariser can DEFER a
        // recording (rather than fail it permanently) when Apple Intelligence is
        // merely still downloading or switched off — the on-device analogue of
        // "Ollama server offline". Conditions that can never resolve on this Mac
        // stay failures, pointing the user back at Ollama.
        deps.embeddedReadiness = {
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
