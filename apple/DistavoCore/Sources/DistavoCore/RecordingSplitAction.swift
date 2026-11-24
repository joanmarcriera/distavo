import Foundation

// RecordingSplitAction.swift — "Split recording…" in the Notes window (D077, D078, task 6668): the file side.
//
// Built on the pure pieces of `RecordingSplit` (silences, candidates, ranges, cut, sidecars, marks). For one
// chosen silence it writes two new recordings beside the original, "<name> part 1.<ext>" and
// "<name> part 2.<ext>" (names that collide with nothing: `RecordingSplit.halfBases(of:existing:)`), copies the
// sidecars a half inherits (`sidecarsToCopy`, copied, never moved) and the re-timed key moments, and leaves the
// halves without a marker so the next scan processes them. Nothing is lost:
//  - the original audio stays where it is, untouched, with a `.done` marker so it is not processed again;
//  - the old note, which may have been edited by hand, is moved to its `.prev-` backup with
//    `NoteVersions.keepPrevious` (never deleted; every listing skips it); the two new notes appear beside it.
// A silence outside the file (or a missing source) throws before any file is touched; when anything after the
// first cut fails, every file this call wrote (the halves, their copied sidecars and marks) is removed again and
// the original keeps its note. No other delete. Each half gets the right start date: its file creation date
// (the original start, plus the cut offset for part 2) and, for a recorder-stamped name
// ("Meeting 2026-11-18 09.00.00"), part 2's stamp moved to its own start.

public enum RecordingSplitAction {

    public struct Outcome: Equatable, Sendable {
        public var first: URL
        public var second: URL
        public var firstBase: String
        public var secondBase: String
        /// The old note's `.prev-` backup; nil when the recording had no note yet.
        public var noteBackup: URL?
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case missingSource, unreadable, outsideFile, noFreeName

        public var errorDescription: String? {
            switch self {
            case .missingSource: return "the original recording is not where it was"
            case .unreadable: return "Distavo cannot read this recording's audio to find a split point"
            case .outsideFile: return "that silence is not inside the recording"
            case .noFreeName: return "no free name for the two halves"
            }
        }
    }

    public static func perform(source: URL, silence: RecordingSplit.Silence, duration: Double,
                               recordingsDir: URL, notesDir: URL, workDir: URL, now: Date = Date()) throws -> Outcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw Failure.missingSource }
        guard let cut = RecordingSplit.ranges(for: silence, duration: duration) else { throw Failure.outsideFile }

        let state = try DistavoState.Store(stateDir: workDir.appendingPathComponent(".state"), notesDir: notesDir)
        let base = DistavoState.baseFor(recordingsDir: recordingsDir, path: source)
        let start = Pipeline.meetingDate(for: source)
        let folder = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        // Bases already in use: notes, recordings beside the source, work-folder sidecars and markers.
        var existing = Set<String>()
        for dir in [notesDir, folder] {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                existing.insert((name as NSString).deletingPathExtension)
                existing.insert(DistavoState.baseFor(recordingsDir: recordingsDir,
                                                     path: dir.appendingPathComponent(name)))
            }
        }
        let workNames = (try? fm.contentsOfDirectory(atPath: workDir.path)) ?? []
        let stateNames = (try? fm.contentsOfDirectory(atPath: workDir.appendingPathComponent(".state").path)) ?? []
        // A base is in use when a note/recording has it or any work-folder file or marker starts with "<base>.".
        func inUse(_ b: String) -> Bool {
            existing.contains(b) || (workNames + stateNames).contains { $0.hasPrefix(b + ".") }
        }

        // File stems and their bases must both be free.
        var taken = existing
        var chosen: (first: URL, second: URL, firstBase: String, secondBase: String)?
        for _ in 0..<99 {
            let names = RecordingSplit.halfBases(of: stem, existing: taken)
            let first = folder.appendingPathComponent(names.first).appendingPathExtension(ext)
            let second = folder.appendingPathComponent(
                restamped(names.second, by: cut.second.lowerBound)).appendingPathExtension(ext)
            let b1 = DistavoState.baseFor(recordingsDir: recordingsDir, path: first)
            let b2 = DistavoState.baseFor(recordingsDir: recordingsDir, path: second)
            if !inUse(b1), !inUse(b2), b1 != b2,
               !fm.fileExists(atPath: first.path), !fm.fileExists(atPath: second.path) {
                chosen = (first, second, b1, b2); break
            }
            taken.insert(names.first); taken.insert(names.second)
        }
        guard let names = chosen else { throw Failure.noFreeName }

        // Every file this call writes, so a failure can take them all back.
        var written: [URL] = []
        var backup: URL?
        do {
            // 1. The two halves (each written atomically by `cut`), dated like the meetings they hold.
            try RecordingSplit.cut(source: source, range: cut.first, destination: names.first)
            written.append(names.first)
            try RecordingSplit.cut(source: source, range: cut.second, destination: names.second)
            written.append(names.second)
            if let start {
                try? fm.setAttributes([.creationDate: start, .modificationDate: start], ofItemAtPath: names.first.path)
                let later = start.addingTimeInterval(cut.second.lowerBound)
                try? fm.setAttributes([.creationDate: later, .modificationDate: later], ofItemAtPath: names.second.path)
            }

            // 2. Sidecars a half inherits (copied) and the re-timed key moments.
            for name in RecordingSplit.sidecarsToCopy(names: workNames, base: base) {
                let suffix = String(name.dropFirst(base.count))
                for half in [names.firstBase, names.secondBase] {
                    let target = workDir.appendingPathComponent(half + suffix)
                    if !fm.fileExists(atPath: target.path) {
                        try fm.copyItem(at: workDir.appendingPathComponent(name), to: target)
                        written.append(target)
                    }
                }
            }
            if let marks = RecordingBookmarks.load(workDir: workDir, base: base)?.marks, !marks.isEmpty {
                let (a, b) = RecordingSplit.splitMarks(marks, cut: cut)
                if !a.isEmpty {
                    try RecordingBookmarks(marks: a).save(workDir: workDir, base: names.firstBase)
                    written.append(RecordingBookmarks.url(workDir: workDir, base: names.firstBase))
                }
                if !b.isEmpty {
                    try RecordingBookmarks(marks: b).save(workDir: workDir, base: names.secondBase)
                    written.append(RecordingBookmarks.url(workDir: workDir, base: names.secondBase))
                }
            }

            // 3. The old note becomes its `.prev-` backup (the last step that can fail).
            let note = state.notePath(base)
            if fm.fileExists(atPath: note.path) { backup = try NoteVersions.keepPrevious(note: note, now: now) }
        } catch {
            for url in written.reversed() { try? fm.removeItem(at: url) }   // only what this call wrote
            throw error
        }
        // 4. The original stays done, so it is never processed again.
        state.markDone(base)

        return Outcome(first: names.first, second: names.second,
                       firstBase: names.firstBase, secondBase: names.secondBase, noteBackup: backup)
    }

    /// A recorder-stamped name ("... 2026-11-18 09.00.00 ...") with the stamp moved on by `seconds`, so part 2
    /// is dated at its own start (the name wins over the file date, `Pipeline.meetingDate`). Other names unchanged.
    static func restamped(_ name: String, by seconds: Double, timeZone: TimeZone = .current) -> String {
        guard let range = name.range(of: #"\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}"#, options: .regularExpression),
              let date = Pipeline.recorderNameDate(String(name[range]), timeZone: timeZone) else { return name }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return name.replacingCharacters(in: range, with: f.string(from: date.addingTimeInterval(seconds)))
    }
}
