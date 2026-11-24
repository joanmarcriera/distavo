// DayLog.swift — one file to read at night instead of twelve notes (D102).
//
// For one day: `notes/day-logs/YYYY-MM-DD-day.md` with a timeline of that day's notes (start time, title
// linked to the note, length, template), the open action items gathered from them, the SPEAKER_nn labels
// still unnamed and the "Check this note" warnings (`NoteWarnings`). The notes come from
// `NotesLibrary.scan` (read only, unchanged), whose listing does not recurse, so the subfolder keeps day logs
// out of the Notes window and the search index. Open actions are written as plain bullets, never "- [ ]":
// `ActionItems.scan` does recurse, and a checkbox copy would list every task twice. Links are relative
// ("../<note>.md", percent-encoded). Same notes in, same bytes out (no clock in the file); a day with no
// notes still gets a file that says so. Frontmatter `type: day-log`. Pure apart from `write`.
// Triggers (app): menu "Write Today's Day Log" and `distavo://daylog?date=YYYY-MM-DD` (`AutomationCommand`).

import Foundation

public enum DayLog {
    public static let folderName = "day-logs"
    public static let noNotes = "No notes for this day."

    public static func url(day: Date, notesDir: URL, timeZone: TimeZone) -> URL {
        notesDir.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("\(NoteFrontmatter.dateString(day, timeZone: timeZone))-day.md")
    }

    /// Writes (or rewrites) the day's log atomically and returns its URL. A log on disk that differs from the
    /// new one (edited by hand, or written before more notes arrived) is first kept as its `.prev-` backup, so
    /// a rewrite never loses an edit. `onlyIfMissing` (a `distavo://daylog` link) leaves an existing log as it is.
    @discardableResult
    public static func write(day: Date, notesDir: URL, workDir: URL, timeZone: TimeZone = .current,
                             onlyIfMissing: Bool = false, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let target = url(day: day, notesDir: notesDir, timeZone: timeZone)
        if onlyIfMissing, fm.fileExists(atPath: target.path) { return target }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = render(day: day, notesDir: notesDir, workDir: workDir, timeZone: timeZone)
        if let old = try? String(contentsOf: target, encoding: .utf8) {
            if old == text { return target }
            _ = try NoteVersions.keepPrevious(note: target, now: now)
        }
        try text.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    /// A strict `yyyy-MM-dd` (a real calendar day) at midnight in `timeZone`, else nil.
    public static func date(fromISO s: String, timeZone: TimeZone) -> Date? {
        guard s.utf8.count == 10, s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        var c = DateComponents(); c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        guard let d = cal.date(from: c) else { return nil }
        let back = cal.dateComponents([.year, .month, .day], from: d)
        return (back.year == parts[0] && back.month == parts[1] && back.day == parts[2]) ? d : nil
    }

    /// A `distavo://daylog` link may ask only for today (nil) or a real day of the past 366 days.
    public static func allowedFromLink(isoDate: String?, today: Date, timeZone: TimeZone) -> Bool {
        guard let isoDate else { return true }
        guard let day = date(fromISO: isoDate, timeZone: timeZone) else { return false }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let start = cal.startOfDay(for: today)
        guard let oldest = cal.date(byAdding: .day, value: -366, to: start) else { return false }
        return day >= oldest && day <= start
    }

    public static func render(day: Date, notesDir: URL, workDir: URL, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let entries = NotesLibrary.scan(notesDir: notesDir, workDir: workDir, timeZone: timeZone)
            .filter { !$0.isVariant && cal.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.date != $1.date ? $0.date < $1.date : $0.base < $1.base }

        var out = "---\ntype: day-log\ndate: \(NoteFrontmatter.dateString(day, timeZone: timeZone))\n---\n"
        out += "# Day log: \(RelativeDates.full(day, cal))\n"
        guard !entries.isEmpty else { return out + "\n\(noNotes)\n" }

        var timeline: [String] = [], actions: [String] = [], speakers: [String] = [], warnings: [String] = []
        for e in entries {
            let text = (try? String(contentsOf: e.notePath, encoding: .utf8)) ?? ""
            let link = "[\(linkTitle(e.title))](\(relativeLink(e.notePath)))"
            var row = "- \(clock(e.date, cal)) · \(link)"
            if let s = e.durationSeconds, s > 0 { row += " · \(max(1, Int((s / 60).rounded()))) min" }
            if let t = template(in: text) { row += " · template: \(t)" }
            timeline.append(row)
            for item in ActionItems.parse(text) where !item.isDone {
                actions.append("- \(item.title) (\(link))")
            }
            let unnamed = unnamedSpeakers(in: text)
            if !unnamed.isEmpty { speakers.append("- \(link): \(unnamed.joined(separator: ", "))") }
            for w in warningBullets(in: text) { warnings.append("- \(link): \(w)") }
        }
        func section(_ title: String, _ lines: [String]) -> String {
            "\n## \(title)\n" + (lines.isEmpty ? "None.\n" : lines.joined(separator: "\n") + "\n")
        }
        return out + section("Timeline", timeline) + section("Open action items", actions)
            + section("Speakers still unnamed", speakers) + section("Warnings", warnings)
    }

    /// Every link target "(...)" after "](" in `text`, for tests and callers that check them.
    public static func linkTargets(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"\]\(([^)\s]+)\)"#)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    // MARK: Internals

    /// ASCII letters, digits and "-._~": everything else in a file name is percent-encoded.
    static let linkSafe = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func relativeLink(_ note: URL) -> String {
        "../" + (note.lastPathComponent.addingPercentEncoding(withAllowedCharacters: linkSafe) ?? note.lastPathComponent)
    }

    static func linkTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func clock(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "Template: Standard notes (auto)" in the summary footer -> "Standard notes".
    static func template(in note: String) -> String? {
        guard let r = note.range(of: #"Template: ([^(.;_\n]+)"#, options: [.regularExpression, .backwards]) else { return nil }
        let t = note[r].dropFirst("Template: ".count).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    static func unnamedSpeakers(in note: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"\bSPEAKER_\d{1,3}\b"#)
        let ns = note as NSString
        let found = Set(regex.matches(in: note, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) })
        return found.sorted()
    }

    static func warningBullets(in note: String) -> [String] {
        let lines = note.components(separatedBy: "\n")
        guard let range = NoteWarnings.blockRange(in: lines) else { return [] }
        return lines[range].compactMap { $0.hasPrefix("> - ") ? String($0.dropFirst(4)) : nil }
    }
}
