import Foundation

/// Pure helpers for finding audible stretches of a recording that the first
/// transcription pass left empty (Vikunja #3579), and for choosing between
/// re-decodes of such a stretch. No models, no I/O — the WhisperKit-touching
/// recovery lives in DistavoEmbedded (`HoleRecovery.swift`) and only feeds
/// numbers in here.
///
/// Why it exists: with a vocabulary prompt, a Whisper fine-tune can emit ~1
/// word for a whole 20–30 s chunk (one segment, one "word" spanning the chunk).
/// The gates never fire, so the speech is silently missing. Such a "word" must
/// not count as coverage, and the stretch is decoded again without the prompt.
public enum SpeechCoverage {

    // MARK: - Energy

    /// RMS of consecutive `frameSeconds` frames (the last frame may be shorter).
    public static func rmsFrames(samples: [Float], sampleRate: Int, frameSeconds: Double = 1.0) -> [Float] {
        let size = max(1, Int((Double(sampleRate) * frameSeconds).rounded()))
        guard !samples.isEmpty else { return [] }
        var out: [Float] = []
        out.reserveCapacity(samples.count / size + 1)
        var i = 0
        while i < samples.count {
            let end = min(i + size, samples.count)
            var sum: Double = 0
            for j in i..<end { sum += Double(samples[j]) * Double(samples[j]) }
            out.append(Float((sum / Double(end - i)).squareRoot()))
            i = end
        }
        return out
    }

    // MARK: - Holes

