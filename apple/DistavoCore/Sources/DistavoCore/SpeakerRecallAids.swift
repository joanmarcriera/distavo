// SpeakerRecallAids.swift — what jogs the memory when the deferred "who was there?" form returns (Vikunja #4021).
//
// Pure and dependency-free (no UI, no audio, no clock, no global time zone). Two pieces:
//  - `contextLine`: "Teams, 15:15–15:30, 15 min" from the call app, the start and the duration.
//  - `distinctiveLines`: per diarised speaker, up to N short lines worth showing next to a name field, each
//    with a 5–10 s clip window the app can hand to `ClipExporter`. Fillers ("yeah, ok") are skipped; lines that
//    carry a number or a proper noun score higher; longer lines win ties up to `maxChars`.
// Everything stays local: the lines come from the recording's own `.segments.json`. The calendar event title
// and attendees remain subject to the existing untrusted-name rules and are not handled here.
import Foundation

public enum SpeakerRecallAids {
    public struct Line: Equatable, Sendable {
        public var text: String
        public var start: Double
        /// Clip window for the ▶ button: from `start`, at most `maxClipSeconds`, at least `minClipSeconds` when the audio allows.
        public var clipStart: Double
        public var clipEnd: Double
    }

    public struct SpeakerLines: Equatable, Sendable {
        public var speaker: String
        public var lines: [Line]
    }

    public static let minClipSeconds = 5.0
    public static let maxClipSeconds = 10.0
    /// A line shorter than this many words is a reaction, not something that identifies a person.
    public static let minWords = 5
    public static let maxChars = 140

    private static let fillers: Set<String> = [
        "yeah", "yes", "yep", "ok", "okay", "right", "sure", "mhm", "mm", "hmm", "uh", "um", "so", "well",
        "and", "but", "the", "a", "i", "you", "it", "that", "is", "thanks", "thank", "cool", "great", "good",
        "no", "not", "just", "like", "see", "now", "then", "to", "of", "in", "on", "we", "they", "he", "she",
    ]

    private static func words(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }.map(String.init)
    }

    /// Higher is more identifying. 0 means "do not show".
    static func score(_ text: String) -> Int {
        let ws = words(text)
        guard ws.count >= minWords else { return 0 }
        let content = ws.filter { !fillers.contains($0.lowercased()) }
        guard content.count >= 3 else { return 0 }
        var s = min(ws.count, 20) / 4
        for (i, w) in ws.enumerated() {
            if w.contains(where: \.isNumber) { s += 3 }
            else if i > 0, let f = w.first, f.isUppercase, w != "I", !w.hasPrefix("I'") { s += 3 }
        }
        return s
    }

    private static func trimmed(_ text: String) -> String {
        let t = TranscriptCleaner.normaliseSpace(text)
        guard t.count > maxChars else { return t }
        let cut = t.prefix(maxChars)
        let atSpace = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return atSpace + "…"
    }

    public static func distinctiveLines(segments: [TranscriptSegments.Segment], perSpeaker: Int = 3,
                                        audioSeconds: Double? = nil) -> [SpeakerLines] {
        var bySpeaker: [String: [(score: Int, seg: TranscriptSegments.Segment)]] = [:]
        var order: [String] = []
        for seg in segments {
            guard let sp = seg.speaker, !sp.isEmpty else { continue }
            let s = score(seg.text)
            guard s > 0 else { continue }
            if bySpeaker[sp] == nil { order.append(sp) }
            bySpeaker[sp, default: []].append((s, seg))
        }
        return order.sorted().map { sp in
            let best = (bySpeaker[sp] ?? [])
                .sorted { ($0.score, -$0.seg.start) > ($1.score, -$1.seg.start) }
                .prefix(max(0, perSpeaker))
                .sorted { $0.seg.start < $1.seg.start }
            let lines = best.map { item -> Line in
                let seg = item.seg
                let length = min(max(seg.end - seg.start, minClipSeconds), maxClipSeconds)
                var end = seg.start + length
                if let total = audioSeconds { end = min(end, total) }
                return Line(text: trimmed(seg.text), start: seg.start, clipStart: seg.start, clipEnd: max(end, seg.start))
            }
            return SpeakerLines(speaker: sp, lines: lines)
        }.filter { !$0.lines.isEmpty }
    }

    /// "Teams, 15:15–15:30, 15 min" (app omitted when unknown). The time zone is injected, never read globally.
    public static func contextLine(callApp: String?, start: Date, durationSeconds: Double, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        func hm(_ d: Date) -> String {
            let c = cal.dateComponents([.hour, .minute], from: d)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        let end = start.addingTimeInterval(max(0, durationSeconds))
        let minutes = max(1, Int((durationSeconds / 60).rounded()))
        let app = (callApp ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (app.isEmpty ? "" : app + ", ") + "\(hm(start))–\(hm(end)), \(minutes) min"
    }
}
