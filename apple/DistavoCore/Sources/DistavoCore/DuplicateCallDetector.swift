// DuplicateCallDetector.swift — the same call captured twice (phone + Mac), Vikunja #4014.
//
// Pure and dependency-free. Takes one `CapturedCall` per recording (start time, duration, whether it has a
// participants sheet) and returns the pairs that overlap in time so strongly that they are the same call.
// It decides nothing on disk: the app/pipeline links the notes ("also captured as …") and reuses the
// primary's sheet for the other. No audio, no transcript text is read, so there is nothing sensitive here;
// a fingerprint check can be layered on later as a second opinion on the pairs this returns.
//
// Rules:
//  - Two recordings are the same call when their overlap is at least `minOverlapShare` (default 0.7) of the
//    SHORTER one, and their starts differ by at most `maxStartSkew` (default 10 min). Back-to-back calls
//    (overlap ~0) and a long call that merely contains a short voice memo (skew too big) are not paired.
//  - The primary is the one with a participants sheet; otherwise the longer one; otherwise the live Mac capture;
//    a final tie goes to the earlier base name so the answer is stable.
//  - Container times: Android writes the UTC END time as `creation_time`, so `startFromContainerEnd` gives the start.
import Foundation

public struct CapturedCall: Equatable, Sendable {
    public var base: String
    public var start: Date
    public var durationSeconds: Double
    public var hasParticipantsSheet: Bool
    /// Recorded live by Distavo's own recorder (`Meeting_…`), as opposed to a file dropped into the watch folder.
    public var isLiveCapture: Bool

    public init(base: String, start: Date, durationSeconds: Double,
                hasParticipantsSheet: Bool = false, isLiveCapture: Bool = false) {
        self.base = base; self.start = start; self.durationSeconds = max(0, durationSeconds)
        self.hasParticipantsSheet = hasParticipantsSheet; self.isLiveCapture = isLiveCapture
    }

    public var end: Date { start.addingTimeInterval(durationSeconds) }

    /// For a phone file whose container `creation_time` is the UTC END of the recording.
    public static func startFromContainerEnd(_ end: Date, durationSeconds: Double) -> Date {
        end.addingTimeInterval(-max(0, durationSeconds))
    }
}

public enum DuplicateCallDetector {
    public struct Pair: Equatable, Sendable {
        public var primary: CapturedCall
        public var secondary: CapturedCall
        public var overlapSeconds: Double
    }

    public static let minOverlapShare = 0.7
    public static let maxStartSkew: TimeInterval = 600

    public static func overlap(_ a: CapturedCall, _ b: CapturedCall) -> Double {
        max(0, min(a.end, b.end).timeIntervalSince(max(a.start, b.start)))
    }

    public static func isSameCall(_ a: CapturedCall, _ b: CapturedCall) -> Bool {
        guard a.base != b.base else { return false }
        let shorter = min(a.durationSeconds, b.durationSeconds)
        guard shorter > 0, abs(a.start.timeIntervalSince(b.start)) <= maxStartSkew else { return false }
        return overlap(a, b) / shorter >= minOverlapShare
    }

    /// Which of two same-call recordings is the primary note (see the rules above).
    public static func primaryFirst(_ a: CapturedCall, _ b: CapturedCall) -> (CapturedCall, CapturedCall) {
        if a.hasParticipantsSheet != b.hasParticipantsSheet { return a.hasParticipantsSheet ? (a, b) : (b, a) }
        if abs(a.durationSeconds - b.durationSeconds) > 1 { return a.durationSeconds > b.durationSeconds ? (a, b) : (b, a) }
        if a.isLiveCapture != b.isLiveCapture { return a.isLiveCapture ? (a, b) : (b, a) }
        return a.base <= b.base ? (a, b) : (b, a)
    }

    /// Every duplicate pair, each recording in at most one pair (the best overlap wins), ordered by primary start.
    public static func pairs(in calls: [CapturedCall]) -> [Pair] {
        var candidates: [Pair] = []
        for i in calls.indices {
            for j in calls.indices where j > i && isSameCall(calls[i], calls[j]) {
                let (p, s) = primaryFirst(calls[i], calls[j])
                candidates.append(Pair(primary: p, secondary: s, overlapSeconds: overlap(p, s)))
            }
        }
        var used = Set<String>()
        var out: [Pair] = []
        for c in candidates.sorted(by: { ($0.overlapSeconds, $1.primary.base) > ($1.overlapSeconds, $0.primary.base) }) {
            guard !used.contains(c.primary.base), !used.contains(c.secondary.base) else { continue }
            used.insert(c.primary.base); used.insert(c.secondary.base)
            out.append(c)
        }
        return out.sorted { ($0.primary.start, $0.primary.base) < ($1.primary.start, $1.primary.base) }
    }

    /// The line added to a note: "Also captured as <other base>". Base names only, never a title or content.
    public static func alsoCapturedLine(otherBase: String, isPrimary: Bool) -> String {
        isPrimary ? "Also captured as \(otherBase) (this note is the primary)."
                  : "Also captured as \(otherBase) (that note is the primary)."
    }
}
