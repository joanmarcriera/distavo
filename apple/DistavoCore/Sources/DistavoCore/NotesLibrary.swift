import Foundation

// Notes library (1.18): the model behind the Notes window — one row per note in
// the notes folder, newest meeting first, with what is on disk for it (saved
// transcript, timed transcript, speakers, calendar match, versions, key moments)
// and, per action, whether it can run on that note and the reason when it cannot.
//
// Why it exists: in 1.17 eight menu commands each listed notes their own way
// (newest 15 / 30 / 50, "last note" only, a popup, a file panel), so nothing
// showed which note an action applied to, and a note that could not be acted on
// was only labelled inside a popup. Everything here is a pure function of the
// notes and work folders, so the window only renders it.
//
// Nothing is written and no new config key exists. `.prev-` backups are skipped
// (`NoteVersions.isBackupName`); a `<base>@<suffix>` variant note is its own row.

/// One note in the list.
public struct NoteEntry: Identifiable, Equatable, Sendable {
    /// The note's file stem, which is also the work-folder key (may be `<base>@<suffix>`).
    public var base: String
    public var notePath: URL
    /// Frontmatter title, else the note's own heading, else the calendar title, else the file name.
    public var title: String
    /// When the meeting happened (calendar match, else the date in the name, else the file date).
    public var date: Date
    /// When the note file was last written.
    public var modified: Date
    public var wordCount: Int
    /// Length of the recording, when a timed transcript or the frontmatter records it.
    public var durationSeconds: Double?
    public var hasCleanTranscript: Bool
    public var hasSegments: Bool
    /// Speakers found in the note, the saved transcript or the timed transcript.
    public var speakerCount: Int
    /// How many of them were given a name with Rename Speakers.
    public var namedSpeakers: Int
    public var calendarTitle: String?
    /// Notes this recording has (the automatic run plus its `@variant` runs).
    public var versionCount: Int
    public var keyMoments: Int
    public var isVariant: Bool

    public var id: String { base }
}

/// What can be done to a selected note.
public enum NoteAction: String, CaseIterable, Sendable {
    case open, reveal, openTranscript, ask
    case exportTranscript, copyTranscript, exportClips
    case regenerate, renameSpeakers, compare

    public var label: String {
        switch self {
        case .open: return "Open Note"
        case .reveal: return "Reveal in Finder"
        case .openTranscript: return "Open Transcript…"
        case .ask: return "Ask About Note…"
        case .exportTranscript: return "Export Transcript…"
        case .copyTranscript: return "Copy Transcript"
        case .exportClips: return "Export Key Moments…"
        case .regenerate: return "Regenerate…"
        case .renameSpeakers: return "Rename Speakers…"
        case .compare: return "Compare Versions…"
        }
    }

    /// True for the actions that rewrite the note (they wait for the scan lock).
    public var rewritesNote: Bool { self == .regenerate || self == .renameSpeakers }
}

/// A regenerate that was asked for and has not finished.
public enum NoteBusy: String, Equatable, Sendable {
    case waiting, running

    public var label: String { self == .waiting ? "regenerate waiting" : "regenerating" }
}

public enum NoteActionAvailability: Equatable, Sendable {
    case available
    /// Shown under the disabled control, e.g. "no saved transcript".
    case unavailable(String)

    public var isAvailable: Bool { self == .available }
    public var reason: String? {
        if case .unavailable(let why) = self { return why }
        return nil
    }
}

/// Remembers what was read for a note until one of its files changes, so a
/// refresh every few seconds re-reads nothing (a two-hour timed transcript is
/// several MB of JSON).
public final class NotesLibraryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (stamp: String, entry: NoteEntry)] = [:]

    public init() {}

    func entry(for base: String, stamp: String) -> NoteEntry? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = entries[base], hit.stamp == stamp else { return nil }
        return hit.entry
    }

    func store(_ entry: NoteEntry, stamp: String) {
        lock.lock(); defer { lock.unlock() }
        entries[entry.base] = (stamp, entry)
    }

    /// Drop notes that are no longer in the folder.
    func keep(only bases: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { bases.contains($0.key) }
    }
}

public enum NotesLibrary {

