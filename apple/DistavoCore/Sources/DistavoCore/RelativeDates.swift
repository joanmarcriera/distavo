// RelativeDates.swift — resolve relative dates in a note's task lines against the recording date (D083).
//
// "by Friday", "tomorrow", "end of next week" in an action item are useless a week later. After the
// summary, each such phrase in a task line gets the computed date in brackets:
//   "by Friday" -> "by Friday (Fri 20 Nov 2026)".
// Scope: lines inside a tasks section (heading starting with Action items / Actions / Tasks / Next steps /
// To do, or Catalan/Spanish Tasques / Accions / Tareas / Acciones / Próximos pasos / Propers passos) and any
// "- [ ]" checkbox line. Everything else is left byte-identical.
// Rules:
//  - a line that already holds an explicit date anywhere ("20 Nov", "20 November 2026", "2026-11-20",
//    "20/11", "December 2026") is left alone; our own brackets are explicit dates, so a second run is a no-op;
//  - text inside the model's own "(interpreted from '...')" bracket is never touched;
//  - a bare weekday = the next such day after the recording date; the recording's own weekday is
//    ambiguous and gets both ("Wed 18 or Wed 25 Nov 2026?");
//  - "next <weekday>" is ambiguous in British usage: both the coming one and the one after;
//  - "end of next week" = Friday of the next ISO week; "next week" = the week of its Monday;
//    "next month" = the month after, written "December 2026".
// Pure: no I/O, no clock; the caller passes the recording date and time zone. Wired through `NoteRefinements`
// behind `summarise.resolve_relative_dates` (absent = off; on for fresh installs).

import Foundation

public enum RelativeDates {
    /// Headings (after the #s, lowercased, accents kept) that open a tasks section.
    static let taskHeadingPrefixes = [
        "action", "actions", "task", "tasks", "next step", "next steps", "to do", "todo", "to-do", "follow-up actions",
        "tasques", "accions", "propers passos", "pròxims passos", "acords i tasques",
        "tareas", "acciones", "próximos pasos", "proximos pasos",
    ]

    private enum Kind {
        case dayOffset(Int)                 // today 0, tomorrow 1, yesterday -1
        case weekday(Int, next: Bool)       // 1 = Sunday ... 7 = Saturday (Calendar.weekday)
        case thisWeek, nextWeek
        case endOfWeek(next: Bool)
        case nextMonth, endOfMonth
    }

    private struct Phrase { let pattern: String; let kind: Kind }

    private static let weekdayWords: [(Int, [String])] = [
        (2, ["monday", "lunes", "dilluns"]), (3, ["tuesday", "martes", "dimarts"]),
        (4, ["wednesday", "miércoles", "miercoles", "dimecres"]), (5, ["thursday", "jueves", "dijous"]),
        (6, ["friday", "viernes", "divendres"]), (7, ["saturday", "sábado", "sabado", "dissabte"]),
        (1, ["sunday", "domingo", "diumenge"]),
    ]

