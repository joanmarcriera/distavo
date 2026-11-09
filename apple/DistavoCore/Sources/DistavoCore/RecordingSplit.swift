import AVFoundation
import Accelerate
import Foundation

/// Pure core for "Split a recording into two meetings" (Vikunja #6668). No UI, no pipeline wiring: the Notes
/// window action, the live "New meeting" marker and the post-note suggestion build on these pieces.
///
/// Seen on 9 Nov 2026: one 61-minute file held a 13-person project meeting, 2 minutes of silence (48:04 to
/// 50:03) and a 1:1 call. The manual fix was an ffmpeg cut either side of the silence, two sidecars and two
/// reprocesses; this is that recipe without ffmpeg.
///
/// Steps: `windowRMS(of:)` (per-second loudness) -> `silences(...)` (runs of >= 60 s below the same gate
/// as `SilenceMonitor`) -> `candidates(...)` (those whose speaker sets differ on each side, from the
/// timed transcript) -> `ranges(for:duration:)` (the two cuts, a little silence kept either side) ->
/// `cut(source:range:destination:)` (AVFoundation, atomic) -> `halfBases` / `sidecarsToCopy` / `splitMarks`.
/// The original is never touched: the caller keeps it.
public enum RecordingSplit {

    /// Shortest silence offered for a split.
    public static let minSilenceSeconds = 60.0
    /// Silence kept at the end of the first half and the start of the second, so no word is clipped.
    public static let paddingSeconds = 2.0

