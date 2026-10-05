import Foundation

// Calendar-aware titling and attendees (Vikunja #2946).
//
// Pure, EventKit-free logic: the app target's EventKit provider turns calendar
// events into `CalendarCandidate`s; everything here (picking the event that
// overlaps a recording, making its title safe for a file name, cleaning the
// attendee list, moving a recording's sidecars to a new base, persisting the
// match as `<base>.calendar.json`) is unit-tested with plain values.
//
// Read-only by construction: nothing in this file (or the app's provider)
// ever writes to a calendar.

/// How the user answered / the state of an event; only `.normal` is matched.
public enum CalendarEventStatus: String, Codable, Equatable, Sendable {
    case normal, declined, cancelled
}

/// One calendar event as the matcher sees it.
public struct CalendarCandidate: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// Display names only; the provider drops the current user.
    public var attendees: [String]
    public var calendarID: String
    public var status: CalendarEventStatus

    public init(title: String, start: Date, end: Date, isAllDay: Bool = false,
                attendees: [String] = [], calendarID: String = "",
                status: CalendarEventStatus = .normal) {
        self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay
        self.attendees = attendees; self.calendarID = calendarID; self.status = status
    }
}

/// The event chosen for a recording; also the `<base>.calendar.json` sidecar.
public struct CalendarMatch: Codable, Equatable, Sendable {
    public var version: Int
    public var title: String
    public var start: Date
    public var end: Date
    public var attendees: [String]

    public static let currentVersion = 1

    public init(title: String, start: Date, end: Date, attendees: [String] = []) {
        self.version = Self.currentVersion
        self.title = title; self.start = start; self.end = end; self.attendees = attendees
    }
}

// MARK: - Picking the event

public enum CalendarMatcher {
    /// Minimum overlap, seconds, regardless of how short the shorter side is.
    public static let minOverlapSeconds: TimeInterval = 300
    /// Required fraction of the SHORTER of (recording, event) that must overlap.
    public static let minOverlapFraction = 0.5

    /// Minimum overlap / union (Jaccard) of recording and event. A long block
    /// (a 9-17 "Focus" slot) that merely contains the recording scores near 0
    /// and is never used, even when it is the only candidate; the real
    /// 30-minute meeting recorded with a couple of minutes of slack scores ~0.85.
    public static let minScore = 0.25

    /// The best event for a recording spanning `start...end`, or nil.
    ///
    /// Ignored: all-day events, declined/cancelled events, empty titles, and
    /// events from calendars outside `calendarIDs` (empty = all). A qualifying
    /// event overlaps at least `max(5 min, 50 % of the shorter duration)` AND
    /// scores at least `minScore`. The best score (overlap / union) wins; a
    /// tie goes to the event whose start is closest to the recording's start.
    public static func best(recordingStart start: Date, recordingEnd end: Date,
                            candidates: [CalendarCandidate],
                            calendarIDs: [String] = [],
                            ownerName: String = "",
                            maxAttendees: Int = CalendarAttendees.defaultCap) -> CalendarMatch? {
        let recDuration = end.timeIntervalSince(start)
        guard recDuration > 0 else { return nil }
        var best: (c: CalendarCandidate, score: Double, startGap: TimeInterval)?
        for c in candidates {
            guard !c.isAllDay, c.status == .normal,
                  CalendarTitle.displayTitle(c.title) != nil,
                  calendarIDs.isEmpty || calendarIDs.contains(c.calendarID) else { continue }
            let evDuration = c.end.timeIntervalSince(c.start)
            guard evDuration > 0 else { continue }
            let overlap = min(end, c.end).timeIntervalSince(max(start, c.start))
            let needed = max(minOverlapSeconds, minOverlapFraction * min(recDuration, evDuration))
            guard overlap >= needed else { continue }
            let score = overlap / (recDuration + evDuration - overlap)
            guard score >= minScore else { continue }
            let gap = abs(c.start.timeIntervalSince(start))
            if let b = best {
                if score > b.score + 1e-9 || (abs(score - b.score) <= 1e-9 && gap < b.startGap) {
                    best = (c, score, gap)
                }
            } else {
                best = (c, score, gap)
            }
        }
        guard let chosen = best?.c, let title = CalendarTitle.displayTitle(chosen.title) else { return nil }
        return CalendarMatch(
            title: title, start: chosen.start, end: chosen.end,
            attendees: CalendarAttendees.clean(chosen.attendees, owner: ownerName, cap: maxAttendees))
    }
}

// MARK: - Titles

public enum CalendarTitle {
    /// UTF-8 byte cap for the title part of a file name.
    public static let maxFileNameBytes = 120
    /// Character cap for the note's `# ` heading.
    public static let maxDisplayChars = 120

