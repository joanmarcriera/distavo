import Foundation
#if canImport(Darwin)
import Darwin
#endif

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
// labels stay recoverable ("Reset to original labels").
//
// WHAT IS REWRITTEN (the matching rule is deliberately narrow, because this edits
// the user's own note):
//   * transcript + segments: ONLY speaker label positions (a turn's `[LABEL]`
//     header; `speaker` fields). Spoken text is never touched.
//   * note: diariser-style labels (`SPEAKER_00`, also `Speaker 1` / `Speaker_00`)
//     everywhere except code spans/fences, URLs and the provenance footer;
//     human names ONLY in label positions (see `NoteRewriter`). Prose mentions of
//     a name are left alone.
// All renames in one call apply simultaneously (A<->B swaps work), names are
// matched literally and under canonical Unicode equivalence, and the write is
// all-or-nothing: temp siblings first, then renamed into place with rollback.
// The previous note is kept as `<base>.prev-<stamp>.md` (`NoteVersions`).

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

    /// nil when absent, corrupt, or written by a newer Distavo (readers that only
    /// want a best-effort view, e.g. Regenerate, use this; `apply` is strict).
    public static func load(workDir: URL, base: String) -> SpeakerNames? {
        if case .ok(let n) = inspect(workDir: workDir, base: base) { return n }
        return nil
    }

    enum State { case none, ok(SpeakerNames), corrupt, newer(Int) }

    static func inspect(workDir: URL, base: String) -> State {
        let u = url(workDir: workDir, base: base)
        guard FileManager.default.fileExists(atPath: u.path) else { return .none }
        guard let data = try? Data(contentsOf: u),
              let n = try? JSONDecoder().decode(SpeakerNames.self, from: data) else { return .corrupt }
        return n.version > currentVersion ? .newer(n.version) : .ok(n)
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
    /// so a swap composes correctly. Entries that end up as identity (renamed back
    /// to the original label) are dropped.
    func composing(_ applied: [String: String], presentLabels: Set<String> = []) -> SpeakerNames {
        var next = names
        // Merging into a label that exists in the files but is not tracked yet
        // (SPEAKER_01 -> SPEAKER_00): record it as its own original so a later rename
        // of the merged name carries it along too. The loop below overwrites it if
        // it is itself renamed.
        let currentNames = Set(names.values)
        for (_, new) in applied where presentLabels.contains(new) && names[new] == nil && !currentNames.contains(new) {
            next[new] = new
        }
        for (old, new) in applied {
            let followers = names.filter { $0.value == old }.map(\.key)
            if followers.isEmpty { if names[old] == nil { next[old] = new } }
            else { for k in followers { next[k] = new } }
        }
        // Drop identity entries (renamed back to the original label) unless another
        // original was merged into that label.
        let counts = Dictionary(next.values.map { ($0, 1) }, uniquingKeysWith: +)
        next = next.filter { $0.key != $0.value || (counts[$0.value] ?? 0) > 1 }
        return SpeakerNames(version: version, names: next)
    }

    /// What Regenerate should tell the summariser for this recording: the owner's
    /// speaker label as renamed here (config is never touched), and the
    /// participants hint extended with a line explaining the renamed labels.
    /// Returns the inputs unchanged when nothing was renamed.
    public static func regenerateContext(userSpeaker: String, participants: String?,
                                         workDir: URL, base: String) -> (userSpeaker: String, participants: String?) {
        guard let n = load(workDir: workDir, base: base), !n.names.isEmpty else { return (userSpeaker, participants) }
        let key = userSpeaker.precomposedStringWithCanonicalMapping
        let owner = n.names[key] ?? userSpeaker
        let list = n.names.sorted { $0.key < $1.key }.prefix(12)
            .map { "\($0.key) is now \"\($0.value)\"" }.joined(separator: "; ")
        let line = "The speaker labels in this transcript were renamed after transcription (\(list)). " +
                   "The transcript's labels are the new names: use them exactly as written."
        let base = participants?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (owner, base.isEmpty ? line : base + "\n" + line)
    }
}

