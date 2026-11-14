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
    /// Each side must own at least this share of the decided timed words, else the file is not a two-sided call
    /// (a panned non-Distavo stereo file reads as one side throughout) and the engine's labels stay.
    public static let minSideShare = 0.05
    /// ...and at least this many decided words (a handful of stray words is not a side).
    public static let minSideWords = 2
    /// An engine result that already separates this many speakers is the diariser's work; two channels cannot
    /// describe it.
    public static let diariserSpeakerCeiling = 3
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
            var b = max(a, min(left.count, right.count, Int(w.end * sampleRate)))
            if b == a { b = min(left.count, right.count, a + 1) }   // a word shorter than one sample/hop still reads one
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
        let engineSpeakers = Set(((result["segments"] as? [[String: Any]]) ?? []).compactMap { $0["speaker"] as? String })
        if engineSpeakers.count >= diariserSpeakerCeiling { return nil }
        // Words the engine could not time (numerals: "42") carry no start/end. They are kept, timed to the gap
        // between their neighbours, so the relabel never drops text; only words with real timings count as evidence.
        var raw: [(text: String, start: Double?, end: Double?)] = []
        for seg in (result["segments"] as? [[String: Any]]) ?? [] {
            let segWords = (seg["words"] as? [[String: Any]]) ?? []
            // The relabel rebuilds the transcript from words alone: a segment with text but no words would vanish.
            // Keep the engine's labels instead of losing text.
            let segText = (seg["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if segWords.isEmpty && !segText.isEmpty { return nil }
            for w in segWords {
                guard let t = w["word"] as? String else { continue }
                raw.append((t, w["start"] as? Double, w["end"] as? Double))
            }
        }
        guard raw.contains(where: { $0.start != nil && $0.end != nil }) else { return nil }
        let words = fillUntimed(raw)
        let isTimed = raw.map { $0.start != nil && $0.end != nil }
        guard !words.isEmpty else { return nil }
        // Only words with real timings are evidence; an untimed word (its span is just the gap) takes the side of
        // the word before it, so a run of numerals cannot outvote the words around it.
        let timedIdx = words.indices.filter { isTimed[$0] }
        let timedLabels = label(words: timedIdx.map { words[$0] }, left: channels.left, right: channels.right,
                                sampleRate: channels.sampleRate)
        var labels = [Side?](repeating: nil, count: words.count)
        var last: Side? = nil
        var next = 0
        for i in words.indices {
            if isTimed[i] { last = timedLabels[next]; next += 1 }
            labels[i] = last
        }
        // Leading words before the first decided side join it (else they come out as SPEAKER_UNKNOWN).
        if let first = labels.firstIndex(where: { $0 != nil }), first > 0 {
            for i in 0..<first { labels[i] = labels[first] }
        }
        let decided = timedLabels.compactMap { $0 }
        guard !decided.isEmpty else { return nil }
        // Integer counts (no float edge at the boundary): each side needs the share AND a few words in absolute terms.
        let ownerCount = decided.filter { $0 == .owner }.count
        let smaller = min(ownerCount, decided.count - ownerCount)
        guard smaller >= minSideWords, Double(smaller) >= minSideShare * Double(decided.count) - 1e-9 else { return nil }
        let t = turns(words: words, labels: labels)
        guard !t.isEmpty else { return nil }
        // The aligner emits only `segments`; keep every other engine key (`detections`, `engine`, ...) because the
        // pipeline reads the detected language and the provenance footer from them.
        var out = WordSpeakerAligner.whisperXDictionary(words: words, turns: t)
        for (k, v) in result where k != "segments" { out[k] = v }
        return out
    }

    /// Gives each untimed word the span between the previous word's end and the next timed word's start
    /// (zero-length at the previous end when that gap is negative); leading untimed words take the first start.
    static func fillUntimed(_ raw: [(text: String, start: Double?, end: Double?)]) -> [TimedWord] {
        var out: [TimedWord] = []
        for (i, w) in raw.enumerated() {
            if let s = w.start, let e = w.end { out.append(TimedWord(text: w.text, start: s, end: e)); continue }
            let prevEnd = out.last?.end
            let nextStart = raw[(i + 1)...].lazy.compactMap { $0.start }.first
            let s = prevEnd ?? nextStart ?? 0
            out.append(TimedWord(text: w.text, start: s, end: max(s, nextStart ?? s)))
        }
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

    /// Seconds of audio per envelope value.
    public static let hopSeconds = 0.01

    /// Streams a file with exactly two channels and returns its loudness envelope: one RMS value per 10 ms hop, so
    /// `sampleRate` is hops per second. RMS over a span of the envelope equals RMS over the samples (equal hops), so
    /// `ChannelSpeakerLabeller` reads it unchanged, while an hour-long call costs ~720 kB instead of ~900 MB of
    /// samples. nil for mono, other layouts or unreadable files.
    public static func read(from url: URL) -> StereoChannels? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.channelCount == 2,
              file.length > 0 else { return nil }
        let rate = file.processingFormat.sampleRate
        let hop = max(1, Int(rate * hopSeconds))
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return nil }
        var left: [Float] = [], right: [Float] = []
        left.reserveCapacity(Int(file.length) / hop + 1); right.reserveCapacity(left.capacity)
        var accL: Float = 0, accR: Float = 0, inHop = 0
        func flush() {
            guard inHop > 0 else { return }
            left.append((accL / Float(inHop)).squareRoot()); right.append((accR / Float(inHop)).squareRoot())
            accL = 0; accR = 0; inHop = 0
        }
        while file.framePosition < file.length {
            // A short or failed read (a compressed file whose length was an estimate) ends the scan; what was
            // read is still a usable envelope.
            guard (try? file.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0,
                  let data = buf.floatChannelData else { break }
            for i in 0..<Int(buf.frameLength) {
                let l = data[0][i], r = data[1][i]
                accL += l * l; accR += r * r; inHop += 1
                if inHop == hop { flush() }
            }
        }
        flush()
        guard !left.isEmpty else { return nil }
        // The hop is a whole number of samples, so the true rate is rate / hop (not exactly 100 Hz at 22.05 kHz).
        return StereoChannels(left: left, right: right, sampleRate: rate / Double(hop))
    }
}
