import XCTest
import WhisperKit
@testable import DistavoEmbedded
import DistavoCore

/// Debug harness for Vikunja #3579 (audible speech missing from the embedded
/// transcript). It reproduces the app's VAD chunking on a real recording,
/// picks the chunks that overlap the requested spans, and decodes each chunk
/// several ways so the cause shows up as numbers:
///
///   app        — exactly the app's `decodingOptions` (+ vocabulary prompt if given)
///   noprompt   — the app's options without the vocabulary prompt
///   nogate     — noSpeechThreshold = nil (the whole-window "silence" skip off)
///   ungated    — every gate off (noSpeech, logProb, firstTokenLogProb, compression)
///   gain       — the app's options on the chunk scaled to RMS 0.1
///
///   DISTAVO_HOLES_LIVE=1 \
///   DISTAVO_HOLES_AUDIO=/abs/16k.wav \
///   DISTAVO_HOLES_SPANS="0-34,182-202,2082-2114,2229-2263,300-330" \
///   DISTAVO_HOLES_MODEL=bsc-ca-3370h DISTAVO_HOLES_LANGUAGE=ca \
///   DISTAVO_HOLES_VOCAB="Term1,Term2" \
///   swift test --filter HoleProbeLiveTests
///
/// **Privacy:** prints only numbers (word counts, probabilities), never text.
final class HoleProbeLiveTests: XCTestCase {

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    func testProbeDroppedSpans() async throws {
        try XCTSkipUnless(env["DISTAVO_HOLES_LIVE"] == "1", "set DISTAVO_HOLES_LIVE=1")
        guard let audioPath = env["DISTAVO_HOLES_AUDIO"] else {
            XCTFail("set DISTAVO_HOLES_AUDIO"); return
        }
        let spans: [(Double, Double)] = (env["DISTAVO_HOLES_SPANS"] ?? "0-34")
            .split(separator: ",").compactMap {
                let p = $0.split(separator: "-").compactMap { Double($0) }
                return p.count == 2 ? (p[0], p[1]) : nil
            }
        let model = EmbeddedModelCatalog.model(id: env["DISTAVO_HOLES_MODEL"] ?? "bsc-ca-3370h")
        let language = env["DISTAVO_HOLES_LANGUAGE"] ?? "ca"
        let vocab = (env["DISTAVO_HOLES_VOCAB"] ?? "").split(separator: ",").map(String.init)

        let whisper = try await WhisperKit(WhisperKitConfig(
            model: model.whisperKitName,
            downloadBase: EmbeddedModelStore.modelsDirectory,
            modelRepo: model.whisperKitRepo,
            modelFolder: EmbeddedModelStore.whisperKitDirectory(
                repo: model.whisperKitRepo, variant: model.whisperKitName).path,
            computeOptions: ModelComputeOptions(textDecoderCompute: .cpuAndGPU),
            verbose: false, load: true, download: false))
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath)
        let sr = Double(WhisperKit.sampleRate)
        print("METRIC audio_seconds=\(Double(audio.count) / sr)")

        // The app's chunk boundaries: same chunker, same window, same VAD.
        let chunks = try await VADAudioChunker().chunkAll(
            audioArray: audio, maxChunkLength: WhisperKit.sampleRate * 30,
            decodeOptions: EmbeddedTranscriber.decodingOptions(languageHint: language))
        print("METRIC vad_chunks=\(chunks.count)")

        var prompt: [Int]? = nil
        if !vocab.isEmpty, let tok = whisper.tokenizer {
            prompt = tok.encode(text: " " + Vocabulary.transcriberPrompt(
                vocab, maxTokens: 223, tokenCount: { tok.encode(text: $0).count }))
        }

        for (lo, hi) in spans {
            let hits = chunks.enumerated().filter {
                let s = Double($0.element.seekOffsetIndex) / sr
                let e = s + Double($0.element.audioSamples.count) / sr
                return e > lo && s < hi
            }
            for (idx, chunk) in hits {
                let s = Double(chunk.seekOffsetIndex) / sr
                let e = s + Double(chunk.audioSamples.count) / sr
                let rms = Self.rms(chunk.audioSamples)
                print(String(format: "CHUNK span=%.0f-%.0f chunk#%d %.1f-%.1f rms=%.4f",
                             lo, hi, idx, s, e, rms))
                for variant in ["app", "noprompt", "nogate", "ungated", "gain"] {
                    var o = EmbeddedTranscriber.decodingOptions(languageHint: language)
                    o.chunkingStrategy = nil   // the chunk is already ≤ one window
                    if variant != "noprompt" { o.promptTokens = prompt }
                    var samples = chunk.audioSamples
                    switch variant {
                    case "nogate": o.noSpeechThreshold = nil
                    case "ungated":
                        o.noSpeechThreshold = nil; o.logProbThreshold = nil
                        o.firstTokenLogProbThreshold = nil; o.compressionRatioThreshold = nil
                    case "gain":
                        let g = rms > 0 ? Float(0.1 / rms) : 1
                        samples = samples.map { max(-1, min(1, $0 * g)) }
                    default: break
                    }
                    do {
                        let r = try await whisper.transcribe(audioArray: samples, decodeOptions: o)
                        let segs = r.flatMap(\.segments)
                        let words = segs.map { $0.text.split(whereSeparator: \.isWhitespace).count }.reduce(0, +)
                        let nsp = segs.map(\.noSpeechProb).max() ?? -1
                        let lp = segs.isEmpty ? 0 : segs.map(\.avgLogprob).reduce(0, +) / Float(segs.count)
                        let cr = segs.map(\.compressionRatio).max() ?? 0
                        let t = segs.map(\.temperature).max() ?? 0
                        let covered = segs.map { Double($0.end - $0.start) }.reduce(0, +)
                        print(String(format: "  %-9@ words=%3d segs=%2d covered=%5.1fs maxNoSpeech=%.2f meanLogProb=%.2f maxCR=%.2f maxT=%.1f",
                                     variant as NSString, words, segs.count, covered, nsp, lp, cr, t))
                    } catch {
                        print("  \(variant) ERROR \(type(of: error))")
                    }
                }
            }
        }
    }

    private static func rms(_ x: [Float]) -> Double {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0.0) { $0 + Double($1 * $1) } / Double(x.count)).squareRoot()
    }
}
