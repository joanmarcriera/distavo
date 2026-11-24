// TwoMeetingsSplit.swift — "Was this two meetings?" at the end of a built-in recording.
//
// Seen on 24 Nov 2026: one recording of 107 minutes held a one-to-one, about 100 seconds in which nobody
// spoke, and then a larger team meeting. The speakers question was answered once, so one speaker count was
// forced on both meetings and the speaker labels came out scrambled. The Notes window can split a recording
// afterwards (`RecordingSplitAction`, D077), but only once a note exists and the damage is done. This asks at
// Stop, before anything is transcribed, so each half gets its own participants and its own speaker count.
//
// Pure, like `SilenceMonitor` and `MeetingEndPolicy`: the recorder controller feeds `TwoMeetingsDetector` the
// same once-a-second microphone + system-audio RMS it feeds `SilenceMonitor`, with a monotonic clock reading;
// at Stop `suggestion()` answers with zero or one gap. Nothing here reads a clock or the audio device.
//
// The rule (`Policy`), and why:
//  1. Duration alone never asks. A two-hour workshop with no gap is one meeting.
//  2. The recording is at least 60 minutes long. In a short recording a minute of quiet is somebody fetching
//     a document; and the question costs a click on every such recording.
//  3. A quiet gap of at least 60 seconds (the same minimum as `RecordingSplit.minSilenceSeconds`), with at
//     least 10 minutes of SOUND (seconds with speech, not elapsed time) on each side: a late start, a silent
//     lobby and a silent tail are not two meetings. Of several gaps the longest is offered, the first on a tie.
//  4. "Quiet" is measured against this recording, per channel, not against the fixed noise gate. Measured on
//     the real case: during the gap the microphone sat at 0.0024-0.0035 RMS, straddling
//     `StereoBalancer.noiseGate` (0.003), so the gate alone found no 60 quiet seconds in a row; speech was
//     0.015-0.06. A channel's threshold is the geometric mean of its 10th and 90th percentile second (half-way
//     between its noise floor and its speech on a dB scale), never below the gate. A channel whose 90th
//     percentile is under the gate, or under 4x its 10th (an idle microphone humming, all zeros in an
//     in-person meeting), carries no speech and is ignored. No channel with speech = nothing is offered.
//  5. A noise of at most 2 seconds between two quiet stretches (a chair, a keyboard, a door) does not end the
//     gap, as long as at least 80% of the gap is quiet. Without the 80% slow speech with pauses would qualify.
//  6. Time nobody measured (the tick did not run for more than 5 seconds: a dialog was open) and levels that
//     are not numbers count as sound. Unknown is never a gap.
//  7. Nothing is dropped. The cut is one point, `keepSilence` (10 s) before the end of the gap: the first half
//     keeps the quiet (the pipeline's `TrailingSilence` trims a silent tail, #2677), the second opens with 10 s
//     of it. An earlier version left the middle of the gap in neither half; a review on 24 Nov 2026 showed three
//     ways that middle can hold speech (rule 5 lets 20% of a gap be noise, rule 4 calls soft speech quiet, and
//     a stalled audio device makes the tick clock run ahead of the file), and the original is replaced by the
//     first half, so it would have been gone. 10 s rather than the 2 s of `RecordingSplit.paddingSeconds`
//     because these times come from the once-a-second tick, not from the file.
//  8. `splitPart` refuses (and the take is saved as one) when the file is more than `maxClockDrift` (5 s)
//     longer or shorter than the ticks said, or when the two halves do not add up to the take frame for frame.
//
// The file side (`splitPart`, `routeSidecars`) reuses `RecordingSplit.cut` and `splitMarks`. It runs on the
// take while it is still a `.part`, so both halves are balanced and published by the recorder's normal finalise.
// Off unless `recording.ask_two_meetings` is on (off on decode and for fresh installs).

import AVFoundation
import Foundation

