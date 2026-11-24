import Foundation

/// A per-user glossary of names and terms (drive 2026-11-23): one person who speech-to-text spells five ways
/// ("Jordan Ellis", "Jordon", "Jordan Elis") becomes one name in the note.
///
/// A plain text file, `names.txt`, in the Distavo support folder (next to `watcher-config.json`). One entry per line:
///
///     # comment
///     Jordan Ellis: Jordon, Jordan Elis; Jordan L     <- canonical name, then the spellings to merge into it
///     Acme Cooling                                    <- a term or name with no aliases (only fed to the prompt)
///
/// What it does, and only when `summarise.name_check` is on:
///  - every canonical name reaches the summary prompt as a glossary term (the `glossary` channel all summarisers use);
///  - after the summary, each alias is replaced by its canonical name, whole word, exact capitalisation (an alias that is
///    also an ordinary word, like "Mark", only matches when capitalised), in the note body.
///    Highlights (the owner's typed Quick Notes) and the facts ledger (verbatim quotes) are never rewritten;
///  - the footer says how many were merged. No file = nothing changes.
public struct NameGlossary: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var canonical: String
        public var aliases: [String]
    }

    public static let fileName = "names.txt"
    /// `~/Library/Application Support/Distavo`, beside `watcher-config.json`.
    public static var defaultSupportDir: URL {
        Config.homeDir.appendingPathComponent("Library/Application Support/Distavo")
    }
    public var entries: [Entry]
    public init(entries: [Entry] = []) { self.entries = entries }

    /// Canonical names in file order: what the prompt glossary receives.
    public var terms: [String] { entries.map(\.canonical) }

    public static func parse(_ text: String) -> NameGlossary {
        var out: [Entry] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let canonical = parts[0].trimmingCharacters(in: .whitespaces)
            guard !canonical.isEmpty else { continue }
            var aliases: [String] = []
            if parts.count > 1 {
                for a in parts[1].components(separatedBy: CharacterSet(charactersIn: ",;")) {
                    let alias = a.trimmingCharacters(in: .whitespaces)
                    if !alias.isEmpty, alias.lowercased() != canonical.lowercased(), !aliases.contains(alias) { aliases.append(alias) }
                }
            }
            out.append(Entry(canonical: canonical, aliases: aliases))
        }
        return NameGlossary(entries: out)
    }

    /// Reads `<supportDir>/names.txt`; a missing or unreadable file is an empty glossary.
    public static func load(supportDir: URL) -> NameGlossary {
        guard let text = try? String(contentsOf: supportDir.appendingPathComponent(fileName), encoding: .utf8) else { return NameGlossary() }
        return parse(text)
    }

    public struct Result: Equatable, Sendable { public var text: String; public var merged: Int }

    /// Replaces each alias with its canonical name outside Highlights, Speakers, the facts ledger, the corrections list and quote lines.
    public func apply(to note: String) -> Result {
        let pairs = entries.flatMap { e in e.aliases.map { (alias: $0, canonical: e.canonical) } }
            .sorted { $0.alias.count > $1.alias.count }
        guard !pairs.isEmpty else { return Result(text: note, merged: 0) }
        var protected = false
        var merged = 0
        var lines: [String] = []
        for line in note.components(separatedBy: "\n") {
            if TranscriptionCorrections.isHeading(line) {
                let title = line.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "#" })
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t*_:#")).lowercased()
                protected = TranscriptionCorrections.isLedgerHeading(line) || title.contains("highlight")
                    || title == "speakers" || title == "possible transcription corrections"
                lines.append(line); continue
            }
            if protected || line.trimmingCharacters(in: .whitespaces).hasPrefix(">") { lines.append(line); continue }
            var text = line
            for p in pairs {
                let r = Self.replace(p.alias, with: p.canonical, in: text, allCanonicals: terms)
                text = r.text; merged += r.count
            }
            lines.append(text)
        }
        return Result(text: lines.joined(separator: "\n"), merged: merged)
    }

    /// Whole-word, case-insensitive; an occurrence inside the canonical name itself ("Jordan" in "Jordan Ellis") stays.
    private static func replace(_ alias: String, with canonical: String, in text: String, allCanonicals: [String]) -> (text: String, count: Int) {
        let edge = "(?<![\\p{L}\\p{N}])", tail = "(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: edge + NSRegularExpression.escapedPattern(for: alias) + tail, options: []),
              !allCanonicals.isEmpty,
              let canonRe = try? NSRegularExpression(pattern: edge + "(?:" + allCanonicals.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")" + tail, options: [])
        else { return (text, 0) }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let canonRanges = canonRe.matches(in: text, range: full).map(\.range)
        let hits = re.matches(in: text, range: full).map(\.range).filter { h in
            !canonRanges.contains { NSIntersectionRange($0, h).length > 0 }
        }
        guard !hits.isEmpty else { return (text, 0) }
        var out = text as NSString
        for h in hits.reversed() { out = out.replacingCharacters(in: h, with: canonical) as NSString }
        return (out as String, hits.count)
    }

    /// Footer sentence, or nil when nothing was merged.
    public static func note(merged: Int) -> String? {
        merged > 0 ? "Names glossary: \(merged) spelling\(merged == 1 ? "" : "s") merged into the names in your glossary (names.txt)" : nil
    }
}
