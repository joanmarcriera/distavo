import Foundation
import WhisperKit
import DistavoCore

/// Spec §5.3: identifies the spoken language(s) with Whisper tiny (77 MB) on
/// three 30-second windows spread across the recording, each nudged forward to
/// the next stretch with speech so leading silence or hold music does not vote.
public actor LanguageDetector {
    public static let shared = LanguageDetector()
    public init() {}

    /// WhisperKit's `detectLangauge` reports natural log-probabilities (≤ 0). The router works in
    /// [0, 1], so convert; an absent entry is 0, and anything above 1 (impossible, guarded) clamps.
    static func probability(fromLogProb logProb: Float?) -> Float {
        guard let logProb else { return 0 }
        return min(1, max(0, Float(exp(Double(logProb)))))
    }

    /// Three window start times (seconds). Pure, unit-tested.
    static func windowStarts(totalSeconds: Double, samples: [Float], sampleRate: Int,
                             window: Double = 30, silenceRMS: Float = 0.01) -> [Double] {
        guard totalSeconds > window else { return [0] }
        let latest = totalSeconds - window
        func hasSpeech(at start: Double) -> Bool {
            let lo = Int(start * Double(sampleRate))
            let hi = min(samples.count, lo + Int(window * Double(sampleRate)))
            guard hi > lo else { return false }
            var sum: Float = 0
            for i in lo..<hi { sum += samples[i] * samples[i] }
            return (sum / Float(hi - lo)).squareRoot() > silenceRMS
        }
        return [0.1, 0.5, 0.9].map { fraction in
            var start = min(latest, totalSeconds * fraction)
            var probe = start
            while probe <= latest, !hasSpeech(at: probe) { probe += 5 }
            if probe <= latest { start = probe } else if hasSpeech(at: latest) { start = latest }
            return start
        }
    }

    public func detect(wavURL: URL) async throws -> [LanguageDetection] {
        let coordinator = ModelCoordinator.shared
        return try await coordinator.withExclusiveAccess {
            // 1. Pick the windows and copy out their samples, then drop the full buffer
            //    before the model loads (spec §6: never hold audio and a model together).
            let rate = 16_000
            let slices: [[Float]] = try {
                let full = try AudioProcessor.loadAudioAsFloatArray(fromPath: wavURL.path)
                let total = Double(full.count) / Double(rate)
                return Self.windowStarts(totalSeconds: total, samples: full, sampleRate: rate).compactMap { start in
                    let lo = Int(start * Double(rate)), hi = min(full.count, lo + 30 * rate)
                    return hi > lo ? Array(full[lo..<hi]) : nil
                }
            }()

            // 2. Load the detector (first run downloads it) and classify each slice.
            if !EmbeddedModelStore.isDetectorDownloaded() {
                try coordinator.ensureFreeSpace(forMB: 77)
                await coordinator.report("Downloading language detector — 77 MB, one-time…")
            } else {
                await coordinator.report("Loading language detector…")
            }
            let config = WhisperKitConfig(
                model: EmbeddedModelCatalog.languageDetectorName,
                downloadBase: EmbeddedModelStore.modelsDirectory,
                verbose: false, load: true, download: true)
            let whisper: WhisperKit
            do { whisper = try await WhisperKit(config) }
            catch { throw EmbeddedTranscriber.pipelineError(error, model: "language detector") }

            await coordinator.report("Detecting language…")
            var out: [LanguageDetection] = []
            for slice in slices {
                let (code, probs) = try await whisper.detectLangauge(audioArray: slice)
                out.append(LanguageDetection(code: code, probability: Self.probability(fromLogProb: probs[code])))
            }
            return out
        }
    }
}