public enum SpeakerRenameError: Error, Equatable, LocalizedError {
    case emptyName(String)
    case invalidName(String)
    case nothingToRename(String)
    case unreadable(String)
    case newerSidecar(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyName(let l): return "The new name for \(l) is empty."
        case .invalidName(let n): return "“\(n)” is not a valid speaker name (no line breaks or square brackets, at most \(SpeakerRename.maxNameLength) characters)."
        case .nothingToRename(let base): return "There is nothing to rename for \(base): no note and no saved transcript."
        case .unreadable(let f): return "\(f) could not be read as UTF-8 text, so nothing was renamed."
        case .newerSidecar(let v): return "The speaker names file was written by a newer Distavo (format \(v)); update Distavo before renaming speakers. Nothing was changed."
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

    private static let wordChars = #"\p{L}\p{N}\p{M}_"#   // letters, digits, combining marks, underscore

    private static func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    private static func diariserNumber(_ label: String) -> Int? {
        guard label.hasPrefix("SPEAKER_"), let n = Int(label.dropFirst(8)), label.dropFirst(8).allSatisfy(\.isNumber) else { return nil }
        return n
    }

    // MARK: Detection

    /// Distinct speaker labels across whatever sources exist, in first-seen order
    /// (transcript, then segments, then the note), each with a turn count and a
    /// sample line. A label the diariser was unsure of (`SPEAKER_UNKNOWN`) is not
    /// listed. All three inputs are optional. Labels are NFC-normalised.
    public static func detectSpeakers(note: String?, transcript: String?,
                                      segments: TranscriptSegments?) -> [DetectedSpeaker] {
        var order: [String] = []
        var turns: [String: Int] = [:]
        var sample: [String: String] = [:]
        func see(_ label: String) { if turns[label] == nil { order.append(label); turns[label] = 0 } }

        // 1. Clean transcript: "[LABEL]\ntext" blocks.
        if let transcript {
            var current: String?
            var blockStart = true
            for raw in transcript.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if blockStart, let label = headerLabel(line) {
                    if label == "SPEAKER_UNKNOWN" { current = nil } else {
                        see(label); turns[label]! += 1; current = label
                    }
                } else if let c = current, !line.isEmpty {
                    if sample[c] == nil { sample[c] = line }
                    current = nil
                }
                blockStart = line.isEmpty
            }
        }
        // 2. Timed segments: runs of the same speaker count as one turn.
        if let segments {
            var prev: String?
            var counted: [String: Int] = [:]
            for seg in segments.segments {
                guard let raw = seg.speaker, !raw.isEmpty, raw != "SPEAKER_UNKNOWN" else { prev = nil; continue }
                let s = nfc(raw)
                see(s)
                if s != prev { counted[s, default: 0] += 1 }
                if sample[s] == nil { sample[s] = seg.text }
                prev = s
            }
            if transcript == nil { for (k, v) in counted { turns[k] = v } }
        }
        // 3. The note: diariser-style labels the summary copied verbatim.
        if let note, let re = try? NSRegularExpression(pattern: "(?<![\(wordChars)])SPEAKER_\\d+(?![\(wordChars)])") {
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

    /// `[LABEL]` on its own line -> NFC label.
    private static func headerLabel(_ trimmed: String) -> String? {
        guard trimmed.count > 2, trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        return nfc(String(trimmed.dropFirst().dropLast()))
    }

    private static func shorten(_ s: String, limit: Int = 90) -> String {
        let t = TranscriptCleaner.normaliseSpace(s)
        return t.count <= limit ? t : String(t.prefix(limit - 1)) + "…"
    }

    // MARK: Mapping helpers

    /// Validate and normalise a mapping: NFC-normalises labels and names, trims
    /// names, drops no-op entries, rejects empty or malformed names.
    public static func normalised(_ mapping: [String: String]) throws -> [String: String] {
        var out: [String: String] = [:]
        for (rawOld, raw) in mapping {
            let old = nfc(rawOld)
            let name = nfc(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            if name.isEmpty { throw SpeakerRenameError.emptyName(old) }
            if name.count > maxNameLength || name.contains(where: { $0.isNewline || $0 == "[" || $0 == "]" }) {
                throw SpeakerRenameError.invalidName(raw)
            }
            if name != old { out[old] = name }
        }
        return out
    }

    /// The merges a (normalised) mapping would cause: two labels given the same
    /// name, or a label renamed to another speaker that stays. Used to ask the user
    /// to confirm, since a merge loses information.
    public static func merges(_ mapping: [String: String], present: [String]) -> [(from: [String], into: String)] {
        var byNew: [String: [String]] = [:]
        for (old, new) in mapping { byNew[new, default: []].append(old) }
        let presentSet = Set(present.map(nfc))
        var out: [(from: [String], into: String)] = []
        for (new, olds) in byNew {
            if olds.count >= 2 || (presentSet.contains(new) && mapping[new] == nil) {
                out.append((from: olds.sorted(), into: new))
            }
        }
        return out.sorted { $0.into < $1.into }
    }

    /// current name -> original diariser label for every speaker that was renamed
    /// one-to-one. Merged speakers cannot be separated again, so they are left out.
    public static func resetMapping(workDir: URL, base: String) -> [String: String] {
        guard let n = SpeakerNames.load(workDir: workDir, base: base) else { return [:] }
        var byCurrent: [String: [String]] = [:]
        for (orig, cur) in n.names { byCurrent[cur, default: []].append(orig) }
        var out: [String: String] = [:]
        for (cur, origs) in byCurrent where origs.count == 1 && origs[0] != cur { out[cur] = origs[0] }
        return out
    }

    // MARK: Rewriting: transcript and segments (label positions only)

    /// Rename the `[LABEL]` header of each turn. Spoken text is never touched.
    static func rewriteTranscript(_ text: String, mapping: [String: String]) -> String {
        guard !mapping.isEmpty else { return text }
        var lines = text.components(separatedBy: "\n")
        var blockStart = true
        for i in lines.indices {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if blockStart, let label = headerLabel(trimmed), let new = mapping[label] {
                let lead = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                let trail = String(line.reversed().prefix(while: { $0 == " " || $0 == "\t" || $0 == "\r" }).reversed())
                lines[i] = lead + "[" + new + "]" + trail
            }
            blockStart = trimmed.isEmpty
        }
        return lines.joined(separator: "\n")
    }

    /// The segments sidecar with speaker (and per-word speaker) labels renamed.
    /// Exact match on the label (canonical equivalence), never on the text.
    static func rewrite(_ t: TranscriptSegments, mapping: [String: String]) -> TranscriptSegments {
        var t = t
        for i in t.segments.indices {
            if let s = t.segments[i].speaker, let n = mapping[nfc(s)] { t.segments[i].speaker = n }
            if var words = t.segments[i].words {
                for j in words.indices { if let s = words[j].speaker, let n = mapping[nfc(s)] { words[j].speaker = n } }
                t.segments[i].words = words
            }
        }
        return t
    }

    // MARK: Rewriting: the note

    /// Rewrite a note. See the file header for the rule. The provenance footer
    /// ("Transcribed on this Mac with …") is never touched.
    static func rewriteNote(_ text: String, mapping: [String: String]) -> String {
        guard !mapping.isEmpty, !text.isEmpty else { return text }
        var body = text
        var footer = ""
        if let f = Pipeline.provenanceFooter(in: text), text.hasSuffix(f) {
            body = String(text.dropLast(f.count)); footer = f
        }
        let rules = NoteRewriter(mapping: mapping)
        var out: [String] = []
        var inFence = false
        var fence = ""
        var inSpeakers = false
        var ownerCol: Int?
        for raw in body.components(separatedBy: "\n") {
            let cr = raw.hasSuffix("\r")
            let line = cr ? String(raw.dropLast()) : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var result = line
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if !inFence { inFence = true; fence = marker } else if marker == fence { inFence = false }
            } else if !inFence {
                let isHeading = trimmed.range(of: #"^#{1,6}(\s|$)"#, options: .regularExpression) != nil
                if isHeading {
                    let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                    inSpeakers = title.caseInsensitiveCompare("Speakers") == .orderedSame
                }
                if !trimmed.hasPrefix("|") { ownerCol = nil }
                result = rules.rewriteLine(line, isHeading: isHeading, inSpeakers: inSpeakers, ownerCol: &ownerCol)
            }
            out.append(cr ? result + "\r" : result)
        }
        return out.joined(separator: "\n") + footer
    }

    /// Line-level rules for the note. Candidates are collected per line, anything
    /// touching code spans or URLs is dropped, then applied right to left.
    private struct NoteRewriter {
        let mapping: [String: String]
        let diariser: [Int: String]            // number -> key (value looked up in mapping)
        let humanAlt: String?                  // regex alternation of non-diariser keys
        let diariserRe: NSRegularExpression?
        let protectedRe = try! NSRegularExpression(
            pattern: #"`[^`\n]*`|<?https?://[^\s<>)\]]+>?|\]\([^)\n]*\)|\bwww\.[^\s<>)\]]+"#)
        let start, paren, owner: NSRegularExpression?

        init(mapping: [String: String]) {
            self.mapping = mapping
            var dia: [Int: String] = [:]
            var human: [String] = []
            for k in mapping.keys {
                if let n = SpeakerRename.diariserNumber(k) { dia[n] = k } else { human.append(k) }
            }
            diariser = dia
            let w = SpeakerRename.wordChars
            diariserRe = dia.isEmpty ? nil : try? NSRegularExpression(
                pattern: "(?<![\(w)])(?i:speaker)[ _](\\d+)(?![\(w)])")
            if human.isEmpty {
                humanAlt = nil; start = nil; paren = nil; owner = nil
                return
            }
            // Longest first, both composed and decomposed spellings.
            var forms: [String] = []
            for k in human.sorted(by: { $0.count > $1.count }) {
                // Swift String == is canonical, so compare the UTF-8 bytes to keep
                // both the composed and the decomposed spelling.
                var seen: [[UInt8]] = []
                for f in [k, k.decomposedStringWithCanonicalMapping] where !seen.contains(Array(f.utf8)) {
                    seen.append(Array(f.utf8))
                    forms.append(NSRegularExpression.escapedPattern(for: f))
                }
            }
            let alt = forms.joined(separator: "|")
            humanAlt = alt
            let b = "(?<![\(w)])"
            let a = "(?![\(w)])"
            let lead = #"^(\s*(?:>\s*)*(?:[-*+]\s+|\d+[.)]\s+)?(?:\*\*|__)?)"#
            start = try? NSRegularExpression(
                pattern: lead + "(?:" + b + ")(" + alt + ")" + a + #"(?=(?:\*\*|__)?\s*:)"#)
            paren = try? NSRegularExpression(pattern: #"(?<=\()(?:"# + alt + #")(?=\)|[,;:])"#)
            owner = try? NSRegularExpression(
                pattern: #"(?<!note )(?<!Note )(?<!NOTE )(?i:owner)\s*:\s*(?:\*\*|__)?"# + b + "(" + alt + ")" + a
                    + #"(?=\s*(?:$|[,;.)|*_]|—|–))"#)
        }

        func rewriteLine(_ line: String, isHeading: Bool, inSpeakers: Bool, ownerCol: inout Int?) -> String {
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            var cands: [(NSRange, String)] = []
            func lookup(_ s: String) -> String? { mapping[s.precomposedStringWithCanonicalMapping] }

            // Diariser-style labels: unambiguous tokens, replaced anywhere.
            if let re = diariserRe {
                for m in re.matches(in: line, range: full) {
                    if let n = Int(ns.substring(with: m.range(at: 1))), let key = diariser[n], let new = mapping[key] {
                        cands.append((m.range, new))
                    }
                }
            }
            if humanAlt != nil, !isHeading {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isTableRow = trimmed.hasPrefix("|")
                if !isTableRow {
                    // `**Name:**` / `Name:` at the start of a line or list item; in a
                    // `## Speakers` section also `Name — …`, `Name (…)`, bare `Name`.
                    if let re = start {
                        for m in re.matches(in: line, range: full) {
                            let r = m.range(at: 2)
                            if let new = lookup(ns.substring(with: r)) { cands.append((r, new)) }
                        }
                    }
                    if inSpeakers, let alt = humanAlt {
                        let w = SpeakerRename.wordChars
                        let lead = #"^(\s*(?:>\s*)*(?:[-*+]\s+|\d+[.)]\s+)?(?:\*\*|__)?)"#
                        if let re = try? NSRegularExpression(
                            pattern: lead + "(?<![\(w)])(" + alt + ")(?![\(w)])" + #"(?=(?:\*\*|__)?\s*(?:—|–|\s-\s|\(|$))"#) {
                            for m in re.matches(in: line, range: full) {
                                let r = m.range(at: 2)
                                if let new = lookup(ns.substring(with: r)) { cands.append((r, new)) }
                            }
                        }
                    }
                    // `(Name)` / `(Name, …)` attribution.
                    if let re = paren {
                        for m in re.matches(in: line, range: full) {
                            if let new = lookup(ns.substring(with: m.range)) { cands.append((m.range, new)) }
                        }
                    }
                    // `owner: Name`.
                    if let re = owner {
                        for m in re.matches(in: line, range: full) {
                            let r = m.range(at: 1)
                            if let new = lookup(ns.substring(with: r)) { cands.append((r, new)) }
                        }
                    }
                } else {
                    cands += tableCandidates(line, ns: ns, ownerCol: &ownerCol, lookup: lookup)
                }
            }

            // Drop anything touching protected text, already-renamed text, overlaps.
            let prot = protectedRe.matches(in: line, range: full).map(\.range)
            let ok = cands.filter { c in
                if prot.contains(where: { NSIntersectionRange($0, c.0).length > 0 || NSLocationInRange(c.0.location, $0) }) { return false }
                let old = ns.substring(with: c.0)
                if c.1 != old, c.1.hasPrefix(old), ns.length - c.0.location >= (c.1 as NSString).length,
                   ns.substring(with: NSRange(location: c.0.location, length: (c.1 as NSString).length)) == c.1 {
                    return false   // "Anna" -> "Anna Puig" already applied here
                }
                return true
            }.sorted { $0.0.location < $1.0.location }
            var chosen: [(NSRange, String)] = []
            for c in ok where chosen.last.map({ NSMaxRange($0.0) <= c.0.location }) ?? true { chosen.append(c) }
            var result = line as NSString
            for (r, new) in chosen.reversed() { result = result.replacingCharacters(in: r, with: new) as NSString }
            return result as String
        }

        /// Table rows: only the cell under an "Owner" header column.
        private func tableCandidates(_ line: String, ns: NSString, ownerCol: inout Int?,
                                     lookup: (String) -> String?) -> [(NSRange, String)] {
            var cells: [(NSRange, String)] = []
            var loc = 0
            for part in line.components(separatedBy: "|") {
                let len = (part as NSString).length
                cells.append((NSRange(location: loc, length: len), part))
                loc += len + 1
            }
            let texts = cells.map { $0.1.trimmingCharacters(in: .whitespaces) }
            if texts.contains(where: { $0.caseInsensitiveCompare("Owner") == .orderedSame }) {
                ownerCol = texts.firstIndex { $0.caseInsensitiveCompare("Owner") == .orderedSame }
                return []
            }
            guard let col = ownerCol, col < cells.count else { return [] }
            let (range, part) = cells[col]
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let new = lookup(trimmed) else { return [] }
            let lead = (part as NSString).range(of: trimmed)
            return [(NSRange(location: range.location + lead.location, length: lead.length), new)]
        }
    }

    // MARK: Apply

    /// Rename speakers for `base`, rewriting the note, the cached transcript and
    /// the segments sidecar, and recording the mapping. `mapping` is current
    /// label -> new name. Missing optional files are skipped; a file that exists
    /// but cannot be read is an error (nothing is changed). All-or-nothing: on any
    /// failure every file is back as it was and the error is thrown.
    ///
    /// A merge (see `merges`) also keeps `<file>.pre-merge-<stamp>` copies of the
    /// transcript and segments, since a merge cannot be undone from the mapping.
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
        let segmentsPath = TranscriptSegments.url(workDir: workDir, base: base)
        let namesPath = SpeakerNames.url(workDir: workDir, base: base)

        func readText(_ url: URL) throws -> String? {
            guard fm.fileExists(atPath: url.path) else { return nil }
            guard let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8) else {
                throw SpeakerRenameError.unreadable(url.lastPathComponent)
            }
            return s
        }
        let note = try readText(notePath)
        let transcript = try readText(transcriptPath)
        var segments: TranscriptSegments?
        if fm.fileExists(atPath: segmentsPath.path) {
            guard let data = try? Data(contentsOf: segmentsPath),
                  let s = try? JSONDecoder().decode(TranscriptSegments.self, from: data) else {
                throw SpeakerRenameError.unreadable(segmentsPath.lastPathComponent)
            }
            segments = s
        }
        guard note != nil || transcript != nil else { throw SpeakerRenameError.nothingToRename(base) }
        let namesState = SpeakerNames.inspect(workDir: workDir, base: base)
        if case .newer(let v) = namesState { throw SpeakerRenameError.newerSidecar(v) }
        if mapping.isEmpty { return SpeakerRenameResult(changedFiles: [], backup: nil) }

        // Compute every new file content first; only differing ones are written.
        struct Job { let url: URL; let data: Data; let isNote: Bool }
        var jobs: [Job] = []
        if let note {
            let new = rewriteNote(note, mapping: mapping)
            if new != note { jobs.append(Job(url: notePath, data: Data(new.utf8), isNote: true)) }
        }
        if let transcript {
            let new = rewriteTranscript(transcript, mapping: mapping)
            if new != transcript { jobs.append(Job(url: transcriptPath, data: Data(new.utf8), isNote: false)) }
        }
        if let segments {
            let new = rewrite(segments, mapping: mapping)
            if new != segments { jobs.append(Job(url: segmentsPath, data: try new.encoded(), isNote: false)) }
        }
        if jobs.isEmpty { return SpeakerRenameResult(changedFiles: [], backup: nil) }

        let present = detectSpeakers(note: note, transcript: transcript, segments: segments).map(\.label)
        var current = SpeakerNames()
        if case .ok(let n) = namesState { current = n }
        jobs.append(Job(url: namesPath,
                        data: try current.composing(mapping, presentLabels: Set(present)).encoded(), isNote: false))

        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let token = UUID().uuidString.prefix(8)
        func sibling(_ url: URL, _ tag: String) -> URL {
            url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(tag)-\(token)")
        }
        let stamp = backupStamp(now)

        // Phase 1: write every new version beside its target (atomically, with the
        // original's permissions and extended attributes), plus the safety copies.
        var temps: [URL] = []
        var copies: [URL] = []
        func cleanUp() { for t in temps + copies { try? fm.removeItem(at: t) } }
        do {
            for job in jobs {
                let tmp = sibling(job.url, "rename-tmp")
                temps.append(tmp)
                try job.data.write(to: tmp, options: .atomic)
                if fm.fileExists(atPath: job.url.path) { copyAttributes(from: job.url, to: tmp) }
            }
            // Information-losing changes keep a copy beside the original, named so
            // scanners and the search index ignore it.
            if !merges(mapping, present: present).isEmpty {
                for url in [transcriptPath, segmentsPath] where jobs.contains(where: { $0.url == url }) {
                    let copy = uniqueSibling(url, tag: "pre-merge-\(stamp)")
                    try fm.copyItem(at: url, to: copy); copies.append(copy)
                }
            }
            if case .corrupt = namesState {
                let copy = uniqueSibling(namesPath, tag: "corrupt-\(stamp)")
                try fm.copyItem(at: namesPath, to: copy); copies.append(copy)
            }
        } catch { cleanUp(); throw error }

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
            cleanUp()
            throw error
        }
        // Committed: drop the set-aside originals of the non-note files (the
        // note's original stays as the kept `.prev-` backup).
        for job in jobs where !job.isNote { try? fm.removeItem(at: sibling(job.url, "rename-orig")) }
        return SpeakerRenameResult(changedFiles: jobs.map { $0.url.lastPathComponent }, backup: backup)
    }

    // MARK: File helpers

    private static func backupStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// `<file>.<tag>`, with `-2`, `-3`… when that name is taken.
    private static func uniqueSibling(_ url: URL, tag: String) -> URL {
        var n = 1
        while true {
            let candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).\(tag)\(n == 1 ? "" : "-\(n)")")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Copy POSIX permissions and extended attributes (Finder tags, quarantine…)
    /// so replacing a file does not drop them. Best effort.
    private static func copyAttributes(from src: URL, to dst: URL) {
        let fm = FileManager.default
        if let perms = (try? fm.attributesOfItem(atPath: src.path))?[.posixPermissions] {
            try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: dst.path)
        }
        #if canImport(Darwin)
        let size = listxattr(src.path, nil, 0, 0)
        guard size > 0 else { return }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(src.path, &names, size, 0) >= 0 else { return }
        var start = 0
        for i in 0..<size where names[i] == 0 {
            let name = names[start..<i].withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            start = i + 1
            let len = getxattr(src.path, name, nil, 0, 0, 0)
            guard len >= 0 else { continue }
            var buf = [UInt8](repeating: 0, count: len)
            if getxattr(src.path, name, &buf, len, 0, 0) >= 0 { _ = setxattr(dst.path, name, buf, len, 0, 0) }
        }
        #endif
    }
}