/// Collects the recorder's once-a-second levels for `TwoMeetingsSplit`. About 8 bytes per second of recording.
public struct TwoMeetingsDetector: Sendable {
    /// Longest stretch between two samples that still counts as measured (rule 6).
    public var maxSampleGap: TimeInterval
    public private(set) var samples: [TwoMeetingsSplit.Sample] = []
    /// Recording time covered so far.
    public private(set) var elapsed: TimeInterval = 0
    private var last: TimeInterval

    public init(now: TimeInterval, maxSampleGap: TimeInterval = 5) {
        self.last = now
        self.maxSampleGap = maxSampleGap
    }

    /// One sample: the RMS of each channel since the previous call.
    public mutating func ingest(mic: Float, system: Float, at now: TimeInterval) {
        guard now.isFinite, now > last else { return }
        let seconds = now - last
        last = now
        elapsed += seconds
        samples.append(.init(seconds: seconds, mic: mic, system: system,
                             measured: seconds <= maxSampleGap && mic.isFinite && system.isFinite))
    }

    public func suggestion(policy: TwoMeetingsSplit.Policy = .init()) -> TwoMeetingsSplit.Suggestion? {
        TwoMeetingsSplit.suggestion(samples: samples, policy: policy)
    }
}

public enum TwoMeetingsSplit {

    public struct Sample: Equatable, Sendable {
        public var seconds: TimeInterval
        public var mic: Float
        public var system: Float
        /// False for a stretch nobody measured or a level that is not a number: counted as sound.
        public var measured: Bool

        public init(seconds: TimeInterval, mic: Float, system: Float, measured: Bool = true) {
            self.seconds = seconds; self.mic = mic; self.system = system; self.measured = measured
        }
    }

    public struct Policy: Equatable, Sendable {
        public var minDuration: TimeInterval = 3600
        public var minGap: TimeInterval = RecordingSplit.minSilenceSeconds
        public var minSoundEachSide: TimeInterval = 600
        /// Longest noise inside a gap that does not end it (rule 5).
        public var maxBlip: TimeInterval = 2
        public var minQuietShare = 0.8
        public var gate: Float = StereoBalancer.noiseGate
        /// A channel carries speech when its 90th percentile is at least this many times its 10th (rule 4).
        public var minRange: Float = 4
        public init() {}
    }

    /// Silence left at the start of the second half (rule 7).
    public static let keepSilence = 10.0
    /// Largest difference between the tick clock and the file that still allows a split (rule 8).
    public static let maxClockDrift = 5.0

    public struct Suggestion: Equatable, Sendable {
        /// The quiet gap, in seconds from the start of the recording.
        public var gap: RecordingSplit.Silence
        /// Recording time covered by the samples.
        public var duration: TimeInterval
        public var cut: RecordingSplit.Cut { TwoMeetingsSplit.cut(gap: gap, duration: duration) }

        public init(gap: RecordingSplit.Silence, duration: TimeInterval) {
            self.gap = gap; self.duration = duration
        }
    }

    /// The two ranges for a gap, meeting at one point `keepSilence` before the gap ends (half-way in a gap
    /// shorter than twice that): every second of the take is in exactly one half (rule 7).
    public static func cut(gap: RecordingSplit.Silence, duration: Double) -> RecordingSplit.Cut {
        let at = gap.end - min(keepSilence, gap.duration / 2)
        return .init(first: 0...at, second: at...max(duration, gap.end))
    }

    // MARK: The policy

