import Foundation

// "Rename speakers across the note" (Vikunja #2944, phase 1).
//
// A recording's speakers appear as diariser labels (`SPEAKER_00`, ...) in three
// places that must stay consistent so a later export or "Regenerate Note…"
// shows the new names:
//   * the note Markdown                      <notesDir>/<base>.md
//   * the cached clean transcript            <workDir>/<base>.transcript.clean.txt
//   * the timed sidecar (segment/word speakers) <workDir>/<base>.segments.json
// plus a small mapping sidecar `<workDir>/<base>.speaker-names.json` recording
// original diariser label -> current name, so renames compose and the original
// labels stay recoverable.
//
// Pure and dependency-free. Matching is by whole token (never a substring), all
// renames in one call apply simultaneously (so A<->B swaps work), and the write
// is all-or-nothing: temp siblings first, then renamed into place with a
// rollback on any failure. The previous note is kept as `<base>.prev-<stamp>.md`
// (`NoteVersions`), which scanners ignore.

/// One speaker found in a note / transcript, for the rename sheet.
public struct DetectedSpeaker: Equatable, Sendable {
    public var label: String
    /// Number of speaker turns (transcript headers, else segment runs, else
    /// occurrences in the note).
    public var turns: Int
    /// A short line this speaker said, to tell who is who; "" when unknown.
    public var sample: String
}

/// `<base>.speaker-names.json`: original diariser label -> current name.
public struct SpeakerNames: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var names: [String: String]

    public init(version: Int = SpeakerNames.currentVersion, names: [String: String] = [:]) {
        self.version = version; self.names = names
    }

    public static func url(workDir: URL, base: String) -> URL {
        workDir.appendingPathComponent("\(base).speaker-names.json")
    }

    public static func load(workDir: URL, base: String) -> SpeakerNames? {
        guard let data = try? Data(contentsOf: url(workDir: workDir, base: base)) else { return nil }
        return try? JSONDecoder().decode(SpeakerNames.self, from: data)
    }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    /// Fold a batch of current-label -> new-name renames into the mapping. Every
    /// original whose current name is a renamed label follows it (so a merge, or a
    /// later rename of a merged name, moves all of them); a label that is not
    /// tracked yet is recorded as its own original. Computed against a snapshot,
    /// so a swap composes correctly.
    func composing(_ applied: [String: String], presentLabels: Set<String> = []) -> SpeakerNames {
        var next = names
        // Merging into a label that exists in the files but is not tracked yet
        // (SPEAKER_01 -> SPEAKER_00): record it as its own original so a later rename of the merged name
        // carries it along too. The loop below overwrites it if it is itself renamed.
        let currentNames = Set(names.values)
        for (_, new) in applied where presentLabels.contains(new) && names[new] == nil && !currentNames.contains(new) {
            next[new] = new
        }
        for (old, new) in applied {
            let followers = names.filter { $0.value == old }.map(\.key)
            if followers.isEmpty { if names[old] == nil { next[old] = new } }
            else { for k in followers { next[k] = new } }
        }
        return SpeakerNames(version: version, names: next)
    }
}

public enum SpeakerRenameError: Error, Equatable, LocalizedError {
    case emptyName(String)
    case invalidName(String)
    case nothingToRename(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName(let l): return "The new name for \(l) is empty."
        case .invalidName(let n): return "“\(n)” is not a valid speaker name (no line breaks or square brackets, at most \(SpeakerRename.maxNameLength) characters)."
        case .nothingToRename(let base): return "There is nothing to rename for \(base): no note and no saved transcript."
        }
    }
}

public struct SpeakerRenameResult: Equatable, Sendable {
    /// File names that were rewritten (empty = the rename was a no-op).
    public var changedFiles: [String]
    /// The kept previous note, when the note changed.
    public var backup: URL?
}

public enum SpeakerRename {
    public static let maxNameLength = 80

    // MARK: Detection

