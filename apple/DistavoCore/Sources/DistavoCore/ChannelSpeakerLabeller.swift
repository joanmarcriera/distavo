import Foundation
import AVFoundation

/// Labels words by which side of the call spoke them, from the recorder's stereo layout
/// (left = the owner's microphone, right = system audio, i.e. the remote side) — Vikunja #6353.
///
/// Per word the energy of each channel over the word's span gives a dB difference (L − R); a
/// 5-word median smooths it; beyond ±`marginDB` the word belongs to that side, otherwise it
/// inherits the previous word's side (nil while no word has been decided yet). Pure: it takes
/// samples and timings, so it is tested with synthetic tones and never needs a recording.
/// It only applies when `bothChannelsLive` — a silent system channel (#2060) keeps the
/// diarisation path. The remote side can still be split by the diariser when more than one
/// remote participant is expected (caller's decision).
public enum ChannelSpeakerLabeller {
    public enum Side: Int, Equatable, Sendable { case owner = 0, remote = 1 }

    /// Margin (dB) a channel must win by; prototype value from the 2026-11-04 call.
    public static let marginDB = 3.0
    /// Median window in words (odd).
    public static let medianWords = 5
    /// A channel below this RMS (about -60 dBFS) counts as silent.
    public static let liveRMS: Float = 0.001

    /// True when both channels carry signal, so a channel comparison means something.
    public static func bothChannelsLive(left: [Float], right: [Float]) -> Bool {
        rms(left[...]) > liveRMS && rms(right[...]) > liveRMS
    }

    /// One label per word (nil = undecided).
    public static func label(words: [TimedWord], left: [Float], right: [Float], sampleRate: Double) -> [Side?] {
        let diffs: [Double] = words.map { w in
            let a = max(0, min(left.count, Int(w.start * sampleRate)))
            let b = max(a, min(left.count, right.count, Int(w.end * sampleRate)))
            guard b > a else { return 0 }
            let l = Double(rms(left[a..<b])), r = Double(rms(right[a..<b]))
            return 20 * log10((l + 1e-6) / (r + 1e-6))
        }
        let half = medianWords / 2
        var out: [Side?] = []
        var previous: Side? = nil
        for i in diffs.indices {
            let window = diffs[max(0, i - half)...min(diffs.count - 1, i + half)].sorted()
            // Even windows (at the edges) average the two middle values.
            let mid = window.count / 2
            let m = window.count % 2 == 1 ? window[mid] : (window[mid - 1] + window[mid]) / 2
            if m > marginDB { previous = .owner } else if m < -marginDB { previous = .remote }
            out.append(previous)
        }
        return out
    }

    /// Consecutive words of one side become one turn (speaker 0 = owner, 1 = remote), ready for
    /// `WordSpeakerAligner`. Undecided words are skipped.
    public static func turns(words: [TimedWord], labels: [Side?]) -> [SpeakerTurn] {
        var turns: [SpeakerTurn] = []
        for (w, l) in zip(words, labels) {
            guard let l else { continue }
            if let last = turns.last, last.speaker == l.rawValue {
                turns[turns.count - 1] = SpeakerTurn(speaker: l.rawValue, start: last.start, end: w.end)
            } else {
                turns.append(SpeakerTurn(speaker: l.rawValue, start: w.start, end: w.end))
            }
        }
        return turns
    }

    /// Re-labels an engine result (WhisperX shape with per-segment `words`) from the channels: words -> sides ->
    /// two turns -> `WordSpeakerAligner`. nil (keep the engine's labels) when a channel is silent, the result has
    /// no word timings, or no word could be decided. Remote stays one speaker; owner = SPEAKER_00.
    public static func relabel(result: [String: Any], channels: StereoChannels) -> [String: Any]? {
        guard bothChannelsLive(left: channels.left, right: channels.right) else { return nil }
        var words: [TimedWord] = []
        for seg in (result["segments"] as? [[String: Any]]) ?? [] {
            for w in (seg["words"] as? [[String: Any]]) ?? [] {
                if let t = w["word"] as? String, let s = w["start"] as? Double, let e = w["end"] as? Double {
                    words.append(TimedWord(text: t, start: s, end: e))
                }
            }
        }
        guard !words.isEmpty else { return nil }
        let labels = label(words: words, left: channels.left, right: channels.right, sampleRate: channels.sampleRate)
        let t = turns(words: words, labels: labels)
        guard !t.isEmpty else { return nil }
        // The aligner emits only `segments`; keep every other engine key (`detections`, `engine`, ...) because the
        // pipeline reads the detected language and the provenance footer from them.
        var out = WordSpeakerAligner.whisperXDictionary(words: words, turns: t)
        for (k, v) in result where k != "segments" { out[k] = v }
        return out
    }

    private static func rms(_ s: ArraySlice<Float>) -> Float {
        guard !s.isEmpty else { return 0 }
        var acc: Float = 0
        for v in s { acc += v * v }
        return (acc / Float(s.count)).squareRoot()
    }
}


/// Left/right samples of a stereo source (left = owner's mic, right = system audio) for `ChannelSpeakerLabeller`.
public struct StereoChannels: Sendable {
    public var left: [Float]
    public var right: [Float]
    public var sampleRate: Double
    public init(left: [Float], right: [Float], sampleRate: Double) {
        self.left = left; self.right = right; self.sampleRate = sampleRate
    }

    /// Decodes a file with exactly two channels; nil for mono, other layouts or unreadable files.
    public static func read(from url: URL) -> StereoChannels? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.channelCount == 2,
              file.length > 0, file.length < 1 << 31,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil, let data = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength)
        return StereoChannels(left: Array(UnsafeBufferPointer(start: data[0], count: n)),
                              right: Array(UnsafeBufferPointer(start: data[1], count: n)),
                              sampleRate: file.processingFormat.sampleRate)
    }
}