    public static let noTranscript = "no saved transcript"
    public static let noTimestamps = "no timestamps saved"

    // MARK: Listing

    /// Every note in `notesDir`, newest meeting first.
    public static func scan(notesDir: URL, workDir: URL, cache: NotesLibraryCache? = nil,
                            timeZone: TimeZone = .current,
                            fileManager fm: FileManager = .default) -> [NoteEntry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let urls = ((try? fm.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.pathExtension.lowercased() == "md" && !NoteVersions.isBackupName($0.lastPathComponent) }
        var notes: [(url: URL, base: String, modified: Date)] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let modified = v.contentModificationDate else { continue }
            notes.append((url, url.deletingPathExtension().lastPathComponent, modified))
        }
        // Versions per recording, counted from the listing (no extra disk reads).
        var versions: [String: Int] = [:]
        for n in notes { versions[LanguageOverride.sourceBase(from: n.base), default: 0] += 1 }

        var out: [NoteEntry] = []
        out.reserveCapacity(notes.count)
        for n in notes {
            let count = versions[LanguageOverride.sourceBase(from: n.base)] ?? 1
            let stamp = fingerprint(base: n.base, noteModified: n.modified, workDir: workDir, fm: fm)
                + "|v\(count)|\(timeZone.identifier)"
            if let hit = cache?.entry(for: n.base, stamp: stamp) { out.append(hit); continue }
            let entry = read(base: n.base, note: n.url, modified: n.modified, workDir: workDir,
                             versionCount: count, timeZone: timeZone, fm: fm)
            cache?.store(entry, stamp: stamp)
            out.append(entry)
        }
        cache?.keep(only: Set(notes.map(\.base)))
        return out.sorted { a, b in
            if a.date != b.date { return a.date > b.date }
            if a.modified != b.modified { return a.modified > b.modified }
            return a.base < b.base
        }
    }

    /// The sidecars a row is built from; a change to any of them invalidates the cached row.
    static func sidecars(workDir: URL, base: String) -> [URL] {
        let source = LanguageOverride.sourceBase(from: base)
        return [Pipeline.cachedTranscriptURL(workDir: workDir, base: base),
                TranscriptSegments.url(workDir: workDir, base: base),
                SpeakerNames.url(workDir: workDir, base: base),
                CalendarMatchStore.url(workDir: workDir, base: source),
                RecordingBookmarks.url(workDir: workDir, base: source)]
    }

    private static func fingerprint(base: String, noteModified: Date, workDir: URL, fm: FileManager) -> String {
        var parts = [String(noteModified.timeIntervalSince1970)]
        for url in sidecars(workDir: workDir, base: base) {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
            parts.append("\(date):\(size)")
        }
        return parts.joined(separator: "|")
    }

    private static func read(base: String, note: URL, modified: Date, workDir: URL, versionCount: Int,
                             timeZone: TimeZone, fm: FileManager) -> NoteEntry {
        let source = LanguageOverride.sourceBase(from: base)
        let text = (try? String(contentsOf: note, encoding: .utf8)) ?? ""
        let body = NoteFrontmatter.strip(text)
        let transcriptURL = Pipeline.cachedTranscriptURL(workDir: workDir, base: base)
        let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8)
        let hasTranscript = !(transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let segments = TranscriptSegments.load(workDir: workDir, base: base)
        let calendar = CalendarMatchStore.load(workDir: workDir, base: source)
        let speakers = SpeakerRename.detectSpeakers(note: text, transcript: transcript, segments: segments)
        let named = SpeakerNames.load(workDir: workDir, base: base)?.names.count ?? 0

        var duration = segments?.segments.map(\.end).max()
        if duration == nil, let minutes = NoteFrontmatter.value("duration_minutes", in: text).flatMap(Double.init) {
            duration = minutes * 60
        }
        return NoteEntry(
            base: base, notePath: note,
            title: title(note: text, body: body, calendarTitle: calendar?.title, base: base),
            date: calendar?.recordingStart ?? dateInName(base, timeZone: timeZone) ?? modified,
            modified: modified,
            wordCount: body.split(whereSeparator: { $0 == " " || $0.isNewline }).count,
            durationSeconds: duration,
            hasCleanTranscript: hasTranscript,
            hasSegments: segments != nil,
            speakerCount: speakers.count,
            namedSpeakers: min(named, speakers.count),
            calendarTitle: calendar.flatMap { CalendarTitle.displayTitle($0.title) },
            versionCount: versionCount,
            keyMoments: RecordingBookmarks.load(workDir: workDir, base: source)?.marks.count ?? 0,
            isVariant: base != source)
    }

