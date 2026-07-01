import Foundation
import DistavoCore
import DistavoEmbedded

extension PipelineDeps {
    /// The app's live dependencies: `PipelineDeps.live()` with the transcribe
    /// step routed per config — the built-in WhisperKit engine when
    /// `transcribe.backend == "embedded"`, otherwise the WhisperX server
    /// client. Routing lives here (not in DistavoCore) so the core package
    /// stays dependency-free.
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
        return deps
    }
}
