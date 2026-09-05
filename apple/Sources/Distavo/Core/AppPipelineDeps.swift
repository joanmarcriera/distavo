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
            if transcribeConfig.backend == "embedded" {
                return try await EmbeddedTranscriber.shared.transcribe(
                    wavURL: wavURL, config: transcribeConfig)
            }
            return try await serverTranscribe(wavURL, transcribeConfig)
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

        return deps
    }
}
