import Foundation
import WhisperKit
import DistavoCore

/// Re-decodes audible stretches the first Whisper pass left empty (Vikunja
/// #3579). Root cause, measured on a real recording: with a vocabulary prompt
/// the Catalan fine-tune emits ~1 word for a whole 20–30 s VAD chunk (one
/// segment, one "word" spanning the chunk). The no-speech and log-prob gates
/// never fire, WhisperKit keeps the result, and the speech is simply missing.
/// The same chunk decodes to 24–68 words without the prompt.
///
/// Flow (Whisper path only — Parakeet has neither prompt nor VAD chunking):
///   1. `SpeechCoverage.holes` finds loud-but-uncovered stretches from the
///      16 kHz audio and the first pass's word timings.
///   2. Each stretch (padded 0.5 s, split into windows of at most 28 s) is
///      decoded with the same language options, no prompt, no VAD chunking —
///      plain and gain-normalised to RMS 0.1 — and `SpeechCoverage.pickBest`
///      chooses.
///   3. Recovered segments replace the first pass's near-empty ones and are
///      merged in time order, before diarisation.
///
/// Best effort by design: the caller treats any throw as "keep the original
/// results". The planning/merging helpers are pure and unit-tested; only
/// `recover` touches a loaded `WhisperKit`.
enum HoleRecovery {
    /// Padding added on both sides of a hole before decoding.
    static let padSeconds = 0.5
    /// Longest slice decoded at once (a Whisper window is 30 s).
    static let maxWindowSeconds = 28.0
    /// RMS the second candidate is normalised to.
    static let targetRMS: Float = 0.1
    /// First-pass segments with at most this many words, lying mostly inside a
    /// recovered hole, are replaced by the recovery.
    static let replaceableWordCount = 2

    struct Outcome {
        var results: [TranscriptionResult]
        /// Seconds of audio re-decoded to non-empty text.
        var recoveredSeconds = 0.0
        /// Seconds of audible audio for which no candidate produced text.
        var emptySeconds = 0.0
        var holeCount = 0
        /// Seconds whose re-decode only repeated text the first pass already had (timestamps squeezed, not dropped).
        var duplicateSeconds = 0.0

        /// Sentences for the note's provenance line (`footer_notes`); empty when there were no holes.
        var footerNotes: [String] {
            HoleRecovery.footerNotes(recoveredSeconds: recoveredSeconds, emptySeconds: emptySeconds)
        }
    }

    // MARK: - Pure helpers

    static func footerNotes(recoveredSeconds: Double, emptySeconds: Double) -> [String] {
        var notes: [String] = []
        if recoveredSeconds >= 0.5 {
            notes.append("Recovered \(Int(recoveredSeconds.rounded())) s of speech the first pass missed.")
        }
        if emptySeconds >= 0.5 {
            notes.append("\(Int(emptySeconds.rounded())) s of audible audio could not be transcribed.")
        }
        return notes
    }

    /// Padded decode windows for a hole: clamped to the recording and split
    /// into equal pieces no longer than `maxWindowSeconds`.
    static func windows(for hole: ClosedRange<Double>, duration: Double) -> [ClosedRange<Double>] {
        let lo = max(0, hole.lowerBound - padSeconds)
        let hi = min(duration, hole.upperBound + padSeconds)
        guard hi > lo else { return [] }
        let count = Int(((hi - lo) / maxWindowSeconds).rounded(.up))
        let step = (hi - lo) / Double(max(1, count))
        return (0..<max(1, count)).map { lo + Double($0) * step ... lo + Double($0 + 1) * step }
    }

    static func wordCount(_ text: String) -> Int {
        EmbeddedResultMapper.cleanText(text).split(whereSeparator: \.isWhitespace).count
    }

