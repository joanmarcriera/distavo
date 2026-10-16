import XCTest
import AVFoundation
import WhisperKit
@testable import DistavoEmbedded
import DistavoCore

/// Live check of the second pass over dropped speech (Vikunja #3579): cut clips out of a real recording,
/// pretend the first pass returned NOTHING for them, and see what `HoleRecovery.recover`
/// gets back from the real model. Clips that hold speech must come back with words; a clip of silence
/// must come back empty.
///
///   DISTAVO_HOLES_LIVE=1 DISTAVO_HOLES_AUDIO=/abs/16k.wav DISTAVO_HOLES_CLIPS="0-60,2200-2290" \
///   DISTAVO_HOLES_MODEL=bsc-ca-3370h DISTAVO_HOLES_LANGUAGE=ca \
///   swift test --filter HoleRecoveryLiveTests
///
/// **Privacy:** prints only numbers (holes found, segments, words), never text.
final class HoleRecoveryLiveTests: XCTestCase {

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    func testRecoversSpeechFromClipsTheFirstPassDidNotReturn() async throws {
        try XCTSkipUnless(env["DISTAVO_HOLES_LIVE"] == "1", "set DISTAVO_HOLES_LIVE=1")
        guard let audioPath = env["DISTAVO_HOLES_AUDIO"] else { XCTFail("set DISTAVO_HOLES_AUDIO"); return }
        let clips: [(Double, Double)] = (env["DISTAVO_HOLES_CLIPS"] ?? "0-60").split(separator: ",").compactMap {
            let p = $0.split(separator: "-").compactMap { Double($0) }
            return p.count == 2 ? (p[0], p[1]) : nil
        }
        let model = EmbeddedModelCatalog.model(id: env["DISTAVO_HOLES_MODEL"] ?? "bsc-ca-3370h")
        let language = env["DISTAVO_HOLES_LANGUAGE"] ?? "ca"
        let whisper = try await WhisperKit(WhisperKitConfig(
            model: model.whisperKitName, downloadBase: EmbeddedModelStore.modelsDirectory, modelRepo: model.whisperKitRepo,
            modelFolder: EmbeddedModelStore.whisperKitDirectory(repo: model.whisperKitRepo, variant: model.whisperKitName).path,
            computeOptions: ModelComputeOptions(textDecoderCompute: .cpuAndGPU),
            verbose: false, load: true, download: false))
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath)
        let sr = Double(WhisperKit.sampleRate)
        let options = EmbeddedTranscriber.decodingOptions(languageHint: language)

        for (lo, hi) in clips {
            let slice = Array(audio[Int(lo * sr)..<min(audio.count, Int(hi * sr))])
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("holes-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("clip.wav")
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
            do {   // the writer must be released (header finalised) before the clip is read back
                let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(slice.count))!
                buffer.frameLength = AVAudioFrameCount(slice.count)
                slice.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: slice.count) }
                try file.write(from: buffer)
            }

            let started = Date()
            let clipAudio = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
            let out = await HoleRecovery.recover(
                whisper: whisper, audio: clipAudio, results: [], options: options, report: { _ in })
            let segs = out.results.flatMap(\.segments)
            let words = segs.map { $0.text.split(whereSeparator: \.isWhitespace).count }.reduce(0, +)
            for g in segs { print(String(format: "SEG %.1f-%.1f words=%d", g.start, g.end, g.text.split(whereSeparator: \.isWhitespace).count)) }
            print(String(format: "METRIC clip=%.0f-%.0f segments=%d words=%d notes=%@ seconds=%.0f",
                         lo, hi, segs.count, words, out.footerNotes.joined(separator: " | ") as NSString,
                         Date().timeIntervalSince(started)))
        }
    }
}