    /// The title as shown in the note heading. Calendar titles are written by
    /// whoever sent the invitation, so this is deliberately strict: control
    /// characters and newlines dropped, HTML tags removed, Markdown links and
    /// images reduced to their text, backticks and angle brackets removed,
    /// leading `#` stripped, whitespace collapsed, capped. nil if nothing
    /// is left. The title is used ONLY for this heading and the file name; it
    /// is never put into the model prompt.
    public static func displayTitle(_ raw: String) -> String? {
        var t = raw.unicodeScalars.map { (isControl($0) ? " " : String($0)) }.joined()
        t = t.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for c in ["<", ">", "`", "[", "]"] { t = t.replacingOccurrences(of: c, with: "") }
        var collapsed = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while collapsed.hasPrefix("#") { collapsed = String(collapsed.dropFirst()).trimmingCharacters(in: .whitespaces) }
        let capped = String(collapsed.prefix(maxDisplayChars)).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? nil : capped
    }

    private static func isControl(_ s: Unicode.Scalar) -> Bool {
        s.value < 0x20 || s.value == 0x7F || (0x80...0x9F).contains(s.value)
            || s.properties.generalCategory == .format          // bidi overrides, zero-width
            || s == "\u{2028}" || s == "\u{2029}"
    }

    /// The title as a file-name component: path separators and `:` become `-`,
    /// control characters go, whitespace collapses, leading dots and trailing
    /// spaces/dots are trimmed, the result is capped at `maxFileNameBytes`
    /// UTF-8 bytes on a character boundary. nil when nothing is left (the
    /// caller then keeps the original name).
    public static func fileNameComponent(_ raw: String) -> String? {
        guard let display = displayTitle(raw) else { return nil }
        // ASCII only, so `DistavoState.baseFor` keeps the words readable
        // (accented letters would each become `_`). Titles with no Latin
        // letters or digits (CJK, Hebrew, emoji only) give nil: no rename.
        let folded = asciiFolded(display)
        guard folded.contains(where: { $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        var s = String(folded.map { "/\\:".contains($0) ? "-" : $0 })
        s = trimEdges(s)
        var out = "", bytes = 0
        for ch in s {
            let n = String(ch).utf8.count
            if bytes + n > maxFileNameBytes { break }
            out.append(ch); bytes += n
        }
        out = trimEdges(out)
        return out.isEmpty ? nil : out
    }

    /// Diacritics and typographic punctuation to plain ASCII: `ó`→`o`, `ñ`→`n`,
    /// `ç`→`c`, `l·l`→`ll`, `’` removed, `'` → space, dashes → `-`, `ß`→`ss`.
    /// Whatever has no ASCII equivalent (CJK, emoji, …) is dropped.
    static func asciiFolded(_ s: String) -> String {
        let table: [Character: String] = [
            "ß": "ss", "æ": "ae", "Æ": "AE", "œ": "oe", "Œ": "OE", "ø": "o", "Ø": "O", "đ": "d", "Đ": "D",
            "ł": "l", "Ł": "L", "ŀ": "l", "Ŀ": "L", "ð": "d", "Ð": "D", "þ": "th", "Þ": "Th", "ı": "i",
            "·": "", "\u{2019}": "", "\u{2018}": "", "\u{02BC}": "", "\u{201C}": "", "\u{201D}": "",
            "\u{201E}": "", "'": " ", "\u{2013}": "-", "\u{2014}": "-", "\u{2212}": "-", "\u{2010}": "-",
            "\u{2011}": "-", "\u{2012}": "-", "\u{2015}": "-", "\u{00A0}": " ", "\u{2026}": "...",
        ]
        var out = ""
        for ch in s {
            if let m = table[ch] { out += m; continue }
            for u in String(ch).decomposedStringWithCanonicalMapping.unicodeScalars {
                if u.isASCII { out.unicodeScalars.append(u) }
                else if let m = table[Character(u)] { out += m }
                // combining marks and everything else without an ASCII form: dropped
            }
        }
        return out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func trimEdges(_ s: String) -> String {
        var chars = Substring(s)
        while let f = chars.first, f == "." || f.isWhitespace { chars = chars.dropFirst() }
        while let l = chars.last, l == "." || l.isWhitespace { chars = chars.dropLast() }
        return String(chars)
    }

    /// `"<yyyy-MM-dd> <Title>"` in the recording's LOCAL date, or nil when the
    /// title cannot make a file name.
    public static func recordingStem(date: Date, title: String,
                                     timeZone: TimeZone = .current) -> String? {
        guard let part = fileNameComponent(title) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return "\(day) \(part)"
    }

    /// The base `DistavoState.baseFor` will derive for `<stem>.<ext>` placed
    /// directly in the recordings folder (spaces become `_`, etc.). The stem is
    /// ASCII (`fileNameComponent` folds it), so this is exactly what `baseFor` gives.
    public static func predictedBase(stem: String) -> String {
        DistavoState.sanitizeJoined(stem)
    }

    /// Replace the note's first `# ` heading with the event title. A note
    /// without a level-1 heading is returned unchanged.
    // TODO(#2954): prefer calendar title for frontmatter title (use CalendarMatchStore.load(workDir:base:)?.title)
    public static func retitle(note: String, title: String) -> String {
        guard let heading = displayTitle(title) else { return note }
        var lines = note.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix("# ") }) else { return note }
        lines[i] = "# \(heading)"
        return lines.joined(separator: "\n")
    }
}

// MARK: - Attendees

public enum CalendarAttendees {
    public static let defaultCap = 15
    static let maxNameChars = 60