    /// Maximal runs of audible, uncovered frames lasting at least `minSeconds`.
    ///
    /// The noise floor is the 20th percentile of the frame RMS values; a frame
    /// is audible when its RMS exceeds `max(floorFactor * floor, 0.005)`. A run
    /// may bridge quiet gaps of up to one second (a breath between sentences).
    /// A frame counts as covered when its centre lies inside a `covered` range.
    /// Touching or overlapping holes are merged. Ranges are in seconds.
    public static func holes(
        rms: [Float], frameSeconds: Double, covered: [ClosedRange<Double>],
        minSeconds: Double = 8, floorFactor: Float = 2
    ) -> [ClosedRange<Double>] {
        guard !rms.isEmpty, frameSeconds > 0 else { return [] }
        let sorted = rms.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.2)]
        let threshold = max(floorFactor * floor, 0.005)

        enum State { case hole, quiet, other }
        let states: [State] = rms.enumerated().map { index, value in
            guard value > threshold else { return .quiet }
            let centre = (Double(index) + 0.5) * frameSeconds
            return covered.contains(where: { $0.contains(centre) }) ? .other : .hole
        }

        let maxGapFrames = max(1, Int((1.0 / frameSeconds).rounded(.down)))
        var found: [ClosedRange<Double>] = []
        var runStart: Int? = nil
        var lastHole = 0
        func close() {
            guard let s = runStart else { return }
            let lo = Double(s) * frameSeconds
            let hi = Double(lastHole + 1) * frameSeconds
            if hi - lo >= minSeconds - 1e-9 { found.append(lo...hi) }
            runStart = nil
        }
        var i = 0
        while i < states.count {
            switch states[i] {
            case .hole:
                if runStart == nil { runStart = i }
                lastHole = i
            case .other:
                close()
            case .quiet:
                guard runStart != nil else { break }
                // Bridge a short quiet gap only if a hole frame follows it.
                var j = i
                while j < states.count, states[j] == .quiet { j += 1 }
                if !(j - i <= maxGapFrames && j < states.count && states[j] == .hole) { close() }
                i = j - 1
            }
            i += 1
        }
        close()

        var merged: [ClosedRange<Double>] = []
        for hole in found {
            if let last = merged.last, hole.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, hole.upperBound)
            } else { merged.append(hole) }
        }
        return merged
    }

    // MARK: - Coverage

    /// A single "word" longer than this is the collapsed one-word-for-a-whole-
    /// chunk artefact, not speech coverage.
    public static let maxCreditedWordSeconds = 3.0
    /// A segment of at least this length with fewer words per second than
    /// `minWordsPerSecond` is treated as dropped speech.
    public static let sparseSegmentSeconds = 5.0
    /// Conversational speech runs at 2-3 words per second. On the 2026-10-16 field recording a
    /// prompted chunk of 22 s came back as 10 words (0.45 per second, 0.7 s of word timings) while
    /// the same chunk decoded to 27 words without the prompt, so 0.25 was too lax.
    public static let minWordsPerSecond = 1.0

    /// True when a segment is too long and too empty to count as coverage (see `coverage`).
    public static func isSparse(start: Double, end: Double, wordCount: Int) -> Bool {
        let duration = end - start
        return duration >= sparseSegmentSeconds && Double(wordCount) / duration < minWordsPerSecond
    }

    /// Time ranges the transcript genuinely accounts for. Words count, except
    /// one longer than 3 s; a segment counts as a whole (it bridges the gaps
    /// between its words) unless it is long and nearly empty (< 1 word per
    /// second over >= 5 s). Result is sorted and merged.
    public static func coverage(
        fromWords words: [(start: Double, end: Double)],
        segments: [(start: Double, end: Double, wordCount: Int)]
    ) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        for w in words where w.end >= w.start && w.end - w.start <= maxCreditedWordSeconds {
            ranges.append(w.start...w.end)
        }
        for s in segments where s.end > s.start && s.wordCount > 0 {
            let duration = s.end - s.start
            if isSparse(start: s.start, end: s.end, wordCount: s.wordCount) { continue }
            ranges.append(s.start...s.end)
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for r in ranges {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else { merged.append(r) }
        }
        return merged
    }

    // MARK: - Collapsed chunks

    /// Voice-activity chunks whose first-pass decode is far too short for their length: at least
    /// `sparseSegmentSeconds` long with fewer than `minWordsPerSecond` words per second. This is
    /// the #3579 root-cause signature (the vocabulary prompt collapses a chunk to a few words),
    /// and it is found from word counts, not loudness: on the field recording one such chunk was
    /// a quiet speaker at the room's noise floor, which no RMS threshold can tell from silence.
    /// `chunks` are (start, end, words) in seconds; overlapping results are merged.
    public static func collapsedChunks(_ chunks: [(start: Double, end: Double, words: Int)]) -> [ClosedRange<Double>] {
        let found = chunks
            .filter { $0.end > $0.start && isSparse(start: $0.start, end: $0.end, wordCount: $0.words) }
            .map { $0.start...$0.end }
        return mergedRanges(found)
    }

    /// Sorted union of `ranges`; touching or overlapping ranges become one.
    public static func mergedRanges(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var merged: [ClosedRange<Double>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else { merged.append(r) }
        }
        return merged
    }

    // MARK: - Duplicates

    /// A re-decoded segment repeats the first pass when at least this share of its word
    /// trigrams already occurs in the nearby first-pass text.
    public static let duplicateShare = 0.5

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// True when `candidate` says what `existing` already says: half or more of its word
    /// trigrams occur in `existing` (lowercased, punctuation ignored). A candidate of one or
    /// two words counts as repeated when it occurs as a contiguous run. Empty text is repeated.
    ///
    /// Why: on a model whose timestamps squeeze a chunk's words towards its start, the rest of
    /// the chunk looks uncovered and decodes again to the same words (#3579 acceptance: 27 %
    /// of the words were doubled before this check).
    public static func isAlreadyTranscribed(_ candidate: String, in existing: String) -> Bool {
        let c = words(candidate)
        guard !c.isEmpty else { return true }
        let e = words(existing)
        guard !e.isEmpty else { return false }
        if c.count < 3 {
            guard e.count >= c.count else { return false }
            return (0...(e.count - c.count)).contains { Array(e[$0..<($0 + c.count)]) == c }
        }
        func trigrams(_ w: [String]) -> [String] {
            w.count < 3 ? [] : (0...(w.count - 3)).map { w[$0..<($0 + 3)].joined(separator: " ") }
        }
        let known = Set(trigrams(e))
        let mine = trigrams(c)
        let repeated = mine.filter(known.contains).count
        return Double(repeated) / Double(mine.count) >= duplicateShare
    }

    // MARK: - Choosing a re-decode

    /// Index of the candidate with the most words among those that look sane
    /// (compression ratio <= 2.4, mean log-prob >= -1.0); nil when no sane
    /// candidate has any words. Ties keep the earliest.
    public static func pickBest(candidates: [(words: Int, compressionRatio: Double, avgLogProb: Double)]) -> Int? {
        var best: Int? = nil
        for (i, c) in candidates.enumerated()
        where c.words > 0 && c.compressionRatio <= 2.4 && c.avgLogProb >= -1.0 {
            if best == nil || c.words > candidates[best!].words { best = i }
        }
        return best
    }
}
