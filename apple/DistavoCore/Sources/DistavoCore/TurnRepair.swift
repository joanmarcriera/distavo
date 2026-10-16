import Foundation

/// A word with timings, engine-neutral (Vikunja #3583).
public struct WordSpan: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

/// A WhisperX-shaped segment for turn repair. `words` is optional and, when
/// present, is kept in step with `text` if a fragment moves between segments.
public struct TurnSegment: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var speaker: String?
    public var words: [WordSpan]?
    public init(text: String, start: Double, end: Double, speaker: String? = nil, words: [WordSpan]? = nil) {
        self.text = text; self.start = start; self.end = end; self.speaker = speaker; self.words = words
    }
}

/// Repairs the two defects measured on a real recording (Vikunja #3583):
///
/// * the Catalan fine-tune's word alignment collapses — 11 % of words had
///   `start == end`, in runs of up to 8 — and SpeakerKit's `.subsegment`
///   strategy then labels those words arbitrarily, flipping the speaker in
///   the middle of a sentence (40 % of speaker changes followed a segment
///   without terminal punctuation) and leaving 18 segments unlabelled;
/// * so: `spreadZeroLengthWords` runs BEFORE diarisation, `smoothTurns`
///   AFTER it, on the mapped segments.
///
/// Pure and conservative: already-clean input comes back unchanged.
public enum TurnRepair {

    // MARK: - Zero-length words

    /// Words shorter than this are treated as collapsed.
    public static let collapsedWordSeconds = 0.02

    /// Spreads each run of collapsed words evenly between the previous timed
    /// word's end and the next timed word's start (falling back to
    /// `segmentStart` / `segmentEnd`, then to the run's own bounds). Timed
    /// words are never touched; the output is monotonic and non-overlapping
    /// within each run. A run with no room (the neighbours already touch) is
    /// left as it was.
    public static func spreadZeroLengthWords(
        _ words: [WordSpan], segmentStart: Double? = nil, segmentEnd: Double? = nil
    ) -> [WordSpan] {
        var out = words
        var i = 0
        while i < out.count {
            guard out[i].end - out[i].start < collapsedWordSeconds else { i += 1; continue }
            var j = i
            while j < out.count, out[j].end - out[j].start < collapsedWordSeconds { j += 1 }
            // out[i..<j] is a collapsed run.
            let lower = i > 0 ? out[i - 1].end : (segmentStart ?? out[i].start)
            let upper = j < out.count ? out[j].start : (segmentEnd ?? out[j - 1].end)
            let room = upper - lower
            if room > 0 {
                let n = j - i
                let slot = room / Double(n)
                for k in 0..<n {
                    out[i + k].start = lower + Double(k) * slot
                    out[i + k].end = lower + Double(k + 1) * slot
                }
            }
            i = j
        }
        return out
    }

    // MARK: - Punctuation helpers

