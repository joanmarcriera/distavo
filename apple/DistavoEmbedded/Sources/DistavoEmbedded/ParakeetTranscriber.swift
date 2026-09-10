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

    /// FluidAudio's typed hint for a Whisper code; nil when Parakeet has no such
    /// language (including the router's "auto" sentinel, which isn't a real
    /// `Language` rawValue and so falls through here harmlessly).
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
                await coordinator.beginDownload(id: model.id)
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
                let asr = AsrManager(config: .default, models: models)
                await coordinator.report("Transcribing on this Mac…")
                var state = TdtDecoderState.make()
                // Nested do/catch so `asr.cleanup()` (releases the model refs)
                // runs whether transcription succeeds or throws — the model
                // must not outlive this call on either path.
                do {
                    let result = try await asr.transcribe(wavURL, decoderState: &state,
                                                          language: Self.fluidLanguage(languageHint))
                    await asr.cleanup()
                    words = Self.timedWords(buildWordTimings(from: result.tokenTimings ?? []))
                } catch {
                    await asr.cleanup()
                    throw error
                }
            } catch {
                // Reset the in-flight download/progress marker on the failure
                // path too, or a failed download leaves the model stuck
                // "downloading" in the UI forever.
                await coordinator.noteDownload(id: model.id, fraction: nil)
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