    public static func suggestion(samples: [Sample], policy: Policy = .init()) -> Suggestion? {
        let duration = samples.reduce(0) { $0 + $1.seconds }
        guard duration >= policy.minDuration else { return nil }

        // Rule 4: per-channel threshold, or nil for a channel without speech.
        func threshold(_ value: (Sample) -> Float) -> Float? {
            let sorted = samples.filter(\.measured).map(value).sorted()
            guard !sorted.isEmpty else { return nil }
            let low = sorted[Int(Double(sorted.count - 1) * 0.1)], high = sorted[Int(Double(sorted.count - 1) * 0.9)]
            guard high >= policy.gate, high >= policy.minRange * low else { return nil }
            return max(policy.gate, (low * high).squareRoot())
        }
        let micThreshold = threshold(\.mic), systemThreshold = threshold(\.system)
        guard micThreshold != nil || systemThreshold != nil else { return nil }
        func isQuiet(_ s: Sample) -> Bool {
            s.measured && (micThreshold.map { s.mic < $0 } ?? true) && (systemThreshold.map { s.system < $0 } ?? true)
        }

        // Runs of quiet / sound, with their start time.
        struct Run { var quiet: Bool; var start: Double; var end: Double; var length: Double { end - start } }
        var runs: [Run] = []
        var t = 0.0
        for s in samples {
            let q = isQuiet(s)
            if let i = runs.indices.last, runs[i].quiet == q { runs[i].end = t + s.seconds }
            else { runs.append(Run(quiet: q, start: t, end: t + s.seconds)) }
            t += s.seconds
        }

        // Rule 5: quiet runs joined across short noises; a joined stretch that is not quiet enough falls back
        // to its longest quiet run.
        var gaps: [RecordingSplit.Silence] = []
        var i = 0
        while i < runs.count {
            guard runs[i].quiet else { i += 1; continue }
            var j = i
            var quietSeconds = runs[i].length
            var longest = runs[i]
            while j + 2 < runs.count, runs[j + 1].length <= policy.maxBlip {
                j += 2
                quietSeconds += runs[j].length
                if runs[j].length > longest.length { longest = runs[j] }
            }
            let joined = RecordingSplit.Silence(start: runs[i].start, end: runs[j].end)
            gaps.append(quietSeconds >= policy.minQuietShare * joined.duration
                        ? joined : .init(start: longest.start, end: longest.end))
            i = j + 1
        }

        // Rule 3: long enough, with enough sound on each side; the longest, the first on a tie.
        func sound(from: Double, to: Double) -> Double {
            runs.filter { !$0.quiet }.reduce(0) { $0 + max(0, min($1.end, to) - max($1.start, from)) }
        }
        var best: RecordingSplit.Silence?
        for gap in gaps where gap.duration >= policy.minGap {
            guard sound(from: 0, to: gap.start) >= policy.minSoundEachSide,
                  sound(from: gap.end, to: duration) >= policy.minSoundEachSide else { continue }
            if best.map({ gap.duration > $0.duration }) ?? true { best = gap }
        }
        return best.map { Suggestion(gap: $0, duration: duration) }
    }

    // MARK: The question

    /// "52:49", "1:01:01".
    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func length(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s"
    }

    public static func question(for s: Suggestion) -> (title: String, body: String) {
        ("Was this two meetings?",
         "This recording has a quiet gap at \(clock(s.gap.start)) (\(length(s.gap.duration))). "
         + "If one meeting ended there and another began, Distavo can split the recording at the gap and ask "
         + "who was in each, so each gets its own note and its own speakers. "
         + "Either way every second of the recording is kept. (Turn this question off in Settings.)")
    }

    /// Safe answer first, so Return keeps the recording as it is.
    public static let buttonTitles = ["Keep as One", "Split in Two"]
    public static func shouldSplit(buttonIndex: Int) -> Bool { buttonIndex == 1 }

    /// Headings of the speakers question for each half.
    public static func speakersHeadings(for s: Suggestion) -> (first: String, second: String) {
        ("Who was in the first meeting? (until \(clock(s.gap.start)))",
         "Who was in the second meeting? (from \(clock(s.gap.end)))")
    }

    // MARK: The files

    public enum SplitError: Error, Equatable { case nameTaken, clockMismatch, framesMissing }

