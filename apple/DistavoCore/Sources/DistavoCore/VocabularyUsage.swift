import Foundation

// "Last used" per vocabulary term (Vikunja #3584). After each transcript the pipeline notes which of
// the user's global terms actually occur in it, so Settings can show how stale a term is and offer to
// drop the ones that have not been heard for a while (a stale glossary fed the summariser invented
// facts in the 2026-10-16 field test). One small JSON map in the work folder: lowercased term -> date.

public enum VocabularyUsage {
    static let fileName = "vocabulary.lastused.json"

    public static func url(workDir: URL) -> URL { workDir.appendingPathComponent(fileName) }

    /// term (lowercased) -> last time it appeared in a transcript.
    public static func load(workDir: URL) -> [String: Date] {
        guard let data = try? Data(contentsOf: url(workDir: workDir)) else { return [:] }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (try? d.decode([String: Date].self, from: data)) ?? [:]
    }

    /// The terms of `terms` that occur in `transcript` as whole words, ignoring case.
    public static func terms(_ terms: [String], in transcript: String) -> [String] {
        Vocabulary.normalisedTerms(terms).filter { term in
            var from = transcript.startIndex
            while let r = transcript.range(of: term, options: [.caseInsensitive, .diacriticInsensitive],
                                           range: from..<transcript.endIndex) {
                let before = r.lowerBound > transcript.startIndex ? transcript[transcript.index(before: r.lowerBound)] : " "
                let after = r.upperBound < transcript.endIndex ? transcript[r.upperBound] : " "
                if !(before.isLetter || before.isNumber), !(after.isLetter || after.isNumber) { return true }
                from = r.upperBound
            }
            return false
        }
    }

    /// Stamp every term of `terms` found in `transcript` with `now`. Best-effort: never throws.
    public static func record(terms: [String], transcript: String, workDir: URL, now: Date = Date()) {
        let found = Self.terms(terms, in: transcript)
        guard !found.isEmpty else { return }
        var map = load(workDir: workDir)
        for t in found { map[t.lowercased()] = now }
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try? e.encode(map).write(to: url(workDir: workDir), options: .atomic)
    }

    /// Terms never seen, or last seen before `now - days`. Never-seen terms count as stale only when
    /// `includeNever` (a term added today has not had a chance yet).
    public static func stale(_ terms: [String], usage: [String: Date], olderThanDays days: Int,
                             now: Date = Date(), includeNever: Bool = false) -> [String] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return Vocabulary.normalisedTerms(terms).filter { t in
            guard let seen = usage[t.lowercased()] else { return includeNever }
            return seen < cutoff
        }
    }
}
