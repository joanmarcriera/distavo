import Foundation

/// A transcribed word with timestamps in seconds (engine-neutral).
public struct TimedWord: Equatable, Sendable {
    public let text: String
    public let start: Double
    public let end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

/// One diarisation turn: speaker index and its time span in seconds.
public struct SpeakerTurn: Equatable, Sendable {
    public let speaker: Int
    public let start: Double
    public let end: Double
    public init(speaker: Int, start: Double, end: Double) { self.speaker = speaker; self.start = start; self.end = end }
}

/// Labels words with speakers and emits the WhisperX `segments` dictionary the
/// rest of the pipeline consumes. Ports SpeakerKit's `.subsegment` strategy
/// (group words by silence gap → largest-intersection turn → carry the previous
/// speaker when nothing overlaps) so the Parakeet path labels exactly like the
/// WhisperKit path does today. Pure; unit-tested with fixtures.
public enum WordSpeakerAligner {
    /// Silence between two words above which they start a new subsegment
    /// — SpeakerKit's default `betweenWordThreshold` (0.15 s), kept for parity.
    public static let betweenWordGap = 0.15

    /// A subsegment that overlaps no diarisation turn inherits the previous
    /// subsegment's speaker when the silence before it is at most this long;
    /// beyond it the speaker is unknown (spec §5.5).
    public static let carryGap = 1.0

    public static func whisperXDictionary(words rawWords: [TimedWord], turns rawTurns: [SpeakerTurn]) -> [String: Any] {
        // M8: sort by (start, end) rather than start alone, so two entries that
        // share a start time (a zero-length turn, or a duplicated timestamp in
        // the ASR output) land in a deterministic, stable order instead of
        // whatever order `sorted` happens to leave equal-key elements in.
        let words = rawWords
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        let turns = rawTurns
            .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        guard !words.isEmpty else { return ["segments": [[String: Any]]()] }

        // 1. Subsegments split on silence.
        var groups: [[TimedWord]] = [[words[0]]]
        for i in 1..<words.count {
            if words[i].start - words[i - 1].end > betweenWordGap { groups.append([words[i]]) }
            else { groups[groups.count - 1].append(words[i]) }
        }

        // 2. Speaker per subsegment: largest intersection. A subsegment that
        // overlaps no turn inherits the previous subsegment's speaker if the
        // silence before it is ≤ carryGap (SpeakerKit carries unconditionally;
        // spec §5.5 bounds it), otherwise it is `unknown`.
        var labelled: [(speaker: Int?, words: [TimedWord])] = []
        var previous: (speaker: Int?, end: Double)? = nil
        for group in groups {
            let start = group.first!.start, end = group.last!.end
            var best: (speaker: Int, score: Double)? = nil
            for t in turns {
                let overlap = min(end, t.end) - max(start, t.start)
                guard overlap > 0 else { continue }
                if best == nil || overlap > best!.score { best = (t.speaker, overlap) }
            }
            var speaker = best?.speaker
            if speaker == nil, let prev = previous, start - prev.end <= carryGap { speaker = prev.speaker }
            labelled.append((speaker, group))
            previous = (speaker, end)
        }

        // 3. Merge consecutive same-speaker groups, then split at sentence ends.
        var out: [[String: Any]] = []
        var current: [TimedWord] = []
        var currentSpeaker: Int? = nil
        func flush() {
            guard !current.isEmpty else { return }
            var entry: [String: Any] = [
                "text": current.map(\.text).joined(separator: " "),
                "start": current.first!.start,
                "end": current.last!.end,
            ]
            if let s = currentSpeaker { entry["speaker"] = String(format: "SPEAKER_%02d", s) }
            out.append(entry)
            current = []
        }
        for (speaker, group) in labelled {
            if speaker != currentSpeaker { flush(); currentSpeaker = speaker }
            for word in group {
                current.append(word)
                if endsSentence(word.text) { flush() }
            }
        }
        flush()
        return ["segments": out]
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last else { return false }
        return ".?!…。？！".unicodeScalars.contains(last)
    }
}