    /// Longest phrases first so "end of next week" wins over "next week".
    private static let phrases: [Phrase] = {
        var list: [Phrase] = [
            Phrase(pattern: #"(?:the )?end of (?:the )?next week"#, kind: .endOfWeek(next: true)),
            Phrase(pattern: #"(?:the )?end of (?:the |this )?week"#, kind: .endOfWeek(next: false)),
            Phrase(pattern: #"(?:the )?end of (?:the |this )?month"#, kind: .endOfMonth),
            Phrase(pattern: #"next week|la semana que viene|la próxima semana|la proxima semana|la setmana que ve|la setmana vinent|la propera setmana"#, kind: .nextWeek),
            Phrase(pattern: #"this week|esta semana|aquesta setmana"#, kind: .thisWeek),
            Phrase(pattern: #"next month|el mes que viene|el próximo mes|el proximo mes|el mes que ve|el mes vinent"#, kind: .nextMonth),
            Phrase(pattern: #"today|hoy|avui"#, kind: .dayOffset(0)),
            Phrase(pattern: #"tomorrow|demà|dema"#, kind: .dayOffset(1)),
            // "mañana" alone is tomorrow; "la/esta/por la mañana" is the morning.
            Phrase(pattern: #"(?<!la |esta |una |cada )mañana"#, kind: .dayOffset(1)),
            Phrase(pattern: #"yesterday|ayer|ahir"#, kind: .dayOffset(-1)),
        ]
        for (day, words) in weekdayWords {
            let alt = words.joined(separator: "|")
            list.append(Phrase(pattern: "(?:next (?:\(words[0]))|el próximo (?:\(words[1]))|el proximo (?:\(words[1])))",
                               kind: .weekday(day, next: true)))
            list.append(Phrase(pattern: "(?:el |this |on )?(?:\(alt))", kind: .weekday(day, next: false)))
        }
        return list
    }()

    private static let monthNames =
        "jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec|january|february|march|april|june|july|august|september|october|november|december"
        + "|gener|febrer|març|abril|maig|juny|juliol|agost|setembre|octubre|novembre|desembre"
        + "|enero|febrero|marzo|mayo|junio|julio|agosto|septiembre|setiembre|noviembre|diciembre"

    /// An explicit date anywhere on the line: "20 Nov", "20th November 2026", "Nov 20", "2026-11-20",
    /// "20/11", "December 2026", "20 de noviembre", "20 de novembre".
    private static let explicitDate: NSRegularExpression = {
        let m = "(?:\(monthNames))\\.?"
        let p = "\\b\\d{1,2}(?:st|nd|rd|th)?(?:\\s+(?:de|of)\\s+|\\s*d['’]|\\s+)\(m)(?![\\p{L}])"
            + "|(?<![\\p{L}])\(m)\\s+\\d{1,2}\\b"
            + "|(?<![\\p{L}])\(m)\\s+\\d{4}\\b"
            + "|\\b\\d{4}-\\d{2}-\\d{2}\\b"
            + "|\\b\\d{1,2}/\\d{1,2}(?:/\\d{2,4})?\\b"
        return try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }()

    private static let untouchable = try! NSRegularExpression(
        pattern: #"\[\[[^\]]*\]\]|https?://\S+|\[[^\]]*\]\([^)]*\)"#, options: [.caseInsensitive])

    private static let interpreted = try! NSRegularExpression(
        pattern: #"\(interpreted from [^)]*\)"#, options: [.caseInsensitive])

    private static let compiled: [(NSRegularExpression, Kind)] = phrases.map {
        (try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_-])(?:\($0.pattern))(?![\\p{L}\\p{N}_'’-])",
                                  options: [.caseInsensitive]), $0.kind)
    }

    public static func resolve(note: String, recordingDate: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = 2                     // ISO weeks: Monday first
        cal.minimumDaysInFirstWeek = 4
        let day = cal.startOfDay(for: recordingDate)

        var lines = note.components(separatedBy: "\n")
        var inTasks = false
        var inFence = false
        for i in lines.indices {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            if isHeading(trimmed) {
                let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
                inTasks = isTaskHeading(heading)
                continue
            }
            let checkbox = trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]")
                || trimmed.hasPrefix("* [ ]")
            guard inTasks || checkbox else { continue }
            lines[i] = resolveLine(line, day: day, cal: cal)
        }
        return lines.joined(separator: "\n")
    }

    /// "## Tasks" is a heading; "#urgent call tomorrow" (an Obsidian tag) is not.
    static func isHeading(_ trimmed: String) -> Bool {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return false }
        let rest = trimmed.dropFirst(hashes)
        return rest.isEmpty || rest.first == " "
    }

    /// "action items", "tasks", "tasques i acords"... but not "actionable insights".
    static func isTaskHeading(_ heading: String) -> Bool {
        taskHeadingPrefixes.contains { prefix in
            guard heading.hasPrefix(prefix) else { return false }
            guard let next = heading.dropFirst(prefix.count).first else { return true }
            return !next.isLetter
        }
    }

    static func resolveLine(_ line: String, day: Date, cal: Calendar) -> String {
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        if explicitDate.firstMatch(in: line, range: whole) != nil { return line }
        // Ranges never touched: the model's own "(interpreted from '...')".
        var taken = (interpreted.matches(in: line, range: whole) + untouchable.matches(in: line, range: whole)).map(\.range)
        var hits: [(NSRange, String)] = []
        for (regex, kind) in compiled {
            for m in regex.matches(in: line, range: whole) {
                guard !taken.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) else { continue }
                if ns.substring(with: m.range) == "Domingo" { taken.append(m.range); continue }
                // Already followed by a bracket ("Friday (interpreted from ...)", or our own date): leave it.
                let after = ns.substring(from: m.range.location + m.range.length)
                if after.drop(while: { $0 == " " }).hasPrefix("(") { taken.append(m.range); continue }
                taken.append(m.range)
                hits.append((m.range, label(kind, day: day, cal: cal)))
            }
        }
        guard !hits.isEmpty else { return line }
        var out = line
        for (range, text) in hits.sorted(by: { $0.0.location > $1.0.location }) {
            let end = range.location + range.length
            guard let idx = Range(NSRange(location: end, length: 0), in: out) else { continue }
            out.insert(contentsOf: " (\(text))", at: idx.lowerBound)
        }
        return out
    }

    // MARK: Formatting

    private static func label(_ kind: Kind, day: Date, cal: Calendar) -> String {
        func add(_ n: Int, _ d: Date = day) -> Date { cal.date(byAdding: .day, value: n, to: d)! }
        let weekStart = cal.dateInterval(of: .weekOfYear, for: day)!.start   // Monday
        switch kind {
        case .dayOffset(let n): return full(add(n), cal)
        case .thisWeek: return "week of \(full(weekStart, cal))"
        case .nextWeek: return "week of \(full(add(7, weekStart), cal))"
        case .endOfWeek(let next): return full(add(next ? 11 : 4, weekStart), cal)
        case .endOfMonth:
            let month = cal.dateInterval(of: .month, for: day)!
            return full(add(-1, month.end), cal)
        case .nextMonth:
            let next = cal.date(byAdding: .month, value: 1, to: day)!
            return monthYear(next, cal)
        case .weekday(let target, let next):
            let today = cal.component(.weekday, from: day)
            var ahead = (target - today + 7) % 7
            if ahead == 0 { ahead = 7 }
            let coming = add(ahead)
            if next { return either(coming, add(7, coming), cal) }
            if target == today { return either(day, coming, cal) }
            return full(coming, cal)
        }
    }

    private static let weekdayShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let monthShort = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let monthLong = ["January", "February", "March", "April", "May", "June", "July", "August",
                                    "September", "October", "November", "December"]

    private static func parts(_ d: Date, _ cal: Calendar) -> (wd: String, day: Int, month: Int, year: Int) {
        let c = cal.dateComponents([.weekday, .day, .month, .year], from: d)
        return (weekdayShort[c.weekday! - 1], c.day!, c.month!, c.year!)
    }

    /// "Fri 20 Nov 2026"
    static func full(_ d: Date, _ cal: Calendar) -> String {
        let p = parts(d, cal)
        return "\(p.wd) \(p.day) \(monthShort[p.month - 1]) \(p.year)"
    }

    /// "December 2026"
    static func monthYear(_ d: Date, _ cal: Calendar) -> String {
        let p = parts(d, cal)
        return "\(monthLong[p.month - 1]) \(p.year)"
    }

    /// "Wed 18 or Wed 25 Nov 2026?", "Mon 30 Nov or Mon 7 Dec 2026?", "Wed 30 Dec 2026 or Wed 6 Jan 2027?"
    static func either(_ a: Date, _ b: Date, _ cal: Calendar) -> String {
        let x = parts(a, cal), y = parts(b, cal)
        let first: String
        if x.year != y.year { first = full(a, cal) }
        else if x.month != y.month { first = "\(x.wd) \(x.day) \(monthShort[x.month - 1])" }
        else { first = "\(x.wd) \(x.day)" }
        return "\(first) or \(full(b, cal))?"
    }
}