    // MARK: Title and date

    /// The heading every untitled note starts with; it says nothing about which meeting it is.
    static let genericHeadings: Set<String> = ["meeting notes", "notes", "meeting summary", "summary"]

    static func title(note: String, body: String, calendarTitle: String?, base: String) -> String {
        if let t = NoteFrontmatter.value("title", in: note)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !t.isEmpty { return t }
        for line in body.split(separator: "\n", omittingEmptySubsequences: true).prefix(5) {
            guard line.hasPrefix("# ") else { continue }
            let heading = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !heading.isEmpty, !genericHeadings.contains(heading.lowercased()) { return heading }
            break
        }
        if let c = calendarTitle.flatMap(CalendarTitle.displayTitle) { return c }
        return base.replacingOccurrences(of: "_", with: " ")
    }

    /// The date (and time, when present) a recording name carries, e.g.
    /// `Meeting_2026-10-07_11.18.17` or `2026-10-05_Event_Title`. The formatter is
    /// built per call with the given zone (never a cached static one).
    static func dateInName(_ base: String, timeZone: TimeZone) -> Date? {
        let pattern = #"(\d{4})-(\d{2})-(\d{2})(?:[_ T](\d{2})[.:](\d{2})(?:[.:](\d{2}))?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)) else { return nil }
        func part(_ i: Int) -> Int? {
            guard let r = Range(m.range(at: i), in: base) else { return nil }
            return Int(base[r])
        }
        var c = DateComponents()
        c.year = part(1); c.month = part(2); c.day = part(3)
        c.hour = part(4) ?? 0; c.minute = part(5) ?? 0; c.second = part(6) ?? 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let month = c.month, let day = c.day, (1...12).contains(month), (1...31).contains(day),
              let hour = c.hour, let minute = c.minute, hour < 24, minute < 60 else { return nil }
        return calendar.date(from: c)
    }

    // MARK: Presentation helpers

    /// "42 min · 5,310 words", or just the word count when the length is unknown.
    public static func lengthLabel(_ entry: NoteEntry) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_GB")
        let words = (formatter.string(from: NSNumber(value: entry.wordCount)) ?? "\(entry.wordCount)")
            + (entry.wordCount == 1 ? " word" : " words")
        guard let seconds = entry.durationSeconds, seconds >= 1 else { return words }
        let minutes = Int((seconds / 60).rounded())
        let length = minutes < 1 ? "under 1 min" : (minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min")
        return "\(length) · \(words)"
    }

    /// What is on disk for a note, in display order: (text, present).
    public static func assets(_ e: NoteEntry) -> [(text: String, present: Bool)] {
        var speakers = "No speakers found"
        if e.speakerCount > 0 {
            speakers = "\(e.speakerCount) speaker\(e.speakerCount == 1 ? "" : "s")"
                + (e.namedSpeakers > 0 ? ", \(e.namedSpeakers) named" : "")
        }
        return [("Timed transcript", e.hasSegments),
                ("Saved transcript", e.hasCleanTranscript),
                (speakers, e.speakerCount > 0),
                (e.calendarTitle.map { "Calendar: \($0)" } ?? "No calendar match", e.calendarTitle != nil)]
    }

    /// Short marks for the list row: only what is missing or unusual.
    public static func marks(_ e: NoteEntry, busy: NoteBusy? = nil) -> [String] {
        var out: [String] = []
        if let busy { out.append(busy.label) }
        if !e.hasCleanTranscript { out.append("no transcript") }
        else if !e.hasSegments { out.append("no timestamps") }
        if e.isVariant { out.append("variant") }
        else if e.versionCount > 1 { out.append("\(e.versionCount) versions") }
        return out
    }

    // MARK: Actions

