import Foundation
import WhisperKit
import SpeakerKit
import DistavoCore

public enum EmbeddedTranscriberError: LocalizedError {
    case unsupportedHardware
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .unsupportedHardware:
            return "Built-in transcription needs an Apple Silicon Mac — switch the "
                + "transcription engine to a WhisperX server in Settings."
        case .emptyResult:
            return "Built-in transcription produced no text."
        }
    }
}

/// Where downloaded models live and how to clean them up. Everything the
/// embedded engine stores on disk is under this one folder — "Remove downloaded
/// models" in Settings deletes it and nothing else remains anywhere.
public enum EmbeddedModelStore {
    public static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Distavo/models", isDirectory: true)
    }

    public static func hasDownloadedModels() -> Bool { diskUsageBytes() > 0 }

    public static func diskUsageBytes() -> Int64 {
        guard let files = FileManager.default.enumerator(
            at: modelsDirectory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [], errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                .totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    public static func diskUsageLabel() -> String {
        ByteCountFormatter.string(fromByteCount: diskUsageBytes(), countStyle: .file)
    }

    public static func removeAll() throws {
        let dir = modelsDirectory
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}

/// On-device implementation of the pipeline's `transcribe` dependency:
/// WhisperKit (CoreML Whisper) + SpeakerKit (pyannote diarization), returning
/// the same `[String: Any]` WhisperX shape as `WhisperXClient.transcribe`.
///
/// Engines are created per call and released afterwards on purpose: Distavo is
/// a background menu-bar app and must not hold ~1–2 GB of model RAM between
/// meetings. Model *files* persist in `EmbeddedModelStore.modelsDirectory`, so
/// only the first call downloads; later calls just reload from disk (seconds).
public actor EmbeddedTranscriber {
    public static let shared = EmbeddedTranscriber()

    private var progressHandler: (@Sendable (String) -> Void)?

    public init() {}

    /// Status line sink (menu-bar status + activity log in the app).
    public func setProgressHandler(_ handler: (@Sendable (String) -> Void)?) {
        progressHandler = handler
    }

    private func report(_ message: String) { progressHandler?(message) }

    public func transcribe(wavURL: URL, config: TranscribeConfig) async throws -> [String: Any] {
        guard HardwareProbe.supportsEmbeddedTranscription else {
            throw EmbeddedTranscriberError.unsupportedHardware
        }
        let model = EmbeddedModelCatalog.model(id: config.embeddedModel)
        let firstRun = !EmbeddedModelStore.hasDownloadedModels()
        if firstRun {
            report("Downloading \(model.displayName) — \(model.downloadLabel), one-time…")
        } else {
            report("Loading \(model.displayName)…")
        }

        let whisperConfig = WhisperKitConfig(
            model: model.whisperKitName,
            downloadBase: EmbeddedModelStore.modelsDirectory,
            verbose: false,
            load: true,
            download: true)
        let whisper = try await WhisperKit(whisperConfig)

        report("Transcribing on this Mac…")
        var options = DecodingOptions()
        options.language = config.language.isEmpty ? nil : config.language
        // Word timings are what SpeakerKit aligns speaker labels to.
        options.wordTimestamps = true
        options.chunkingStrategy = .vad
        let results = try await whisper.transcribe(audioPath: wavURL.path, decodeOptions: options)

        guard config.diarize else {
            return EmbeddedResultMapper.whisperXDictionary(segments: results.flatMap(\.segments))
        }

        report("Identifying speakers…")
        let speakerConfig = PyannoteConfig(
            downloadBase: EmbeddedModelStore.modelsDirectory.path,
            download: true,
            load: true,
            verbose: false)
        let speakerKit = try await SpeakerKit(speakerConfig)
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: wavURL.path)
        let diarization = try await speakerKit.diarize(
            audioArray: audio,
            options: PyannoteDiarizationOptions(numberOfSpeakers: config.numSpeakers))
        let groups = diarization.addSpeakerInfo(to: results, strategy: .subsegment)
        return EmbeddedResultMapper.whisperXDictionary(speakerGroups: groups)
    }
}
