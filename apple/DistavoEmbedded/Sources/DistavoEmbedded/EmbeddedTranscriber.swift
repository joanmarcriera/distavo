import Foundation
import WhisperKit
import SpeakerKit
import FluidAudio
import DistavoCore

public enum EmbeddedTranscriberError: LocalizedError {
    case unsupportedHardware
    case emptyResult
    /// A model could not be loaded. `offline` is carried separately because
    /// WhisperKit's own message leads with "Model not found. Please check the
    /// model or repo name" even when the real cause was no internet connection,
    /// which sends the user to re-pick a model that was never the problem.
    case modelUnavailable(model: String, offline: Bool, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedHardware:
            return "Built-in transcription needs an Apple Silicon Mac — switch the "
                + "transcription engine to a WhisperX server in Settings."
        case .emptyResult:
            return "Built-in transcription produced no text."
        case let .modelUnavailable(model, offline, underlying):
            if offline {
                return "No internet connection, so the \(model) model could not be "
                    + "downloaded. Distavo only needs the network for this one-time "
                    + "download — reconnect and it will retry automatically. "
                    + "(\(underlying))"
            }
            return "Could not load the \(model) model: \(underlying)"
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
        let whisper: WhisperKit
        do {
            whisper = try await WhisperKit(whisperConfig)
        } catch {
            throw Self.pipelineError(error, model: model.displayName)
        }

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
        let speakerKit: SpeakerKit
        do {
            speakerKit = try await SpeakerKit(speakerConfig)
        } catch {
            throw Self.pipelineError(error, model: "speaker identification")
        }
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: wavURL.path)
        let diarization = try await speakerKit.diarize(
            audioArray: audio,
            options: PyannoteDiarizationOptions(numberOfSpeakers: config.numSpeakers))
        let groups = diarization.addSpeakerInfo(to: results, strategy: .subsegment)
        return EmbeddedResultMapper.whisperXDictionary(speakerGroups: groups)
    }

    /// Classify a model load/download failure so the surfaced message names the
    /// real cause rather than repeating the SDK's misleading primary message.
    static func modelError(_ error: Error, model: String) -> EmbeddedTranscriberError {
        .modelUnavailable(model: model,
                          offline: NetworkScope.describesOfflineFailure(error),
                          underlying: (error as? LocalizedError)?.errorDescription
                              ?? error.localizedDescription)
    }

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
}
