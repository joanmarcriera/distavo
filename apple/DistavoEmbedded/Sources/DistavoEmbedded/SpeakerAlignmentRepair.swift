import Foundation
import WhisperKit

/// Repairs for the two defects the 2026-10-16 Catalan field test showed in the embedded transcript
/// (Vikunja #3583): 873 of 7,851 words (11 %) had start == end, and 40 % of the speaker changes
/// fell in the middle of a sentence, with 18 segments carrying no speaker at all.
///
/// Cause: the BSC fine-tune's word alignment collapses runs of words onto one instant, and
/// SpeakerKit's `.subsegment` strategy assigns each word to a speaker by its timestamp, so
/// zero-length words land on either side of a speaker turn. Two pure steps fix it:
///
///  1. `repairWordTimings` runs BEFORE the speaker alignment and spreads each run of zero-length words
///     over the time up to the next properly timed word, so a run stays together;
///  2. `smoothTurns` runs on the mapped segments AFTER it: a turn of at most two words that sits
///     between two turns of the same other speaker is a flip, not a turn, and joins them; a segment
///     with no speaker takes the nearest speaker within a second.
public enum SpeakerAlignmentRepair {

    // MARK: 1. Word timings

    /// Shortest time given to a word that had none, seconds.
    static let minWord = 0.04

    /// `words` with every run of zero-length (end <= start) words given real, increasing times: spread
    /// evenly from the run's instant to the start of the next timed word (or the segment's end), at
    /// least `minWord` each and at most 0.4 s each. Timed words are never moved.
    public static func repairWordTimings(
        _ words: [(start: Double, end: Double)], segmentEnd: Double
    ) -> [(start: Double, end: Double)] {
        var out = words
        var i = 0
        while i < out.count {
            guard out[i].end <= out[i].start else { i += 1; continue }
            var j = i
            while j < out.count, out[j].end <= out[j].start { j += 1 }
            let run = j - i
            let t0 = out[i].start
            let limit = j < out.count ? out[j].start : segmentEnd
            let share = limit > t0 ? (limit - t0) / Double(run) : 0
            let each = min(0.4, max(minWord, share))
            for k in 0..<run {
                let s = t0 + Double(k) * each
                out[i + k] = (start: s, end: s + each)
            }
            i = j
        }
        return out
    }

    /// Apply `repairWordTimings` to every word of every segment, in place.
    public static func repair(_ results: [TranscriptionResult]) {
        for result in results {
            var segments = result.segments
            for s in segments.indices {
                guard var words = segments[s].words, words.contains(where: { $0.end <= $0.start }) else { continue }
                let fixed = repairWordTimings(
                    words.map { (start: Double($0.start), end: Double($0.end)) },
                    segmentEnd: Double(segments[s].end))
                for w in words.indices { words[w].start = Float(fixed[w].start); words[w].end = Float(fixed[w].end) }
                segments[s].words = words
            }
            result.segments = segments
        }
    }

    // MARK: 2. Speaker turns

    public struct Turn: Equatable {
        public var speaker: String?
        public var text: String
        public var start: Double
        public var end: Double
        public init(speaker: String?, text: String, start: Double, end: Double) {
            self.speaker = speaker; self.text = text; self.start = start; self.end = end
        }
        var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
    }

    /// Longest gap, seconds, across which an unlabelled segment borrows a neighbour's speaker.
    static let nearest = 1.0
    /// A turn of at most this many words between two turns of one speaker is a flip.
    static let flipWords = 2

    public static func smoothTurns(_ turns: [Turn]) -> [Turn] {
        var t = turns
        // Unlabelled segments take the closer labelled neighbour within `nearest` seconds.
        for i in t.indices where t[i].speaker == nil {
            let before = (0..<i).reversed().first { t[$0].speaker != nil }
            let after = ((i + 1)..<t.count).first { t[$0].speaker != nil }
            let gapBefore = before.map { t[i].start - t[$0].end } ?? .infinity
            let gapAfter = after.map { t[$0].start - t[i].end } ?? .infinity
            if min(gapBefore, gapAfter) <= nearest {
                t[i].speaker = gapBefore <= gapAfter ? t[before!].speaker : t[after!].speaker
            }
        }
        // A short turn between two turns of the same other speaker joins them.
        var i = 1
        while i + 1 < t.count {
            if let s = t[i].speaker, let a = t[i - 1].speaker, let b = t[i + 1].speaker,
               a == b, s != a, t[i].wordCount <= flipWords {
                t[i].speaker = a
            }
            i += 1
        }
        return t
    }
}