    /// Cuts a take that is still a `.part` in two at `cut.second.lowerBound`: `secondPart` receives everything
    /// from there to the end of the file and `part` is then replaced by everything before it, so no frame of
    /// the take is in neither half (`cut.first.upperBound` is not used: a cut with a hole is closed). Same file
    /// format, no resampling (`RecordingSplit.cut`). Both halves are written and counted before `part` is
    /// replaced; a failure (rule 8 included) leaves `part` as it was and no `secondPart`.
    /// A crash between the two steps leaves the whole take plus the second half: nothing is lost.
    public static func splitPart(part: URL, cut: RecordingSplit.Cut, secondPart: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: secondPart.path) else { throw SplitError.nameTaken }
        let (total, rate): (Int64, Double) = try {
            let f = try AVAudioFile(forReading: part)
            return (f.length, f.processingFormat.sampleRate)
        }()
        let seconds = Double(total) / rate
        guard abs(seconds - cut.second.upperBound) <= maxClockDrift else { throw SplitError.clockMismatch }
        let at = cut.second.lowerBound
        let firstTemp = part.deletingLastPathComponent()
            .appendingPathComponent(".split-first-\(UUID().uuidString).part")   // not a recording extension
        do {
            let second = try RecordingSplit.cut(source: part, range: at...max(seconds, at), destination: secondPart)
            let first = try RecordingSplit.cut(source: part, range: 0...at, destination: firstTemp)
            guard first + second == total else { throw SplitError.framesMissing }
            _ = try fm.replaceItemAt(part, withItemAt: firstTemp)
        } catch {
            try? fm.removeItem(at: secondPart)
            try? fm.removeItem(at: firstTemp)
            throw error
        }
    }

    /// Typed notes re-timed for the two halves, by the same rule as `RecordingSplit.splitMarks`.
    public static func splitLines(_ lines: [ScratchpadNotes.Line], cut: RecordingSplit.Cut)
        -> (first: [ScratchpadNotes.Line], second: [ScratchpadNotes.Line]) {
        var a: [ScratchpadNotes.Line] = [], b: [ScratchpadNotes.Line] = []
        let mid = (cut.first.upperBound + cut.second.lowerBound) / 2
        for line in lines {
            var l = line
            let t = Double(line.offsetSeconds)
            if t <= cut.first.upperBound || (t < cut.second.lowerBound && t < mid) {
                a.append(l)
            } else {
                l.offsetSeconds = max(0, Int((t - cut.second.lowerBound).rounded(.down)))
                b.append(l)
            }
        }
        return (a, b)
    }

    /// Moves what was typed and marked during the recording to the half its time falls in: `.scratchpad.json`
    /// lines and `.bookmarks.json` marks at or after the cut go to `secondBase`, re-timed to its start. The
    /// people typed in Quick Notes stay with the first half (they are not timed; the second half is asked).
    /// A half with nothing gets no file. Returns how many lines and marks went to the second half.
    @discardableResult
    public static func routeSidecars(workDir: URL, firstBase: String, secondBase: String, cut: RecordingSplit.Cut,
                                     secondSource: String?) throws -> (lines: Int, marks: Int) {
        var moved = (lines: 0, marks: 0)
        // Raw decode: `ScratchpadNotes.load` applies the prompt caps, which are per note, not per recording.
        if let data = try? Data(contentsOf: ScratchpadNotes.url(workDir: workDir, base: firstBase)),
           let notes = try? JSONDecoder().decode(ScratchpadNotes.self, from: data) {
            let (a, b) = splitLines(notes.lines, cut: cut)
            if !b.isEmpty {
                var second = ScratchpadNotes(lines: b)
                second.version = notes.version
                try second.save(workDir: workDir, base: secondBase)
                var first = notes
                first.lines = a
                if a.isEmpty && notes.people == nil { ScratchpadNotes.delete(workDir: workDir, base: firstBase) }
                else { try first.save(workDir: workDir, base: firstBase) }
                moved.lines = b.count
            }
        }
        if let marks = RecordingBookmarks.load(workDir: workDir, base: firstBase) {
            let (a, b) = RecordingSplit.splitMarks(marks.marks, cut: cut)
            if !b.isEmpty {
                try RecordingBookmarks(marks: b, source: secondSource).save(workDir: workDir, base: secondBase)
                if a.isEmpty { RecordingBookmarks.delete(workDir: workDir, base: firstBase) }
                else { try RecordingBookmarks(marks: a, source: marks.source).save(workDir: workDir, base: firstBase) }
                moved.marks = b.count
            }
        }
        return moved
    }
}