    /// Display names only: `mailto:` stripped, e-mail-only entries skipped
    /// (names are never invented from an address), de-duplicated, the note
    /// owner removed, capped.
    public static func clean(_ names: [String], owner: String, cap: Int = defaultCap) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for raw in names {
            guard let name = plausibleName(raw), !isOwner(name, owner: owner) else { continue }
            let key = fold(name)
            if seen.insert(key).inserted { out.append(name) }
            if out.count >= cap { break }
        }
        return out
    }

    public static let maxNameWords = 6
    private static let injectionWords = ["ignore previous", "ignore all", "disregard", "instruction", "system prompt",
                                         "you are", "assistant", "as an ai"]

    /// An attendee name safe to hand to the model: the invitation's sender
    /// wrote it, so it must look like a person's display name or it is dropped.
    /// Single line, control characters and `{}<>[]` and backticks removed, at
    /// most `maxNameChars` characters and `maxNameWords` words, at least one
    /// letter; anything with a URL, `@`, `#`, `*`, `|` or a phrase that reads
    /// like an instruction is rejected outright (not truncated). `mailto:` is
    /// stripped first, and an address-only entry is skipped.
    static func plausibleName(_ raw: String) -> String? {
        var name = raw.unicodeScalars.map { u -> String in
            (u.value < 0x20 || u.value == 0x7F || (0x80...0x9F).contains(u.value)
                || u.properties.generalCategory == .format || u == "\u{2028}" || u == "\u{2029}") ? " " : String(u)
        }.joined()
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasPrefix("mailto:") { name = String(name.dropFirst(7)) }
        for c in ["{", "}", "<", ">", "[", "]", "`"] { name = name.replacingOccurrences(of: c, with: "") }
        let words = name.split(whereSeparator: { $0.isWhitespace })
        name = words.joined(separator: " ")
        let lower = name.lowercased()
        guard !name.isEmpty, name.count <= maxNameChars, words.count <= maxNameWords,
              name.contains(where: { $0.isLetter }),
              !name.contains("@"), !lower.contains("http"), !lower.contains("://"), !lower.contains("www."),
              !lower.contains(".com"), !name.contains(where: { "#*|\\".contains($0) }),
              !injectionWords.contains(where: { lower.contains($0) }) else { return nil }
        return name
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func tokens(_ s: String) -> [String] {
        fold(s).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Same person as the configured owner: equal names, or (when the shorter
    /// side has two or more words) one name's words all appear in the other's.
    /// A single-word owner such as "Marc" only matches exactly, so a different
    /// "Marc Smith" is kept.
    static func isOwner(_ name: String, owner: String) -> Bool {
        let o = tokens(owner), n = tokens(name)
        guard !o.isEmpty, !n.isEmpty else { return false }
        if o == n { return true }
        if o.count >= 2, Set(o).isSubset(of: Set(n)) { return true }
        if n.count >= 2, Set(n).isSubset(of: Set(o)) { return true }
        return false
    }

    /// `existing` participants text plus any calendar attendee not already
    /// mentioned in it. Returns `existing` untouched when there is nothing to
    /// add, so a recording without attendees keeps a byte-identical prompt.
    public static func mergedParticipants(existing: String?, attendees: [String]) -> String? {
        let base = existing?.trimmingCharacters(in: .whitespacesAndNewlines)
        let haystack = fold(base ?? "")
        let missing = attendees.filter { !haystack.contains(fold($0)) }
        guard !missing.isEmpty else { return existing }
        let line = hintsText(missing)
        guard let base, !base.isEmpty else { return line }
        return base + ". " + line
    }

    /// The attendees whose names still appear in `participants` (all-case/accent
    /// insensitive); none when the text is nil or blank.
    public static func mentioned(in participants: String?, attendees: [String]) -> [String] {
        let haystack = fold(participants ?? "")
        return attendees.filter { haystack.contains(fold($0)) }
    }

    /// The participants text the "Who was in this meeting?" window writes.
    public static func hintsText(_ attendees: [String]) -> String {
        "Other participants: " + attendees.joined(separator: ", ")
    }
}

// MARK: - Sidecar

public enum CalendarMatchStore {
    public static func url(workDir: URL, base: String) -> URL {
        workDir.appendingPathComponent("\(base).calendar.json")
    }

    /// The saved match, or nil when absent, corrupt, or written by a newer Distavo.
    public static func load(workDir: URL, base: String) -> CalendarMatch? {
        guard let data = try? Data(contentsOf: url(workDir: workDir, base: base)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let m = try? decoder.decode(CalendarMatch.self, from: data),
              m.version <= CalendarMatch.currentVersion else { return nil }
        return m
    }

    public static func save(_ match: CalendarMatch, workDir: URL, base: String) throws {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(match).write(to: url(workDir: workDir, base: base), options: .atomic)
    }
}

// MARK: - Pipeline glue

public enum CalendarLookup {
    /// The match for a recording at processing time: the stored sidecar if any,
    /// else (feature on, seam wired) a fresh lookup over `[start, start+duration]`,
    /// persisted. Never touches the recording file. Returns nil when the
    /// feature is off, the seam is absent, or nothing qualifies.
    static func resolve(path: URL, sourceBase: String, workDir: URL, config: Config,
                        deps: PipelineDeps) async -> CalendarMatch? {
        guard config.calendar.enabled else { return nil }
        if let stored = CalendarMatchStore.load(workDir: workDir, base: sourceBase) { return stored }
        // Only with trustworthy recording-time evidence (the recorder's own file
        // name or the media's embedded creation date); a file's creation or
        // modification date is usually the copy/download time, so without
        // evidence there is no lookup and no sidecar.
        guard let lookup = deps.calendarLookup,
              let start = await deps.recordingStart(path),
              let seconds = await deps.audioDurationSeconds(path), seconds > 0 else { return nil }
        let end = start.addingTimeInterval(seconds)
        let candidates = await lookup(start, end)
        guard let match = CalendarMatcher.best(
            recordingStart: start, recordingEnd: end, candidates: candidates,
            calendarIDs: config.calendar.calendars, ownerName: config.noteOwner) else { return nil }
        try? CalendarMatchStore.save(match, workDir: workDir, base: sourceBase)
        // Same as the recorder's direct path: attendees become speaker hints
        // unless the owner already gave some.
        if config.calendar.attendeesAsParticipants, !match.attendees.isEmpty,
           SpeakerHints.load(workDir: workDir, base: sourceBase) == nil {
            try? SpeakerHints(participants: CalendarAttendees.hintsText(match.attendees))
                .save(workDir: workDir, base: sourceBase)
        }
        return match
    }

    /// The participants text for the prompt, calendar attendees merged in.
    static func participants(_ existing: String?, match: CalendarMatch?, config: Config) -> String? {
        guard let match, config.calendar.attendeesAsParticipants else { return existing }
        // Re-sanitised: the sidecar is data on disk, never trusted to be clean.
        return CalendarAttendees.mergedParticipants(
            existing: existing, attendees: CalendarAttendees.clean(match.attendees, owner: ""))
    }
}

// MARK: - Renaming the recording

public enum CalendarRename {
    public enum Failure: Error, Equatable { case collision(String) }

    /// True when anything (work files, markers, notes) already uses `base`.
    static func baseInUse(_ base: String, workDir: URL, notesDir: URL, fm: FileManager = .default) -> Bool {
        func clash(_ dir: URL) -> Bool {
            ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .contains { $0.hasPrefix(base + ".") || $0.hasPrefix(base + "@") }
        }
        return clash(workDir) || clash(workDir.appendingPathComponent(".state")) || clash(notesDir)
    }

    /// The first free `<stem>.<ext>` (then `<stem> 2`, `<stem> 3`, …) in
    /// `folder` whose derived base is also unused. nil after 99 attempts.
    public static func uniqueTarget(folder: URL, stem: String, ext: String,
                                    workDir: URL, notesDir: URL,
                                    fm: FileManager = .default) -> URL? {
        for n in 1...99 {
            let name = n == 1 ? stem : "\(stem) \(n)"
            let url = folder.appendingPathComponent("\(name).\(ext)")
            let base = DistavoState.baseFor(recordingsDir: folder, path: url)
            if fm.fileExists(atPath: url.path) || fm.fileExists(atPath: url.path + ".part") { continue }
            if baseInUse(base, workDir: workDir, notesDir: notesDir, fm: fm) { continue }
            return url
        }
        return nil
    }

    /// Test seams for the steps of `moveSidecars`.
    public struct Steps {
        public var copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
        /// Renames the audio `.part` (the commit point).
        public var commit: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
        /// Runs right after a successful commit, before the old sidecars are removed.
        public var afterCommit: () -> Void = {}
        public init() {}
    }

    /// Re-key a recording that is still an audio `.part` from `oldBase` to
    /// `newBase`: every top-level work-dir file `<oldBase>.*` (enumerated, not a
    /// fixed list) is COPIED to the new base, a bookmarks sidecar's `source` is
    /// pointed at the new file name, then the audio part is renamed (the single
    /// commit point), and only then are the old sidecars removed.
    ///
    /// Crash-safe by construction: at every instant the `.part` on disk has a
    /// complete sidecar set under ITS OWN base, so startup recovery
    /// (`MeetingRecorder.recoverOrphanedRecordings`, which finalises a
    /// `.wav.part` under the part's own name) never loses participants, notes
    /// or key moments. A crash before the commit leaves harmless stray copies
    /// under the unused new base; after it, stray old sidecars. Any thrown
    /// error removes the copies and leaves everything as it was.
    public static func moveSidecars(
        workDir: URL, oldBase: String, newBase: String,
        oldSource: String, newSource: String,
        part: (from: URL, to: URL)? = nil,
        fm: FileManager = .default,
        steps: Steps = Steps()
    ) throws {
        let names = ((try? fm.contentsOfDirectory(atPath: workDir.path)) ?? [])
            .filter { $0.hasPrefix(oldBase + ".") }
        var olds: [URL] = [], copies: [URL] = []
        func undo() { for c in copies { try? fm.removeItem(at: c) } }
        for name in names {
            let from = workDir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: from.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let to = workDir.appendingPathComponent(newBase + name.dropFirst(oldBase.count))
            do {
                if fm.fileExists(atPath: to.path) { throw Failure.collision(to.lastPathComponent) }
                try steps.copy(from, to)
                copies.append(to); olds.append(from)
            } catch { undo(); throw error }
        }
        // Bookmarks remember the recording file name for clip export.
        if let bm = RecordingBookmarks.load(workDir: workDir, base: newBase), bm.source == oldSource {
            var fixed = bm
            fixed.source = newSource
            do { try fixed.save(workDir: workDir, base: newBase) } catch { undo(); throw error }
        }
        if let part {
            do { try steps.commit(part.from, part.to) } catch { undo(); throw error }
        }
        steps.afterCommit()
        for old in olds { try? fm.removeItem(at: old) }
    }

    /// Everything the recorder needs before it publishes the finished take:
    /// choose `<yyyy-MM-dd> <Title>.<ext>`, move the sidecars keyed on the old
    /// name, and return the new URL. nil (nothing changed) when the title
    /// cannot form a name, no free name exists, or a move fails: the caller
    /// then keeps the original name.
    public static func prepare(recording: URL, match: CalendarMatch, recordingStart: Date,
                               recordingsDir: URL, workDir: URL, notesDir: URL,
                               timeZone: TimeZone = .current,
                               fm: FileManager = .default,
                               steps: Steps = Steps()) -> URL? {
        guard let stem = CalendarTitle.recordingStem(date: recordingStart, title: match.title, timeZone: timeZone),
              let target = uniqueTarget(folder: recording.deletingLastPathComponent(), stem: stem,
                                        ext: recording.pathExtension, workDir: workDir,
                                        notesDir: notesDir, fm: fm) else { return nil }
        let oldBase = DistavoState.baseFor(recordingsDir: recordingsDir, path: recording)
        let newBase = DistavoState.baseFor(recordingsDir: recordingsDir, path: target)
        guard oldBase != newBase else { return nil }
        do {
            // `recording` is still `<name>.wav.part` on disk: rename it with the sidecars.
            let part = fm.fileExists(atPath: recording.path + ".part")
                ? (from: URL(fileURLWithPath: recording.path + ".part"), to: URL(fileURLWithPath: target.path + ".part")) : nil
            try moveSidecars(workDir: workDir, oldBase: oldBase, newBase: newBase,
                             oldSource: recording.lastPathComponent, newSource: target.lastPathComponent,
                             part: part, fm: fm, steps: steps)
        } catch { return nil }
        return target
    }
}
