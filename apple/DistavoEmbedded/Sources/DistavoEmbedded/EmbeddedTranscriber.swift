import Foundation
import WhisperKit
import SpeakerKit
// Both SpeakerKit and FluidAudio declare a `DiarizationResult` type; this
// specific-symbol import resolves the unqualified name to SpeakerKit's (the
// one `SpeakerKit.diarize(...)` actually returns) without needing
// `SpeakerKit.DiarizationResult`, which the compiler reads as a member of the
// `SpeakerKit` class rather than the module.
import struct SpeakerKit.DiarizationResult
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
    /// The router chose a model this engine cannot run (a Parakeet entry reached
    /// the WhisperKit transcriber). Permanent: the dispatch is wrong, not the network.
    case wrongEngine(model: String)

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
        case let .wrongEngine(model):
            return "\(model) is not a Whisper model — choose a Whisper model in Settings, or Automatic."
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

    public static func freeSpaceBytes() -> Int64 { freeSpaceBytes(at: modelsDirectory) }

    /// Free space on the volume holding `url`, walking up to the nearest
    /// existing ancestor first — `resourceValues` throws (Cocoa error 260) on a
    /// path that doesn't exist yet, e.g. before Distavo has ever downloaded a
    /// model, which would otherwise collapse "not created yet" into "0 bytes
    /// free" and make `ensureFreeSpace` reject downloads on a fresh install.
    public static func freeSpaceBytes(at url: URL) -> Int64 {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path != "/" {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
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
        guard model.engine == .whisperKit else {
            throw EmbeddedTranscriberError.wrongEngine(model: model.displayName)
        }
        let coordinator = ModelCoordinator.shared
        return try await coordinator.withExclusiveAccess {
            let firstRun = !EmbeddedModelStore.isDownloaded(model)
            if firstRun {
                try coordinator.ensureFreeSpace(forMB: model.downloadMB)
                await coordinator.beginDownload(id: model.id)
                await self.report("Downloading \(model.displayName) — \(model.downloadLabel), one-time…")
            } else {
                await self.report("Loading \(model.displayName)…")
            }

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
                if firstRun, model.whisperKitRepo != nil {
                    // Verified once, right after the download; a later
                    // on-disk corruption is caught by WhisperKit's own load
                    // failure.
                    try Self.verifyManifest(model: model)
                }
                await self.report("Transcribing on this Mac…")
                var options = DecodingOptions()
                options.language = languageHint
                options.wordTimestamps = true
                options.chunkingStrategy = .vad
                results = try await whisper.transcribe(audioPath: wavURL.path, decodeOptions: options)
                // `whisper` goes out of scope here: the 1–4 GB model is released
                // before SpeakerKit loads (spec §6 peak-memory rule).
                await coordinator.noteDownload(id: model.id, fraction: nil)
            } catch let retry as RetryableDependencyError {
                // A manifest mismatch (see `verifyManifest` above) is already
                // the right shape for the pipeline — don't let `pipelineError`
                // reclassify it as a permanent failure below.
                await coordinator.noteDownload(id: model.id, fraction: nil)
                throw retry
            } catch {
                await coordinator.noteDownload(id: model.id, fraction: nil)
                throw Self.pipelineError(error, model: model.displayName)
            }

            guard config.diarize else {
                return EmbeddedResultMapper.whisperXDictionary(segments: results.flatMap(\.segments))
            }
            await self.report("Identifying speakers…")
            let groups = try await Self.diarize(wavURL: wavURL, results: results, numSpeakers: config.numSpeakers)
            return EmbeddedResultMapper.whisperXDictionary(speakerGroups: groups)
        }
    }

    /// Loads SpeakerKit and runs diarisation — the shared setup for both
    /// `diarize` (WhisperKit result alignment) and `speakerTurns` (Parakeet).
    private static func loadDiarization(wavURL: URL, numSpeakers: Int) async throws -> DiarizationResult {
        let speakerConfig = PyannoteConfig(
            downloadBase: EmbeddedModelStore.modelsDirectory.path,
            download: true, load: true, verbose: false)
        let speakerKit: SpeakerKit
        do { speakerKit = try await SpeakerKit(speakerConfig) }
        catch { throw pipelineError(error, model: "speaker identification") }
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: wavURL.path)
        return try await speakerKit.diarize(
            audioArray: audio, options: PyannoteDiarizationOptions(numberOfSpeakers: numSpeakers))
    }

    /// SpeakerKit diarisation of a WhisperKit result (shared with the detector-free path).
    static func diarize(wavURL: URL, results: [TranscriptionResult], numSpeakers: Int) async throws -> [[SpeakerSegment]] {
        let diarization = try await loadDiarization(wavURL: wavURL, numSpeakers: numSpeakers)
        return diarization.addSpeakerInfo(to: results, strategy: .subsegment)
    }

    /// SpeakerKit turns for an engine that brings its own words (Parakeet).
    static func speakerTurns(wavURL: URL, numSpeakers: Int) async throws -> [SpeakerTurn] {
        let diarization = try await loadDiarization(wavURL: wavURL, numSpeakers: numSpeakers)
        return diarization.segments.compactMap { seg in
            guard let id = seg.speaker.speakerId else { return nil }
            return SpeakerTurn(speaker: id, start: Double(seg.startTime), end: Double(seg.endTime))
        }
    }

    /// Verifies a just-loaded custom-repo model's folder against its
    /// `manifest.json` (spec §5.6, §7). Called only when `model.whisperKitRepo
    /// != nil` — Argmax's own repo has no manifest, so this never runs for the
    /// built-in Whisper models. On any mismatch, removes the *one* variant
    /// folder (never anything above it) so the next attempt re-downloads from
    /// scratch, and reports it as a retryable, not permanent, failure.
    static func verifyManifest(model: EmbeddedModel) throws {
        let dir = EmbeddedModelStore.whisperKitDirectory(repo: model.whisperKitRepo, variant: model.whisperKitName)
        do {
            try ModelManifestCheck.verify(folder: dir)
        } catch {
            do {
                try FileManager.default.removeItem(at: dir)
            } catch let removeError {
                // Swallowing this would leave the same corrupt folder in
                // place to be re-verified (and fail again) on every future
                // load — surface it instead so the user can clear it by hand.
                throw RetryableDependencyError(
                    "The \(model.displayName) download was incomplete and Distavo could not "
                        + "remove it (\(removeError.localizedDescription)) — remove downloaded "
                        + "models in Settings and it will download again.")
            }
            throw RetryableDependencyError(
                "The \(model.displayName) download was incomplete — Distavo will download it again.")
        }
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