    /// Distinct speaker labels across whatever sources exist, in first-seen order
    /// (transcript, then segments, then the note), each with a turn count and a
    /// sample line. A label the diariser was unsure of (`SPEAKER_UNKNOWN`) is not
    /// listed. All three inputs are optional.
    public static func detectSpeakers(note: String?, transcript: String?,
                                      segments: TranscriptSegments?) -> [DetectedSpeaker] {
        var order: [String] = []
        var turns: [String: Int] = [:]
        var sample: [String: String] = [:]
        func see(_ label: String) { if turns[label] == nil { order.append(label); turns[label] = 0 } }

        // 1. Clean transcript: "[LABEL]\ntext" blocks.
        if let transcript {
            var current: String?
            for raw in transcript.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.count > 2, line.hasPrefix("["), line.hasSuffix("]") {
                    let label = String(line.dropFirst().dropLast())
                    if label == "SPEAKER_UNKNOWN" { current = nil; continue }
                    see(label); turns[label]! += 1; current = label
                } else if let c = current, !line.isEmpty {
                    if sample[c] == nil { sample[c] = line }
                    current = nil
                }
            }
        }
        // 2. Timed segments: runs of the same speaker count as one turn.
        if let segments {
            var prev: String?
            var counted: [String: Int] = [:]
            for seg in segments.segments {
                guard let s = seg.speaker, !s.isEmpty, s != "SPEAKER_UNKNOWN" else { prev = nil; continue }
                if turns[s] == nil || transcript == nil { see(s) }
                if s != prev { counted[s, default: 0] += 1 }
                if sample[s] == nil { sample[s] = seg.text }
                prev = s
            }
            if transcript == nil { for (k, v) in counted { turns[k] = v } }
        }
        // 3. The note: diariser-style labels the summary copied verbatim.
        if let note, let re = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])SPEAKER_\d+(?![A-Za-z0-9_])"#) {
            let ns = note as NSString
            for m in re.matches(in: note, range: NSRange(location: 0, length: ns.length)) {
                let label = ns.substring(with: m.range)
                let known = turns[label] != nil
                see(label)
                if transcript == nil && segments == nil { turns[label]! += 1 } else if !known { turns[label]! += 1 }
            }
        }
        return order.map { DetectedSpeaker(label: $0, turns: turns[$0] ?? 0, sample: shorten(sample[$0] ?? "")) }
    }

    private static func shorten(_ s: String, limit: Int = 90) -> String {
        let t = TranscriptCleaner.normaliseSpace(s)
        return t.count <= limit ? t : String(t.prefix(limit - 1)) + "…"
    }

    // MARK: Rewriting

    /// Validate and normalise a mapping: trims names, drops no-op entries,
    /// rejects empty or malformed names.
    public static func normalised(_ mapping: [String: String]) throws -> [String: String] {
        var out: [String: String] = [:]
        for (old, raw) in mapping {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { throw SpeakerRenameError.emptyName(old) }
            if name.count > maxNameLength || name.contains(where: { $0.isNewline || $0 == "[" || $0 == "]" }) {
                throw SpeakerRenameError.invalidName(raw)
            }
            if name != old { out[old] = name }
        }
        return out
    }

    /// Replace every whole-token occurrence of each key by its value, all at
    /// once. A token boundary is any character that is not a letter, digit or
    /// underscore, so `SPEAKER_1` never touches `SPEAKER_10`. Names are matched
    /// literally (regex metacharacters escaped).
    public static func rewrite(_ text: String, mapping: [String: String]) -> String {
        guard !mapping.isEmpty, !text.isEmpty else { return text }
        let keys = mapping.keys.sorted { $0.count > $1.count }   // longest first
        let alternation = keys.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard let re = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}_])(?:\(alternation))(?![\\p{L}\\p{N}_])") else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += mapping[ns.substring(with: m.range)] ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// The segments sidecar with speaker (and per-word speaker) labels renamed.
    /// Exact match on the label, not token search: the field holds only a label.
    static func rewrite(_ t: TranscriptSegments, mapping: [String: String]) -> TranscriptSegments {
        var t = t
        for i in t.segments.indices {
            if let s = t.segments[i].speaker, let n = mapping[s] { t.segments[i].speaker = n }
            if var words = t.segments[i].words {
                for j in words.indices { if let s = words[j].speaker, let n = mapping[s] { words[j].speaker = n } }
                t.segments[i].words = words
            }
        }
        return t
    }

    // MARK: Apply

    /// Rename speakers for `base`, rewriting the note, the cached transcript and
    /// the segments sidecar, and recording the mapping. `mapping` is current
    /// label -> new name. Missing optional files are skipped. All-or-nothing:
    /// on any failure every file is back as it was and the error is thrown.
    ///
    /// - Parameter moveItem: test seam so a unit test can fail a step mid-commit.
    @discardableResult
    public static func apply(
        mapping rawMapping: [String: String], base: String, notesDir: URL, workDir: URL,
        now: Date = Date(),
        moveItem: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws -> SpeakerRenameResult {
        let mapping = try normalised(rawMapping)
        let fm = FileManager.default
        let notePath = notesDir.appendingPathComponent("\(base).md")
        let transcriptPath = Pipeline.cachedTranscriptURL(workDir: workDir, base: base)
        let namesPath = SpeakerNames.url(workDir: workDir, base: base)

        let note = try? String(contentsOf: notePath, encoding: .utf8)
        let transcript = try? String(contentsOf: transcriptPath, encoding: .utf8)
        let segments = TranscriptSegments.load(workDir: workDir, base: base)
        guard note != nil || transcript != nil else { throw SpeakerRenameError.nothingToRename(base) }
        if mapping.isEmpty { return SpeakerRenameResult(changedFiles: [], backup: nil) }

        // Compute every new file content first; only differing ones are written.
        struct Job { let url: URL; let data: Data; let isNote: Bool }
        var jobs: [Job] = []
        if let note {
            let new = rewrite(note, mapping: mapping)
            if new != note { jobs.append(Job(url: notePath, data: Data(new.utf8), isNote: true)) }
        }
        if let transcript {
            let new = rewrite(transcript, mapping: mapping)
            if new != transcript { jobs.append(Job(url: transcriptPath, data: Data(new.utf8), isNote: false)) }
        }
        if let segments {
            let new = rewrite(segments, mapping: mapping)
            if new != segments {
                jobs.append(Job(url: TranscriptSegments.url(workDir: workDir, base: base),
                                data: try new.encoded(), isNote: false))
            }
        }
        // The mapping sidecar is recorded only when something was renamed, so an
        // idempotent re-apply leaves no trace.
        if !jobs.isEmpty {
            let current = SpeakerNames.load(workDir: workDir, base: base) ?? SpeakerNames()
            let present = Set(detectSpeakers(note: note, transcript: transcript, segments: segments).map(\.label))
            jobs.append(Job(url: namesPath, data: try current.composing(mapping, presentLabels: present).encoded(), isNote: false))
        }
        if jobs.isEmpty { return SpeakerRenameResult(changedFiles: [], backup: nil) }

        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let token = UUID().uuidString.prefix(8)
        func sibling(_ url: URL, _ tag: String) -> URL {
            url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(tag)-\(token)")
        }

        // Phase 1: write every new version beside its target.
        var temps: [URL] = []
        func cleanTemps() { for t in temps { try? fm.removeItem(at: t) } }
        do {
            for job in jobs {
                let tmp = sibling(job.url, "rename-tmp")
                try job.data.write(to: tmp)
                temps.append(tmp)
            }
        } catch { cleanTemps(); throw error }

        // Phase 2: move originals aside, new versions in; undo everything on failure.
        // `undo` entries run newest-first.
        var undo: [() -> Void] = []
        var backup: URL?
        do {
            for (job, tmp) in zip(jobs, temps) {
                var original: URL?
                if fm.fileExists(atPath: job.url.path) {
                    if job.isNote {
                        let kept = try NoteVersions.keepPrevious(note: job.url, now: now)
                        backup = kept
                        original = kept
                    } else {
                        let aside = sibling(job.url, "rename-orig")
                        try moveItem(job.url, aside)
                        original = aside
                    }
                }
                do { try moveItem(tmp, job.url) } catch {
                    if let original { try? fm.moveItem(at: original, to: job.url) }
                    throw error
                }
                let isNote = job.isNote
                undo.append {
                    try? fm.removeItem(at: job.url)
                    if let original { try? fm.moveItem(at: original, to: job.url) }
                    if isNote { backup = nil }
                }
            }
        } catch {
            for u in undo.reversed() { u() }
            cleanTemps()
            throw error
        }
        // Committed: drop the set-aside originals of the non-note files (the
        // note's original stays as the kept `.prev-` backup).
        for job in jobs where !job.isNote { try? fm.removeItem(at: sibling(job.url, "rename-orig")) }
        return SpeakerRenameResult(changedFiles: jobs.map { $0.url.lastPathComponent }, backup: backup)
    }
}
