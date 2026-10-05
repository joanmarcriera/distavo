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

    /// The best event for a recording spanning `start...end`, or nil.
    ///
    /// Ignored: all-day events, declined/cancelled events, empty titles, and
    /// events from calendars outside `calendarIDs` (empty = all). A qualifying
    /// event overlaps at least `max(5 min, 50 % of the shorter duration)`.
    /// Among those the largest overlap wins; a tie goes to the event whose
    /// start is closest to the recording's start.
    public static func best(recordingStart start: Date, recordingEnd end: Date,
                            candidates: [CalendarCandidate],
                            calendarIDs: [String] = [],
                            ownerName: String = "",
                            maxAttendees: Int = CalendarAttendees.defaultCap) -> CalendarMatch? {
        let recDuration = end.timeIntervalSince(start)
        guard recDuration > 0 else { return nil }
        var best: (c: CalendarCandidate, overlap: TimeInterval, startGap: TimeInterval)?
        for c in candidates {
            guard !c.isAllDay, c.status == .normal,
                  CalendarTitle.displayTitle(c.title) != nil,
                  calendarIDs.isEmpty || calendarIDs.contains(c.calendarID) else { continue }
            let evDuration = c.end.timeIntervalSince(c.start)
            guard evDuration > 0 else { continue }
            let overlap = min(end, c.end).timeIntervalSince(max(start, c.start))
            let needed = max(minOverlapSeconds, minOverlapFraction * min(recDuration, evDuration))
            guard overlap >= needed else { continue }
            let gap = abs(c.start.timeIntervalSince(start))
            if let b = best {
                if overlap > b.overlap || (overlap == b.overlap && gap < b.startGap) {
                    best = (c, overlap, gap)
                }
            } else {
                best = (c, overlap, gap)
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
    public static let maxDisplayChars = 200

    /// The title as shown in the note heading: control characters and
    /// newlines dropped, whitespace collapsed, trimmed, capped. nil if empty.
    public static func displayTitle(_ raw: String) -> String? {
        let flat = raw.unicodeScalars.map { (isControl($0) ? " " : String($0)) }.joined()
        let collapsed = flat.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
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
        var s = String(display.map { "/\\:".contains($0) ? "-" : $0 })
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
    /// directly in the recordings folder (spaces become `_`, etc.). Foundation's
    /// file URLs hand `baseFor` the canonically *decomposed* name, so an accented
    /// letter becomes its base letter plus `_` (Reunio_), hence the NFD step.
    public static func predictedBase(stem: String) -> String {
        DistavoState.sanitizeJoined(stem.decomposedStringWithCanonicalMapping)
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
    static let maxNameChars = 80

    /// Display names only: `mailto:` stripped, e-mail-only entries skipped
    /// (names are never invented from an address), de-duplicated, the note
    /// owner removed, capped.
    public static func clean(_ names: [String], owner: String, cap: Int = defaultCap) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for raw in names {
            var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.lowercased().hasPrefix("mailto:") { name = String(name.dropFirst(7)) }
            name = String(name.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                .joined(separator: " ").prefix(maxNameChars))
            guard !name.isEmpty, !name.contains("@"), !isOwner(name, owner: owner) else { continue }
            let key = fold(name)
            if seen.insert(key).inserted { out.append(name) }
            if out.count >= cap { break }
        }
        return out
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
        guard let lookup = deps.calendarLookup,
              let start = Pipeline.meetingDate(for: path),
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
        return CalendarAttendees.mergedParticipants(existing: existing, attendees: match.attendees)
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

    /// Move every top-level work-dir file keyed on `oldBase` (`<oldBase>.*` -
    /// enumerated, not a fixed list) to `newBase`, and point a bookmarks
    /// sidecar's `source` at the new file name. All-or-nothing: on any failure
    /// everything already moved is moved back and the error is thrown.
    /// `move` is injectable for failure tests.
    public static func moveSidecars(
        workDir: URL, oldBase: String, newBase: String,
        oldSource: String, newSource: String,
        fm: FileManager = .default,
        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws {
        let names = ((try? fm.contentsOfDirectory(atPath: workDir.path)) ?? [])
            .filter { $0.hasPrefix(oldBase + ".") }
        var moved: [(from: URL, to: URL)] = []
        func rollback() { for m in moved.reversed() { try? fm.moveItem(at: m.to, to: m.from) } }
        for name in names {
            let from = workDir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: from.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let to = workDir.appendingPathComponent(newBase + name.dropFirst(oldBase.count))
            do {
                if fm.fileExists(atPath: to.path) { throw Failure.collision(to.lastPathComponent) }
                try move(from, to)
                moved.append((from, to))
            } catch { rollback(); throw error }
        }
        // Bookmarks remember the recording file name for clip export.
        if let bm = RecordingBookmarks.load(workDir: workDir, base: newBase), bm.source == oldSource {
            var fixed = bm
            fixed.source = newSource
            do { try fixed.save(workDir: workDir, base: newBase) } catch { rollback(); throw error }
        }
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
                               move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) -> URL? {
        guard let stem = CalendarTitle.recordingStem(date: recordingStart, title: match.title, timeZone: timeZone),
              let target = uniqueTarget(folder: recording.deletingLastPathComponent(), stem: stem,
                                        ext: recording.pathExtension, workDir: workDir,
                                        notesDir: notesDir, fm: fm) else { return nil }
        let oldBase = DistavoState.baseFor(recordingsDir: recordingsDir, path: recording)
        let newBase = DistavoState.baseFor(recordingsDir: recordingsDir, path: target)
        guard oldBase != newBase else { return nil }
        do {
            try moveSidecars(workDir: workDir, oldBase: oldBase, newBase: newBase,
                             oldSource: recording.lastPathComponent, newSource: target.lastPathComponent,
                             fm: fm, move: move)
        } catch { return nil }
        return target
    }
}