    /// Whether `action` can run on `entry`, and why not. `busy` is a regenerate
    /// of this note that has not finished: nothing else may rewrite the note meanwhile.
    public static func availability(_ action: NoteAction, for e: NoteEntry, busy: NoteBusy? = nil) -> NoteActionAvailability {
        if let busy, action.rewritesNote {
            if action == .regenerate {
                return .unavailable(busy == .waiting ? "already waiting to regenerate" : "regenerating now")
            }
            return .unavailable("wait for the regenerate to finish")
        }
        switch action {
        case .open, .reveal, .ask:
            return .available
        case .openTranscript:
            return e.hasCleanTranscript || e.hasSegments ? .available : .unavailable(noTranscript)
        case .copyTranscript, .regenerate:
            return e.hasCleanTranscript ? .available : .unavailable(noTranscript)
        case .exportTranscript:
            if e.hasSegments { return .available }
            return .unavailable(e.hasCleanTranscript ? noTimestamps : noTranscript)
        case .exportClips:
            return e.keyMoments > 0 ? .available : .unavailable("no key moments marked")
        case .renameSpeakers:
            return e.speakerCount > 0 ? .available : .unavailable("no speakers found")
        case .compare:
            return e.versionCount >= 2 ? .available : .unavailable("only one version")
        }
    }

    /// For several selected notes only the transcript export applies: the ones
    /// with timestamps are exported, the rest are named in the reason.
    public static func exportable(_ entries: [NoteEntry]) -> (ready: [NoteEntry], skipped: [NoteEntry]) {
        (entries.filter(\.hasSegments), entries.filter { !$0.hasSegments })
    }

    // MARK: Filtering

    /// Notes whose title or file name contains every word of `query`
    /// (case- and accent-insensitive). An empty query keeps everything.
    public static func filter(_ entries: [NoteEntry], query: String) -> [NoteEntry] {
        let words = fold(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { e in
            let haystack = fold(e.title + " " + e.base.replacingOccurrences(of: "_", with: " ")
                                + " " + (e.calendarTitle ?? ""))
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
    }

    /// The selection after a refresh: bases that are still listed, in the same
    /// order. It never moves to another note by itself — a note written while the
    /// window is open appears in the list but is not selected (2947.9).
    public static func retainedSelection(_ selection: [String], in entries: [NoteEntry]) -> [String] {
        let present = Set(entries.map(\.base))
        return selection.filter { present.contains($0) }
    }
}

// MARK: - Exporting several transcripts at once

public enum TranscriptBatchExport {
    public struct Item: Equatable, Sendable {
        public var base: String
        public var fileName: String
    }

    public struct Outcome: Equatable, Sendable {
        public var written: [URL] = []
        public var failures: [String] = []
    }

    /// One file name per note: `<base>.<ext>`, with " 2", " 3"… when the folder
    /// already has that name (an existing file is never overwritten).
    public static func plan(bases: [String], format: TranscriptExportFormat, existing: Set<String>) -> [Item] {
        var taken = Set(existing.map { $0.lowercased() })
        var out: [Item] = []
        for base in bases {
            let stem = base.replacingOccurrences(of: "/", with: "_")
            var name = "\(stem).\(format.fileExtension)"
            var n = 2
            while taken.contains(name.lowercased()) {
                name = "\(stem) \(n).\(format.fileExtension)"
                n += 1
            }
            taken.insert(name.lowercased())
            out.append(Item(base: base, fileName: name))
        }
        return out
    }

    /// Render and write each note's timed transcript into `folder`.
    public static func run(bases: [String], format: TranscriptExportFormat, workDir: URL, folder: URL,
                           fileManager fm: FileManager = .default) -> Outcome {
        let existing = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
        var outcome = Outcome()
        for item in plan(bases: bases, format: format, existing: existing) {
            guard let transcript = TranscriptSegments.load(workDir: workDir, base: item.base) else {
                outcome.failures.append("\(item.base): \(NotesLibrary.noTimestamps)")
                continue
            }
            do {
                let url = folder.appendingPathComponent(item.fileName)
                try format.render(transcript, title: item.base).write(to: url, options: .withoutOverwriting)
                outcome.written.append(url)
            } catch {
                outcome.failures.append("\(item.base): \(error.localizedDescription)")
            }
        }
        return outcome
    }
}
