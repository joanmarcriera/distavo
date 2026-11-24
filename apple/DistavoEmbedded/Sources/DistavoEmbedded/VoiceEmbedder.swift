import Foundation
import AVFoundation
import FluidAudio
import DistavoCore

/// The engine behind voice profiles (#2944 phase 2, spec in `DistavoCore/VoiceProfiles.swift`): one voice
/// sample (a 256-number speaker embedding) per speaker, from chosen stretches of a recording.
///
/// FluidAudio's WeSpeaker embedding model (already a dependency for Parakeet), through its public
/// `DiarizerManager.extractSpeakerEmbedding`. That call takes at most ten seconds of 16 kHz mono audio, so
/// each stretch is cut into windows of up to ten seconds; the sample is the mean of the windows, renormalised.
/// The two Core ML models are a separate one-time download into Distavo's models folder; nothing is downloaded
/// unless `transcribe.voice_profiles` is on and a voice has to be computed.
/// Per-call lifetime, under the model lock: nothing model-sized outlives `embeddings`.
/// A failure (no network for the download, unreadable audio) returns no sample: a voice is then simply not
/// recognised or not remembered, and the recording is never failed for it.
public enum VoiceEmbedder {
    static let windowSeconds = 10.0
    static let minWindowSeconds = 2.0
    static let sampleRate = 16_000.0

    /// FluidAudio appends its repo folder to the parent of the directory it is given, so this path ends in it.
    public static var modelsDirectory: URL {
        EmbeddedModelStore.modelsDirectory.appendingPathComponent("voice", isDirectory: true)
            .appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    }

    public static var isDownloaded: Bool {
        let fm = FileManager.default
        return ModelNames.Diarizer.requiredModels.allSatisfy {
            fm.fileExists(atPath: modelsDirectory.appendingPathComponent($0).path)
        }
    }

    /// Speaker -> L2-normalised embedding. Speakers whose audio could not be read or embedded are left out.
    public static func embeddings(audio: URL, ranges: [String: [ClosedRange<Double>]]) async -> [String: [Float]] {
        guard !ranges.isEmpty, HardwareProbe.supportsEmbeddedTranscription else { return [:] }
        let coordinator = ModelCoordinator.shared
        let result = try? await coordinator.withExclusiveAccess { () -> [String: [Float]] in
            if !isDownloaded { await coordinator.report("Downloading the voice model, one-time…") }
            let models = try await DiarizerModels.download(to: modelsDirectory)
            let manager = DiarizerManager()
            manager.initialize(models: models)
            defer { manager.cleanup() }
            var out: [String: [Float]] = [:]
            for speaker in ranges.keys.sorted() {
                var sum: [Float] = [], windows = 0
                for range in ranges[speaker]! {
                    var start = range.lowerBound
                    while range.upperBound - start >= minWindowSeconds {
                        let end = min(start + windowSeconds, range.upperBound)
                        if let samples = try? readMono16k(audio, from: start, to: end),
                           samples.count >= Int(minWindowSeconds * sampleRate),
                           let e = try? manager.extractSpeakerEmbedding(from: samples),
                           e.allSatisfy({ $0.isFinite }) {
                            if sum.isEmpty { sum = e } else if sum.count == e.count { for i in e.indices { sum[i] += e[i] } }
                            windows += 1
                        }
                        start = end
                    }
                }
                let norm = sum.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
                if windows > 0, norm > 1e-6 { out[speaker] = sum.map { $0 / norm } }
            }
            return out
        }
        return result ?? [:]
    }

    /// `[start, end]` seconds of any audio file AVFoundation reads, as 16 kHz mono floats (channels averaged).
    static func readMono16k(_ url: URL, from start: Double, to end: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let first = AVAudioFramePosition(max(0, start) * format.sampleRate)
        let last = min(AVAudioFramePosition(end * format.sampleRate), file.length)
        guard last > first, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(last - first)) else { return [] }
        file.framePosition = first
        try file.read(into: buffer, frameCount: AVAudioFrameCount(last - first))
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return [] }
        let n = Int(buffer.frameLength), count = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<count {
            let p = channels[c]
            for i in 0..<n { mono[i] += p[i] }
        }
        if count > 1 { for i in 0..<n { mono[i] /= Float(count) } }
        guard format.sampleRate != sampleRate else { return mono }
        // Linear resampling: plenty for a speaker embedding, and no converter state to manage per window.
        let ratio = format.sampleRate / sampleRate
        let outCount = Int(Double(n) / ratio)
        var out = [Float](repeating: 0, count: outCount)
        if ratio > 1 {
            // Downsampling: average each output sample's span (a crude low-pass against aliasing).
            for i in 0..<outCount {
                let a = Int(Double(i) * ratio), b = min(n, max(a + 1, Int(Double(i + 1) * ratio)))
                var s: Float = 0
                for j in a..<b { s += mono[j] }
                out[i] = s / Float(b - a)
            }
        } else {
            for i in 0..<outCount {
                let x = Double(i) * ratio
                let a = min(n - 1, Int(x)), b = min(n - 1, a + 1)
                let t = Float(x - Double(a))
                out[i] = mono[a] * (1 - t) + mono[b] * t
            }
        }
        return out
    }
}
