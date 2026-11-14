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

    /// A subsegment that straddles a turn boundary is cut there only when each
    /// side holds at least this many words (#3953): a fast hand-off ("...five and
    /// seven." / "How old?") leaves no 0.15 s gap, so the whole run used to take
    /// one label; a lone word at an edge stays with its neighbours, so a
    /// diarisation flicker cannot shred a sentence.
    public static let minSplitWords = 2

    /// Speaker of the turn covering most of a word (midpoint fallback), nil when none.
    static func speakerOf(_ w: TimedWord, in turns: [SpeakerTurn]) -> Int? {
        var best: (Int, Double)? = nil
        for t in turns {
            let o = min(w.end, t.end) - max(w.start, t.start)
            if o > 0, best == nil || o > best!.1 { best = (t.speaker, o) }
        }
        if best == nil {
            let m = (w.start + w.end) / 2
            return turns.first { m >= $0.start && m <= $0.end }?.speaker
        }
        return best?.0
    }

    /// Cuts a gap-free word group where its words move from one turn's speaker to
    /// another's, keeping runs of at least `minSplitWords` words.
    static func splitAtTurnBoundaries(_ group: [TimedWord], turns: [SpeakerTurn]) -> [[TimedWord]] {
        guard group.count >= 2 * minSplitWords else { return [group] }
        var per = group.map { speakerOf($0, in: turns) }
        // Words before the first covered one take its label (#5934): a leading
        // uncovered run must never become a group of its own, or it would inherit
        // the previous group's speaker through `carryGap`.
        if let first = per.firstIndex(where: { $0 != nil }), first > 0 {
            for k in 0..<first { per[k] = per[first] }
        }
        // Runs of identical (non-nil) labels; nil words join the preceding run.
        var runs: [(speaker: Int?, range: Range<Int>)] = []
        var i = 0
        while i < per.count {
            var j = i + 1
            while j < per.count, per[j] == per[i] || per[j] == nil { j += 1 }
            runs.append((per[i], i..<j)); i = j
        }
        // Fold runs that are too short into the previous (or next) run.
        var merged: [(speaker: Int?, range: Range<Int>)] = []
        for r in runs {
            if r.range.count < minSplitWords, var last = merged.popLast() {
                last.range = last.range.lowerBound..<r.range.upperBound; merged.append(last)
            } else if let last = merged.last, last.speaker == r.speaker {
                merged[merged.count - 1].range = last.range.lowerBound..<r.range.upperBound
            } else { merged.append(r) }
        }
        if merged.count > 1, merged[0].range.count < minSplitWords {
            let f = merged.removeFirst(); merged[0].range = f.range.lowerBound..<merged[0].range.upperBound
        }
        return merged.map { Array(group[$0.range]) }
    }

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
        groups = groups.flatMap { splitAtTurnBoundaries($0, turns: turns) }

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
            // Word timings ride along for the segments sidecar (#2943); the cleaner ignores them.
            entry["words"] = current.map { ["word": $0.text, "start": $0.start, "end": $0.end] as [String: Any] }
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
