import XCTest
import Darwin
import WhisperKit
@testable import DistavoEmbedded
import DistavoCore

/// Memory-growth guard for Vikunja #4019 (Distavo at 9.6 GB after three days).
///
/// Processes the same SYNTHETIC clip (made with `say`, never a real recording) N times in one process
/// through the real built-in engines (language detector, WhisperKit, SpeakerKit) and checks that the
/// process footprint after the last run is within `DISTAVO_SOAK_LIMIT_MB` (default 300) of the
/// footprint after run 2. Needs the models already downloaded; skipped unless `DISTAVO_SOAK=1`.
///
///   say -o "$TMPDIR/soak.aiff" -f text.txt
///   afconvert -f WAVE -d LEI16@16000 "$TMPDIR/soak.aiff" "$TMPDIR/soak.wav"
///   DISTAVO_SOAK=1 DISTAVO_SOAK_AUDIO="$TMPDIR/soak.wav" swift test --filter ModelUnloadSoakTests
///
/// Optional: `DISTAVO_SOAK_RUNS` (default 10), `DISTAVO_SOAK_MODEL` (catalog id, default the turbo model),
/// `DISTAVO_SOAK_STEPS` = `full` (default: detector + WhisperKit + SpeakerKit), `detect` (detector only),
/// `whisper` (WhisperKit without diarisation), `diarize` (SpeakerKit only), `load` (WhisperKit load + unload,
/// no audio), `gpuload` (the same with the production GPU text decoder), `decode` (one WhisperKit kept loaded,
/// transcribe only), `holes` (kept model, transcribe + `HoleRecovery`), `loaddecode` (a fresh model per run,
/// one transcribe, unload: what production does), to find which step grows.
/// Prints only metrics (footprint, load time per run), never transcript text.
final class ModelUnloadSoakTests: XCTestCase {
    /// `phys_footprint` of this process in MB: the number Activity Monitor and `footprint` report.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }

    func testFootprintStaysFlatOverRepeatedRuns() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DISTAVO_SOAK"] == "1" else { throw XCTSkip("set DISTAVO_SOAK=1 to run the model-unload soak") }
        guard let audioPath = env["DISTAVO_SOAK_AUDIO"], FileManager.default.fileExists(atPath: audioPath) else {
            return XCTFail("DISTAVO_SOAK_AUDIO must name a synthetic WAV")
        }
        let runs = max(3, Int(env["DISTAVO_SOAK_RUNS"] ?? "") ?? 10)
        let limit = Double(env["DISTAVO_SOAK_LIMIT_MB"] ?? "") ?? 300
        let model = EmbeddedModelCatalog.model(id: env["DISTAVO_SOAK_MODEL"] ?? EmbeddedModelCatalog.defaultModelID)
        guard EmbeddedModelStore.isDownloaded(model), EmbeddedModelStore.isDetectorDownloaded() else {
            throw XCTSkip("models not downloaded on this Mac: not measured")
        }
        let wav = URL(fileURLWithPath: audioPath)
        let steps = env["DISTAVO_SOAK_STEPS"] ?? "full"
        var config = TranscribeConfig()
        config.diarize = steps != "whisper"

        // `gpuload` / `holes` use the production compute options (text decoder on the GPU, #2158).
        let gpu = steps == "gpuload" || steps == "holes" || steps == "loaddecode"
        let whisperConfig = WhisperKitConfig(model: model.whisperKitName, downloadBase: EmbeddedModelStore.modelsDirectory,
                                             modelRepo: model.whisperKitRepo,
                                             computeOptions: gpu ? ModelComputeOptions(textDecoderCompute: .cpuAndGPU) : nil,
                                             verbose: false, load: true, download: true)
        let kept: WhisperKit? = (steps == "decode" || steps == "holes") ? try await WhisperKit(whisperConfig) : nil
        var footprints: [Double] = []
        for run in 1...runs {
            let started = Date()
            if steps == "full" || steps == "detect" {
                _ = try await LanguageDetector.shared.detect(wavURL: wav)
            }
            if steps == "full" || steps == "whisper" {
                _ = try await EmbeddedTranscriber.shared.transcribe(
                    wavURL: wav, model: model, languageHint: "en", config: config)
            }
            if steps == "holes", let kept {
                let options = DecodingOptions(language: "en")
                let first = try await kept.transcribe(audioPath: wav.path, decodeOptions: options)
                let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: wav.path)
                _ = await HoleRecovery.recover(whisper: kept, audio: audio, results: first, options: options, report: { _ in })
            }
            if steps == "loaddecode" {
                let w = try await WhisperKit(whisperConfig)
                _ = try await w.transcribe(audioPath: wav.path, decodeOptions: DecodingOptions(language: "en"))
                await w.unloadModels()
            }
            if steps == "load" || steps == "gpuload" {
                let w = try await WhisperKit(whisperConfig)
                await w.unloadModels()
            }
            if steps == "decode", let kept {
                _ = try await kept.transcribe(audioPath: wav.path, decodeOptions: DecodingOptions(language: "en"))
            }
            if steps == "diarize" {
                _ = try await EmbeddedTranscriber.speakerTurns(wavURL: wav, numSpeakers: 0)
            }
            let seconds = Date().timeIntervalSince(started)
            let mb = Self.footprintMB()
            footprints.append(mb)
            print(String(format: "SOAK[\(steps)] run %d: footprint %.0f MB, detect+transcribe+diarise %.1f s", run, mb, seconds))
        }
        let growth = footprints[runs - 1] - footprints[1]
        print(String(format: "SOAK growth run 2 -> run %d: %.0f MB (limit %.0f MB)", runs, growth, limit))
        XCTAssertLessThanOrEqual(growth, limit, "footprint grew \(Int(growth)) MB between run 2 and run \(runs)")
    }
}