    private static let closers = CharacterSet(charactersIn: "\"'”’»)]}*_")
    private static let terminals: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]
    private static let softPunctuation: Set<Character> = [",", ";", ":", "，", "；", "："]

    private static func trimmedForEnding(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = s.unicodeScalars.last, closers.contains(last) { s.unicodeScalars.removeLast() }
        return s
    }

    /// True when the text ends a sentence (. ? ! … , ignoring closing quotes/brackets).
    public static func endsTerminally(_ text: String) -> Bool {
        guard let last = trimmedForEnding(text).last else { return true }   // empty: nothing dangling
        return terminals.contains(last)
    }

    private static func endsFragment(_ word: String) -> Bool {
        guard let last = trimmedForEnding(word).last else { return false }
        return terminals.contains(last) || softPunctuation.contains(last)
    }

    private static func endsSentence(_ word: String) -> Bool {
        guard let last = trimmedForEnding(word).last else { return false }
        return terminals.contains(last)
    }

    /// True when the first letter (skipping ¿ ¡ quotes and brackets) is lowercase.
    static func startsLowercase(_ text: String) -> Bool {
        for ch in text {
            if ch.isLetter { return ch.isLowercase }
            if ch.isNumber { return false }
        }
        return false
    }

    static func tokens(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    // MARK: - Metric

    /// Speaker changes between consecutive labelled segments, and how many of
    /// them follow a segment that does not end in terminal punctuation.
    public static func changesAfterNonTerminal(_ segments: [TurnSegment]) -> (changes: Int, afterNonTerminal: Int) {
        var changes = 0, nonTerminal = 0
        for k in 1..<max(1, segments.count) {
            guard let a = segments[k - 1].speaker, let b = segments[k].speaker, a != b else { continue }
            changes += 1
            if !endsTerminally(segments[k - 1].text) { nonTerminal += 1 }
        }
        return (changes, nonTerminal)
    }

    // MARK: - Smoothing

    /// Longest pause between two segments that still counts as "the same sentence".
    static let sameSentenceGap = 1.5
    /// Longest fragment (words) moved back to the previous speaker when it ends at a comma.
    static let maxFragmentWords = 3
    /// Longest sentence continuation (words, up to its full stop) moved back to the previous speaker.
    static let maxContinuationWords = 30
    /// A neighbour label within this gap wins when labelling an unlabelled segment.
    static let labelGap = 1.0

    public static func smoothTurns(segments input: [TurnSegment]) -> [TurnSegment] {
        var segs = input
        fillUnlabelled(&segs)
        absorbShortTurns(&segs)
        moveMidSentenceFragments(&segs)
        return segs
    }

    /// (iii) A segment with no speaker takes the nearest labelled neighbour's
    /// speaker when the gap is <= 1 s, otherwise the longer neighbour's.
    private static func fillUnlabelled(_ segs: inout [TurnSegment]) {
        let labelled = segs.indices.filter { segs[$0].speaker != nil }
        guard !labelled.isEmpty else { return }
        let original = segs
        for k in segs.indices where original[k].speaker == nil {
            let left = labelled.last { $0 < k }
            let right = labelled.first { $0 > k }
            func duration(_ i: Int) -> Double { original[i].end - original[i].start }
            switch (left, right) {
            case let (l?, r?):
                let gapL = max(0, original[k].start - original[l].end)
                let gapR = max(0, original[r].start - original[k].end)
                if min(gapL, gapR) <= labelGap {
                    segs[k].speaker = gapL <= gapR ? original[l].speaker : original[r].speaker
                } else {
                    segs[k].speaker = duration(l) >= duration(r) ? original[l].speaker : original[r].speaker
                }
            case let (l?, nil): segs[k].speaker = original[l].speaker
            case let (nil, r?): segs[k].speaker = original[r].speaker
            default: break
            }
        }
    }

    /// (i) A turn of <= 2 words between two segments of the same other speaker
    /// takes that speaker.
    private static func absorbShortTurns(_ segs: inout [TurnSegment]) {
        guard segs.count >= 3 else { return }
        for k in 1..<(segs.count - 1) {
            guard let prev = segs[k - 1].speaker, let next = segs[k + 1].speaker, prev == next,
                  segs[k].speaker != prev, tokens(segs[k].text).count <= 2 else { continue }
            segs[k].speaker = prev
        }
    }

    /// (ii) When a turn changes in the middle of a sentence — the previous
    /// segment has no terminal punctuation and the next starts lowercase right
    /// after a short pause — the next segment's first few words (up to their
    /// first punctuation mark, at most 3 words) or else the rest of the sentence
    /// (up to its full stop, at most 30 words) belong to the previous speaker.
    /// A continuation of at most 30 words with no full stop moves whole. On the
    /// 2026-10-16 field recording almost every remaining mid-sentence change was
    /// this shape: a comma, then a lowercase continuation under another label.
    private static func moveMidSentenceFragments(_ segs: inout [TurnSegment]) {
        guard segs.count >= 2 else { return }
        for k in 1..<segs.count {
            guard let a = segs[k - 1].speaker, let b = segs[k].speaker, a != b,
                  !endsTerminally(segs[k - 1].text), startsLowercase(segs[k].text),
                  segs[k].start - segs[k - 1].end <= sameSentenceGap else { continue }
            let words = tokens(segs[k].text)
            // A short fragment up to its first punctuation mark; failing that, the rest of the
            // sentence up to its full stop (a lowercase start after an unfinished sentence is a
            // continuation: Whisper capitalises a new speaker's first word).
            let cut = words.prefix(maxFragmentWords).firstIndex(where: endsFragment)
                ?? words.prefix(maxContinuationWords).firstIndex(where: endsSentence)
            guard let cut else {
                if words.count <= maxContinuationWords { segs[k].speaker = a }   // no sentence end at all: all of it
                continue
            }
            let take = cut + 1
            if take >= words.count {
                // The whole segment is the tail of the previous sentence.
                segs[k].speaker = a
                continue
            }
            let fragment = words[..<take].joined(separator: " ")
            let rest = words[take...].joined(separator: " ")
            var boundary: Double
            if let w = segs[k].words, w.count == words.count {
                boundary = w[take].start
                segs[k - 1].words = (segs[k - 1].words ?? []) + w[..<take]
                segs[k].words = Array(w[take...])
                segs[k - 1].end = max(segs[k - 1].end, w[take - 1].end)
            } else {
                let span = segs[k].end - segs[k].start
                boundary = segs[k].start + span * Double(take) / Double(words.count)
                segs[k - 1].end = max(segs[k - 1].end, boundary)
                // Word timings no longer match the text: drop them rather than mislead the sidecar.
                segs[k - 1].words = nil
                segs[k].words = nil
            }
            segs[k - 1].text = segs[k - 1].text.trimmingCharacters(in: .whitespaces) + " " + fragment
            segs[k].text = rest
            segs[k].start = min(max(boundary, segs[k].start), segs[k].end)
        }
    }

    // MARK: - WhisperX dictionary adapter

    /// Applies `smoothTurns` to a WhisperX-shaped result (`["segments": [...]]`),
    /// keeping word timings in step. Returns the input untouched when nothing
    /// needs repairing or the shape is unexpected.
    public static func smoothTurns(result: [String: Any]) -> [String: Any] {
        guard let raw = result["segments"] as? [[String: Any]], !raw.isEmpty else { return result }
        let before: [TurnSegment] = raw.map { entry in
            let words = (entry["words"] as? [[String: Any]])?.compactMap { w -> WordSpan? in
                guard let t = w["word"] as? String, let s = w["start"] as? Double, let e = w["end"] as? Double else { return nil }
                return WordSpan(start: s, end: e, text: t)
            }
            return TurnSegment(
                text: entry["text"] as? String ?? "", start: entry["start"] as? Double ?? 0,
                end: entry["end"] as? Double ?? 0, speaker: entry["speaker"] as? String, words: words)
        }
        let after = smoothTurns(segments: before)
        guard after != before else { return result }
        var out: [[String: Any]] = []
        for (entry, seg) in zip(raw, after) {
            var e = entry
            e["text"] = seg.text
            e["start"] = seg.start
            e["end"] = seg.end
            if let s = seg.speaker { e["speaker"] = s }
            if let words = seg.words {
                e["words"] = words.map { ["word": $0.text, "start": $0.start, "end": $0.end] as [String: Any] }
            } else {
                e["words"] = nil
            }
            // A segment emptied by a fragment move disappears.
            if !seg.text.trimmingCharacters(in: .whitespaces).isEmpty { out.append(e) }
        }
        var copy = result
        copy["segments"] = out
        return copy
    }
}