    public struct Silence: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var duration: Double { end - start }
        public init(start: Double, end: Double) { self.start = start; self.end = end }
    }

    public struct Candidate: Equatable, Sendable {
        public var silence: Silence
        public var speakersBefore: [String]
        public var speakersAfter: [String]
    }

    public struct Cut: Equatable, Sendable {
        public var first: ClosedRange<Double>      // seconds, from 0
        public var second: ClosedRange<Double>     // seconds, to the end
    }

    // MARK: Silences

    /// Runs of at least `minSeconds` of windows at or below `gate`. A run touching the start or the end of
    /// the file is not a split point (it is lead-in or `TrailingSilence`'s job) and is dropped.
    public static func silences(windowRMS: [Float], windowSeconds: Double = 1,
                                gate: Float = StereoBalancer.noiseGate,
                                minSeconds: Double = minSilenceSeconds) -> [Silence] {
        var out: [Silence] = []
        var runStart: Int?
        for (i, v) in windowRMS.enumerated() {
            if v <= gate { if runStart == nil { runStart = i }; continue }
            if let s = runStart {
                let sil = Silence(start: Double(s) * windowSeconds, end: Double(i) * windowSeconds)
                if s > 0, sil.duration >= minSeconds { out.append(sil) }
                runStart = nil
            }
        }
        return out   // an open run reaches the end of the file: dropped on purpose
    }

    /// Per-window loudness (maximum channel RMS), the input of `silences`. One window per `windowSeconds`.
    public static func windowRMS(of url: URL, windowSeconds: Double = 1) throws -> (rms: [Float], duration: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard channels > 0, file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else { return ([], 0) }
        let windowFrames = max(1, Int(format.sampleRate * windowSeconds))
        var windows: [Float] = []
        var pending = 0, pendingMax: Float = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            var offset = 0
            while offset < frames {
                let count = min(windowFrames - pending, frames - offset)
                for ch in 0..<channels {
                    var rms: Float = 0
                    vDSP_rmsqv(data[ch] + offset, 1, &rms, vDSP_Length(count))
                    pendingMax = max(pendingMax, rms)
                }
                pending += count; offset += count
                if pending >= windowFrames { windows.append(pendingMax); pending = 0; pendingMax = 0 }
            }
        }
        if pending > 0 { windows.append(pendingMax) }
        return (windows, Double(file.length) / format.sampleRate)
    }

    // MARK: Candidates

    /// Speaker labels (sorted, unique) with at least one segment inside `[from, to)`, by segment start.
    static func speakers(in segments: [TranscriptSegments.Segment], from: Double, to: Double) -> [String] {
        Array(Set(segments.filter { $0.start >= from && $0.start < to }.compactMap { $0.speaker })).sorted()
    }

    /// The silences whose speaker sets differ before and after. Both sides need a labelled speaker: with no
    /// diarisation there is nothing to compare, so nothing is suggested (the owner can still pick a silence
    /// by hand from `silences`). `duration` bounds the "after" side.
    public static func candidates(silences: [Silence], segments: TranscriptSegments?, duration: Double) -> [Candidate] {
        guard let segs = segments?.segments, !segs.isEmpty else { return [] }
        return silences.compactMap { s in
            let before = speakers(in: segs, from: 0, to: s.start)
            let after = speakers(in: segs, from: s.end, to: max(duration, s.end + 1))
            guard !before.isEmpty, !after.isEmpty, before != after else { return nil }
            return Candidate(silence: s, speakersBefore: before, speakersAfter: after)
        }
    }

    // MARK: Cut

    /// The two ranges for a silence: the first ends `paddingSeconds` into it, the second starts
    /// `paddingSeconds` before it ends (each at most half of the silence, so the ranges never overlap).
    /// nil for a silence outside the file.
    public static func ranges(for silence: Silence, duration: Double) -> Cut? {
        guard silence.start > 0, silence.end < duration, silence.end > silence.start else { return nil }
        let pad = min(paddingSeconds, silence.duration / 2)
        return Cut(first: 0...(silence.start + pad), second: (silence.end - pad)...duration)
    }

    public enum SplitError: Error, Equatable { case emptyRange, outsideFile }

    /// Writes seconds `range` of `source` to `destination` (same file format as the source), through a
    /// temporary file that is renamed only when complete. Returns the frames written.
    @discardableResult
    public static func cut(source: URL, range: ClosedRange<Double>, destination: URL) throws -> Int64 {
        let reader = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = reader.processingFormat.sampleRate
        let start = Int64((range.lowerBound * rate).rounded())
        let end = min(reader.length, Int64((range.upperBound * rate).rounded()))
        guard start >= 0, start < reader.length else { throw SplitError.outsideFile }
        guard end > start else { throw SplitError.emptyRange }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 1 << 16) else {
            throw SplitError.emptyRange
        }
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".split-\(UUID().uuidString)-\(destination.lastPathComponent)")
        do {
            let writer = try AVAudioFile(forWriting: temp, settings: reader.fileFormat.settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            reader.framePosition = start
            var remaining = end - start
            while remaining > 0 {
                let want = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
                try reader.read(into: buffer, frameCount: want)
                guard buffer.frameLength > 0 else { break }
                try writer.write(from: buffer)
                remaining -= Int64(buffer.frameLength)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: destination)
        }
        return end - start
    }

    // MARK: Names and sidecars

    /// Base names of the two halves: `<base> part 1`, `<base> part 2` (spaces are fine: bases already
    /// carry them).
    public static func halfBases(of base: String) -> (first: String, second: String) {
        ("\(base) part 1", "\(base) part 2")
    }

    /// The per-recording sidecars a half inherits: what the owner TOLD Distavo (speakers, language, template).
    /// Everything derived from the audio (transcript, segments, markers, `.state`) is rebuilt per half, and
    /// `.bookmarks.json` is re-timed by `splitMarks`. Pure: `names` are the file names in the work folder.
    public static func sidecarsToCopy(names: [String], base: String) -> [String] {
        let wanted = [SpeakerHintsNames.suffix, ".language.json"]
        return names.filter { n in wanted.contains { n == base + $0 } }.sorted()
    }

    /// Key moments re-timed for the two halves: marks inside `first` stay, marks inside `second` move back
    /// by its start; a mark in the dropped middle of the silence goes to the nearer half.
    public static func splitMarks(_ marks: [RecordingBookmarks.Mark], cut: Cut)
        -> (first: [RecordingBookmarks.Mark], second: [RecordingBookmarks.Mark]) {
        var a: [RecordingBookmarks.Mark] = [], b: [RecordingBookmarks.Mark] = []
        let mid = (cut.first.upperBound + cut.second.lowerBound) / 2
        for m in marks {
            let t = m.offsetSeconds
            if t <= cut.first.upperBound || (t < cut.second.lowerBound && t < mid) {
                a.append(.init(offsetSeconds: min(t, cut.first.upperBound), label: m.label))
            } else {
                b.append(.init(offsetSeconds: max(0, t - cut.second.lowerBound), label: m.label))
            }
        }
        return (a, b)
    }
}

/// File-name suffixes shared with `SpeakerHints` (kept here so the split core has no second copy of the literal).
enum SpeakerHintsNames { static let suffix = ".speakers.json" }
