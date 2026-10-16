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

    private static func overlap(_ s: TranscriptionSegment, _ r: ClosedRange<Double>) -> Double {
        max(0, min(Double(s.end), r.upperBound) - max(Double(s.start), r.lowerBound))
    }

    /// Replaces near-empty first-pass segments inside the recovered windows by
    /// the recovered ones and returns everything in time order. A recovered
    /// segment that mostly overlaps a kept, substantial first-pass segment is
    /// dropped instead, so no stretch is transcribed twice.
    static func merged(original: [TranscriptionSegment],
                       recovered: [(window: ClosedRange<Double>, segments: [TranscriptionSegment])]
    ) -> [TranscriptionSegment] {
        let windows = recovered.map(\.window)
        let kept = original.filter { seg in
            let duration = Double(seg.end - seg.start)
            guard wordCount(seg.text) <= replaceableWordCount else { return true }
            return !windows.contains { duration <= 0 ? $0.contains(Double(seg.start)) : overlap(seg, $0) >= 0.5 * duration }
        }
        let substantial = kept.filter { wordCount($0.text) > replaceableWordCount }
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
        let holes = SpeechCoverage.holes(rms: rms, frameSeconds: 1.0, covered: coverage(of: firstPass))
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
                let segments = shifted(candidates[best].segments, by: window.lowerBound)
                if !segments.isEmpty {
                    recovered.append((window, segments))
                    outcome.recoveredSeconds += window.upperBound - window.lowerBound
                    continue
                }
            }
            outcome.emptySeconds += window.upperBound - window.lowerBound
        }

        guard !recovered.isEmpty else { return outcome }
        let segments = merged(original: firstPass, recovered: recovered)
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