    /// Scale `samples` to the target RMS, clipped to [-1, 1]. Silence is returned unchanged.
    static func gainNormalised(_ samples: [Float], targetRMS: Float = HoleRecovery.targetRMS) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var sum: Double = 0
        for s in samples { sum += Double(s) * Double(s) }
        let rms = Float((sum / Double(samples.count)).squareRoot())
        guard rms > 1e-6 else { return samples }
        let gain = targetRMS / rms
        return samples.map { max(-1, min(1, $0 * gain)) }
    }

    /// What the first pass genuinely covers (collapsed long "words" excluded).
    static func coverage(of segments: [TranscriptionSegment]) -> [ClosedRange<Double>] {
        let words = segments.flatMap { $0.words ?? [] }.map { (start: Double($0.start), end: Double($0.end)) }
        let segs = segments.map { (start: Double($0.start), end: Double($0.end), wordCount: wordCount($0.text)) }
        return SpeechCoverage.coverage(fromWords: words, segments: segs)
    }

    /// Moves a decoded slice's segments (and words) onto the recording's clock.
    static func shifted(_ segments: [TranscriptionSegment], by offset: Double) -> [TranscriptionSegment] {
        let shift = Float(offset)
        return segments.compactMap { original in
            guard wordCount(original.text) > 0 else { return nil }
            var s = original
            s.start += shift
            s.end += shift
            s.words = original.words?.map { w in
                var w = w
                w.start += shift
                w.end += shift
                return w
            }
            return s
        }
    }

    /// Seconds of context on each side of a window whose first-pass text counts as "nearby".
    /// Generous because the Catalan fine-tune can squeeze a chunk's timestamps towards its start.
    static let neighbourSeconds = 90.0

    /// The first-pass text of segments within `neighbourSeconds` of `window`, in order, leaving
    /// out the ones a recovery of this window replaces (their words must survive in the recovery).
    static func neighbourText(of window: ClosedRange<Double>, in segments: [TranscriptionSegment],
                              collapsed: [ClosedRange<Double>] = []) -> String {
        let lo = window.lowerBound - neighbourSeconds, hi = window.upperBound + neighbourSeconds
        return segments
            .filter { Double($0.end) >= lo && Double($0.start) <= hi && !isReplaceable($0, by: window, collapsed: collapsed) }
            .map(\.text).joined(separator: " ")
    }

    /// A first-pass segment a recovery of `window` replaces: one that starts inside a collapsed
    /// chunk the window overlaps, or a near-empty (<= 2 words) or long sparse segment lying
    /// mostly inside the window.
    static func isReplaceable(_ seg: TranscriptionSegment, by window: ClosedRange<Double>,
                              collapsed: [ClosedRange<Double>] = []) -> Bool {
        let start = Double(seg.start)
        if collapsed.contains(where: { $0.contains(start) && $0.overlaps(window) }) { return true }
        let words = wordCount(seg.text)
        guard words <= replaceableWordCount
                || SpeechCoverage.isSparse(start: start, end: Double(seg.end), wordCount: words)
        else { return false }
        let duration = Double(seg.end - seg.start)
        return duration <= 0 ? window.contains(start) : overlap(seg, window) >= 0.5 * duration
    }

    /// (start, end, words) of each voice-activity chunk of the first pass. WhisperKit returns one
    /// result per chunk with `seekTime` at the chunk start; a chunk ends where the next begins.
    /// Results without a seek time (no chunking) give nothing.
    static func chunkSpans(of results: [TranscriptionResult], duration: Double) -> [(start: Double, end: Double, words: Int)] {
        let starts = results.map { $0.seekTime.map(Double.init) }
        var spans: [(start: Double, end: Double, words: Int)] = []
        for (i, result) in results.enumerated() {
            guard let start = starts[i] else { continue }
            let end = starts[(i + 1)...].compactMap { $0 }.first { $0 > start } ?? duration
            spans.append((start, end, result.segments.reduce(0) { $0 + wordCount($1.text) }))
        }
        return spans
    }

    private static func overlap(_ s: TranscriptionSegment, _ r: ClosedRange<Double>) -> Double {
        max(0, min(Double(s.end), r.upperBound) - max(Double(s.start), r.lowerBound))
    }

    /// Replaces near-empty first-pass segments inside the recovered windows by
    /// the recovered ones and returns everything in time order. A recovered
    /// segment that mostly overlaps a kept, substantial first-pass segment is
    /// dropped instead, so no stretch is transcribed twice.
    static func merged(original: [TranscriptionSegment],
                       recovered: [(window: ClosedRange<Double>, segments: [TranscriptionSegment])],
                       collapsed: [ClosedRange<Double>] = []
    ) -> [TranscriptionSegment] {
        let windows = recovered.map(\.window)
        let kept = original.filter { seg in !windows.contains { isReplaceable(seg, by: $0, collapsed: collapsed) } }
        // `kept` excludes everything replaced, so a recovery is a duplicate only of what stays.
        let substantial = kept.filter {
            let n = wordCount($0.text)
            return n > replaceableWordCount && !SpeechCoverage.isSparse(start: Double($0.start), end: Double($0.end), wordCount: n)
        }
        var out = kept
        for (_, segments) in recovered {
            for seg in segments {
                let duration = Double(seg.end - seg.start)
                let duplicate = duration > 0 && substantial.contains {
                    overlap($0, Double(seg.start)...Double(seg.end)) >= 0.5 * duration
                }
                if !duplicate { out.append(seg) }
            }
        }
        out.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        for i in out.indices { out[i].id = i }
        return out
    }

    // MARK: - WhisperKit

    /// Finds and re-decodes dropped speech. `options` are the first pass's
    /// options (language plan included); the prompt and VAD chunking are
    /// removed here. Returns the input unchanged when there is no hole.
    static func recover(
        whisper: WhisperKit, audio: [Float], results: [TranscriptionResult],
        options: DecodingOptions, report: @Sendable (String) -> Void
    ) async -> Outcome {
        var outcome = Outcome(results: results)
        let rate = Double(WhisperKit.sampleRate)
        let duration = Double(audio.count) / rate
        let firstPass = results.flatMap(\.segments)
        let rms = SpeechCoverage.rmsFrames(samples: audio, sampleRate: WhisperKit.sampleRate)
        let loudHoles = SpeechCoverage.holes(rms: rms, frameSeconds: 1.0, covered: coverage(of: firstPass))
        // Chunks the prompt collapsed: decoded far too short for their length, loud or not.
        let collapsed = SpeechCoverage.collapsedChunks(chunkSpans(of: results, duration: duration))
        let holes = SpeechCoverage.mergedRanges(loudHoles + collapsed)
        guard !holes.isEmpty else { return outcome }
        outcome.holeCount = holes.count

        let windows = holes.flatMap { windows(for: $0, duration: duration) }
        let total = windows.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        report("Recovering \(Int(total.rounded())) s of speech the first pass dropped…")

        var decodeOptions = options
        decodeOptions.promptTokens = nil
        decodeOptions.chunkingStrategy = nil

        var recovered: [(window: ClosedRange<Double>, segments: [TranscriptionSegment])] = []
        for window in windows {
            let lo = max(0, Int(window.lowerBound * rate))
            let hi = min(audio.count, Int(window.upperBound * rate))
            guard hi > lo else { continue }
            let slice = Array(audio[lo..<hi])
            var candidates: [(segments: [TranscriptionSegment], stats: (words: Int, compressionRatio: Double, avgLogProb: Double))] = []
            for samples in [slice, gainNormalised(slice)] {
                do {
                    let decoded = try await whisper.transcribe(audioArray: samples, decodeOptions: decodeOptions)
                    let segs = decoded.flatMap(\.segments)
                    let words = segs.reduce(0) { $0 + wordCount($1.text) }
                    let ratio = segs.map { Double($0.compressionRatio) }.max() ?? 0
                    let logProb = segs.isEmpty ? 0 : segs.reduce(0.0) { $0 + Double($1.avgLogprob) } / Double(segs.count)
                    candidates.append((segs, (words, ratio, logProb)))
                } catch {
                    report("Recovery of a dropped stretch failed (\(type(of: error))) — keeping the first pass.")
                }
            }
            if let best = SpeechCoverage.pickBest(candidates: candidates.map(\.stats)) {
                let decoded = shifted(candidates[best].segments, by: window.lowerBound)
                // Speech the first pass DID transcribe, but under squeezed timestamps, decodes again
                // here; drop what the nearby first-pass text already says (#3579 duplicate fix).
                let nearby = neighbourText(of: window, in: firstPass, collapsed: collapsed)
                let segments = decoded.filter { !SpeechCoverage.isAlreadyTranscribed($0.text, in: nearby) }
                if decoded.count > 0 && segments.isEmpty { outcome.duplicateSeconds += window.upperBound - window.lowerBound; continue }
                if !segments.isEmpty {
                    recovered.append((window, segments))
                    outcome.recoveredSeconds += window.upperBound - window.lowerBound
                    continue
                }
            }
            outcome.emptySeconds += window.upperBound - window.lowerBound
        }

        guard !recovered.isEmpty else { return outcome }
        let segments = merged(original: firstPass, recovered: recovered, collapsed: collapsed)
        let template = results.first
        outcome.results = [TranscriptionResult(
            text: segments.map(\.text).joined(),
            segments: segments,
            language: template?.language ?? "",
            timings: template?.timings ?? TranscriptionTimings(),
            seekTime: nil)]
        return outcome
    }
}
