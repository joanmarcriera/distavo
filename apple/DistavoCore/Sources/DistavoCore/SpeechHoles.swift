import Foundation

// Finding audible speech the transcriber dropped (Vikunja #3579).
//
// Field test 2026-10-16 (Catalan, BSC model, 50 min): six stretches of clear speech (RMS as in
// normal talk) had no segment at all, about 3 minutes or 5-6 % of the meeting, including the
// introductions. The embedded transcriber cuts the audio with a voice-activity chunker and drops
// a chunk whose decode fails the quality gates (no-speech, log-probability), silently. This file
// is the pure half of the fix: from the audio's loudness and the segments that came back it finds
// the "holes" worth decoding again without the gates. The decoding itself is in DistavoEmbedded.
//
// A hole is a run of at least `minSeconds` made of windows that are clearly louder than the
// recording's own noise floor and are covered by no segment. A recording of true silence (or of
// steady low noise) has no windows above the threshold, so it has no holes.
public enum SpeechHoles {

    public struct Hole: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var duration: Double { end - start }
        public init(start: Double, end: Double) { self.start = start; self.end = end }
    }

    /// Tunables, named so the tests and the app share them.
    public struct Settings: Equatable, Sendable {
        /// Loudness window length.
        public var windowSeconds = 1.0
        /// Shortest hole worth a second decode.
        public var minSeconds = 8.0
        /// A window counts as sound when its RMS is above `noiseFloor * floorFactor` ...
        public var floorFactor = 2.0
        /// ... and above this absolute RMS (normal speech is 0.02-0.07; room noise is far below).
        public var minimumRMS = 0.008
        /// Quiet windows inside a hole (a breath, a pause) do not split it, up to this many in a row.
        public var bridgeWindows = 2
        public init() {}
    }

    /// RMS of consecutive `windowSeconds` windows of mono `samples` (the last partial window counts).
    public static func windowRMS(samples: [Float], sampleRate: Double, windowSeconds: Double = 1.0) -> [Double] {
        let size = max(1, Int(sampleRate * windowSeconds))
        var out: [Double] = []
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + size)
            var sum = 0.0
            for j in i..<end { sum += Double(samples[j]) * Double(samples[j]) }
            out.append((sum / Double(end - i)).squareRoot())
            i = end
        }
        return out
    }

    /// The recording's own noise level: the median of its quietest fifth of windows.
    public static func noiseFloor(_ rms: [Double]) -> Double {
        guard !rms.isEmpty else { return 0 }
        let quiet = rms.sorted().prefix(max(1, rms.count / 5))
        return quiet[quiet.index(quiet.startIndex, offsetBy: quiet.count / 2)]
    }

    /// Holes in `segments` (start/end seconds) given per-window `rms`.
    public static func find(rms: [Double], segments: [(start: Double, end: Double)],
                            settings: Settings = Settings()) -> [Hole] {
        guard !rms.isEmpty else { return [] }
        let threshold = max(noiseFloor(rms) * settings.floorFactor, settings.minimumRMS)
        let w = settings.windowSeconds
        func covered(_ i: Int) -> Bool {
            let lo = Double(i) * w, hi = lo + w
            // Covered when a segment overlaps more than half the window.
            return segments.contains { min($0.end, hi) - max($0.start, lo) > w / 2 }
        }
        let open = rms.indices.map { rms[$0] > threshold && !covered($0) }

        var holes: [Hole] = []
        var runStart: Int?
        var lastOpen = 0
        var gap = 0
        func close() {
            if let s = runStart {
                let hole = Hole(start: Double(s) * w, end: Double(lastOpen + 1) * w)
                if hole.duration >= settings.minSeconds { holes.append(hole) }
            }
            runStart = nil; gap = 0
        }
        for i in rms.indices {
            if open[i] {
                if runStart == nil { runStart = i }
                lastOpen = i; gap = 0
            } else if runStart != nil {
                gap += 1
                // A window that holds a segment ends the hole; a merely quiet one is a pause.
                if covered(i) || gap > settings.bridgeWindows { close() }
            }
        }
        close()
        return holes
    }

    /// Seconds of `holes` that still have no segment after a second pass (for the note footer).
    public static func uncoveredSeconds(of holes: [Hole], segments: [(start: Double, end: Double)]) -> Double {
        holes.reduce(0) { total, hole in
            let covered = segments.reduce(0.0) { $0 + max(0, min($1.end, hole.end) - max($1.start, hole.start)) }
            return total + max(0, hole.duration - covered)
        }
    }

    /// Whether a re-decoded segment is worth keeping. With the quality gates off the model can
    /// loop or invent text over noise, so the obvious failures are dropped here instead.
    public static func acceptsRecovered(text: String, avgLogprob: Double, compressionRatio: Double) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && compressionRatio <= 2.4 && avgLogprob > -1.6
    }
}
