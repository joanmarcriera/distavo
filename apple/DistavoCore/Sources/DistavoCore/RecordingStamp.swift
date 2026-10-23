// RecordingStamp.swift — when a dropped recording started, from its file name or container metadata
// (Vikunja #4018). Pure: no file system, no clock; the time zone is injected (tests never touch the
// process zone).
//
// Why: a phone export named `interview-22-10-2026-10.00.mp4` used to be dated by the file's creation date
// (the copy time), so a batch from 15-22 Oct was stamped the day it was dropped. Order of evidence:
//   1. a stamp in the file name (`parse`): DD-MM-YYYY-HH.MM, YYYY-MM-DD_HH.MM.SS, YYYYMMDD_HHMMSS, ...
//   2. the container's `creation_time` minus the duration (`start(creation:duration:)`): phones and call
//      apps write the moment the recording ENDED, in UTC.
//   3. nothing (the caller may still fall back to the file system date, as before).
// A file name is attacker-influenceable, so this is for NOTE DATING only; calendar lookup keeps its own
// stricter evidence rule (`Pipeline.exactRecorderNameDate`).
import Foundation

public enum RecordingStamp {

    /// The start encoded in `stem` (a file name without extension), read as local time in `timeZone`.
    /// Rejects impossible dates (31-02), years outside 2000...2100 and a missing time of day.
    public static func parse(_ stem: String, timeZone: TimeZone = .current) -> Date? {
        for (pattern, order) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)) else { continue }
            func num(_ i: Int) -> Int? {
                guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: stem) else { return nil }
                return Int(stem[r])
            }
            guard let a = num(1), let b = num(2), let c = num(3), let hour = num(4), let minute = num(5) else { continue }
            let second = num(6) ?? 0
            let (y, mo, d): (Int, Int, Int)
            switch order {
            case .dmy: (d, mo, y) = (a, b, c)
            case .ymd: (y, mo, d) = (a, b, c)
            }
            if let date = date(year: y, month: mo, day: d, hour: hour, minute: minute, second: second, timeZone: timeZone) {
                return date
            }
        }
        return nil
    }

    /// Start of a recording whose container says it was created (finished) at `creation` and which lasts
    /// `duration` seconds. nil for a non-positive or absurd (> 24 h) duration.
    public static func start(creation: Date, duration: TimeInterval) -> Date? {
        guard duration > 0, duration <= 24 * 3600 else { return nil }
        return creation.addingTimeInterval(-duration)
    }

    /// "Recorded Thu 22 Oct 2026, 10:00, 61 min" (POSIX locale, ASCII digits) for a note header.
    public static func headerLine(start: Date, duration: TimeInterval?, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEE d MMM yyyy, HH:mm"
        var line = "Recorded " + f.string(from: start)
        if let duration, duration >= 30 { line += ", \(Int((duration / 60).rounded())) min" }
        return line
    }

    // MARK: Internals

    private enum Order { case dmy, ymd }

    private static let patterns: [(String, Order)] = [
        // 22-10-2026-10.00, 22-10-2026_10.00.30, 22-10-2026 10:00
        (#"(?<!\d)(\d{2})-(\d{2})-(\d{4})[-_ T](\d{2})[.:h-](\d{2})(?:[.:-](\d{2}))?(?!\d)"#, .dmy),
        // 2026-10-22_10.00.30, 2026-10-22 10.00.30, 2026-10-22T10:00
        (#"(?<!\d)(\d{4})-(\d{2})-(\d{2})[-_ T](\d{2})[.:-](\d{2})(?:[.:-](\d{2}))?(?!\d)"#, .ymd),
        // 20261022_100030, 20261022-1000
        (#"(?<!\d)(\d{4})(\d{2})(\d{2})[_-](\d{2})(\d{2})(\d{2})?(?!\d)"#, .ymd),
    ]

    private static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int,
                             timeZone: TimeZone) -> Date? {
        guard (2000...2100).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let comps = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = cal.date(from: comps) else { return nil }
        // Round trip: 31-02 would otherwise roll over into March; a DST gap hour would shift.
        let back = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard back.year == year, back.month == month, back.day == day, back.hour == hour, back.minute == minute
        else { return nil }
        return date
    }
}

/// One timing line per processed file (Vikunja #4018): where the time went. Pure formatting.
public struct PhaseTimings: Equatable, Sendable {
    public var steps: [(name: String, seconds: Double)] = []
    public init() {}

    public static func == (a: PhaseTimings, b: PhaseTimings) -> Bool {
        a.steps.count == b.steps.count && zip(a.steps, b.steps).allSatisfy { $0.name == $1.name && $0.seconds == $1.seconds }
    }

    public mutating func add(_ name: String, seconds: Double) { steps.append((name, max(0, seconds))) }

    /// "Timing: load 3 s, asr 120 s, summarise 41 s, total 164 s" (numbers only: no file names, no content).
    public var logLine: String {
        guard !steps.isEmpty else { return "Timing: none recorded" }
        let parts = steps.map { "\($0.name) \(Int($0.seconds.rounded())) s" }
        let total = Int(steps.reduce(0) { $0 + $1.seconds }.rounded())
        return "Timing: " + parts.joined(separator: ", ") + ", total \(total) s"
    }
}
