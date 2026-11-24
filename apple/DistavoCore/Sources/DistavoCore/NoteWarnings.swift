// NoteWarnings.swift — the warnings the pipeline already knows, at the TOP of the note (D082, D081).
//
// "Recording may end before the call did" sat in a footer line nobody reads. With `notes.warnings_on_top`
// on, one block goes right under the note's title (after any frontmatter):
//
//     > [!warning] Check this note
//     > - The recording may have stopped before the call ended ...
//
// Obsidian renders it as a callout; plain Markdown shows a quote. The footer lines stay as they are.
// Fixed order: truncated recording, words removed by the offensive-word guard, one person under several
// spellings, unsure language detection. No warning = no block and the note byte-identical. Re-inserting
// replaces an existing block, so Regenerate never doubles it. Pure; wired in `Pipeline.composeNote`.
// (Not covered: "no call audio heard" is known only to the recorder in the app, not to the pipeline.)

import Foundation

public enum NoteWarnings {
    public static let header = "> [!warning] Check this note"

    public struct Signals: Equatable, Sendable {
        public var truncated: Bool
        public var wordsRemoved: Int
        /// `NameConsistency.suspectGroups` of the final note.
        public var nameGroups: [[String]]
        /// Language name and percentage when the detector's best guess was below the router floor, e.g. "English 43%".
        public var unsureLanguage: String?

        public init(truncated: Bool = false, wordsRemoved: Int = 0, nameGroups: [[String]] = [],
                    unsureLanguage: String? = nil) {
            self.truncated = truncated; self.wordsRemoved = wordsRemoved
            self.nameGroups = nameGroups; self.unsureLanguage = unsureLanguage
        }
    }

    static let languagePrefix = "Language detection was unsure ("

    /// One plain-words bullet per warning, in the fixed order.
    public static func bullets(_ s: Signals) -> [String] {
        var out: [String] = []
        if s.truncated {
            out.append("The recording may have stopped before the call ended: the last sentence is unfinished, so the end of the meeting may be missing.")
        }
        if s.wordsRemoved > 0 {
            let words = s.wordsRemoved == 1 ? "1 word" : "\(s.wordsRemoved) words"
            out.append("\(words) heard as offensive replaced with \(OffensiveWordGuard.placeholder): check the transcript.")
        }
        if !s.nameGroups.isEmpty {
            let parts = s.nameGroups.prefix(3).map { $0.joined(separator: " / ") }.joined(separator: "; ")
            out.append("One person may appear under several spellings: \(parts).")
        }
        if let lang = s.unsureLanguage {
            out.append("\(languagePrefix)\(lang)): the transcript may be in the wrong language.")
        }
        return out
    }

    /// Display text for an unsure detection from a transcribe result's `detections`, or nil when the best
    /// window reached `EngineRouter.confidenceFloor` (or there were no detections: nothing to judge).
    public static func unsureLanguage(detections: [(code: String, probability: Double)]) -> String? {
        guard let best = detections.max(by: { $0.probability < $1.probability }),
              best.probability < Double(EngineRouter.confidenceFloor) else { return nil }
        let name = WhisperLanguageCatalog.language(forCode: best.code)?.englishName ?? best.code
        return "\(name) \(Int((best.probability * 100).rounded()))%"
    }

    /// `unsureLanguage` over a transcribe result's `detections` list (code + probability per window).
    public static func unsureLanguage(transcribeResult: [String: Any], spokenLanguages: [String] = []) -> String? {
        let allowed = Set(EngineRouter.normalisedSpokenLanguages(spokenLanguages))
        let all: [(code: String, probability: Double)] =
            (transcribeResult["detections"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let code = entry["code"] as? String else { return nil }
                return (code: code, probability: (entry["probability"] as? Double) ?? Double((entry["probability"] as? Float) ?? 0))
            }
        // "Languages I speak": the router ignored the other windows, so judge only the listed ones.
        let pairs = allowed.isEmpty ? all : all.filter { allowed.contains($0.code) }
        return unsureLanguage(detections: pairs)
    }

    /// The unsure-language text of the block already in `note` (Regenerate has no detections of its own).
    public static func carriedUnsureLanguage(in note: String?) -> String? {
        guard let note, let range = blockRange(in: note.components(separatedBy: "\n")) else { return nil }
        let lines = note.components(separatedBy: "\n")
        for line in lines[range] {
            guard let start = line.range(of: languagePrefix),
                  let end = line.range(of: "): the transcript", range: start.upperBound..<line.endIndex) else { continue }
            return String(line[start.upperBound..<end.lowerBound])
        }
        return nil
    }

    /// `note` with exactly one block for `bullets` (none when empty): an existing block is removed first,
    /// the new one goes after the frontmatter and after the first H1 when the body opens with one.
    public static func insert(_ bullets: [String], into note: String) -> String {
        var lines = note.components(separatedBy: "\n")
        if let range = blockRange(in: lines) {
            var upper = range.upperBound
            if upper < lines.count, lines[upper].trimmingCharacters(in: .whitespaces).isEmpty { upper += 1 }
            lines.removeSubrange(range.lowerBound..<upper)
        }
        guard !bullets.isEmpty else { return lines.joined(separator: "\n") }

        var at = 0
        // Frontmatter: "---" first line, up to the closing "---".
        if lines.first == "---", let close = lines.indices.dropFirst().first(where: { lines[$0] == "---" }) {
            at = close + 1
        }
        // Then the title, when the body opens with one (blank lines allowed before it).
        var probe = at
        while probe < lines.count, lines[probe].trimmingCharacters(in: .whitespaces).isEmpty { probe += 1 }
        if probe < lines.count, lines[probe].hasPrefix("# ") {
            at = probe + 1
            // Keep the blank line that follows the title before the block.
            if at < lines.count, lines[at].trimmingCharacters(in: .whitespaces).isEmpty { at += 1 }
            let block = [header] + bullets.map { "> - \($0)" } + [""]
            lines.insert(contentsOf: block, at: at)
            if at > 0, !lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                lines.insert("", at: at)
            }
        } else {
            lines.insert(contentsOf: [header] + bullets.map { "> - \($0)" } + [""], at: at)
        }
        return lines.joined(separator: "\n")
    }

    /// The header line and its "> " continuation lines.
    static func blockRange(in lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(of: header) else { return nil }
        var end = start + 1
        while end < lines.count, lines[end].hasPrefix(">") { end += 1 }
        return start..<end
    }
}
