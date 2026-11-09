import Foundation

// RoleTermPacks.swift — spelling terms seeded from a role named in the participants line
// (Vikunja #3950). "Sam (accountant for ...)" means the call will say VAT, PAYE, IR35, FreeAgent;
// the models otherwise write "bat registration" and "POYE". The terms ride the per-meeting glossary,
// which the prompt already frames as a spelling aid and never as facts, so a term that is not in the
// transcript never reaches the note. Role terms are kept out of the fuzzy vocabulary post-pass (Pipeline), so
// a word is only ever suggested to the transcriber, never rewritten.

public struct RoleTermPack: Equatable, Sendable {
    public let id: String
    /// Whole lowercase words in the participants line that select this pack.
    public let triggers: [String]
    public let terms: [String]
}

public enum RoleTermPacks {
    public static let maxTerms = 12

    public static let all: [RoleTermPack] = [
        RoleTermPack(
            id: "uk_tax", triggers: ["accountant", "accountants", "bookkeeper", "bookkeepers"],
            terms: ["HMRC", "VAT", "PAYE", "IR35", "SDS", "FreeAgent", "Qdos", "SIPP", "self-assessment",
                    "Companies House", "corporation tax"]),
    ]

    /// True when `text` is just a role trigger word ("accountant"), which is never a name worth seeding.
    public static func isRoleWord(_ text: String, packs: [RoleTermPack] = all) -> Bool {
        let w = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return packs.contains { $0.triggers.contains(w) }
    }

    /// Terms of every pack whose trigger appears as a whole word in `text`, deduplicated, capped.
    /// Common-word brand names (Tide, Starling, Mettle) are deliberately not listed: a summariser would bend
    /// "tied"/"starting" toward them.
    public static func terms(forParticipants text: String?, packs: [RoleTermPack] = all) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        let words = Set(text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
        let picked = packs.filter { pack in pack.triggers.contains { words.contains($0) } }
        return Array(Vocabulary.normalisedTerms(picked.flatMap(\.terms)).prefix(maxTerms))
    }
}

extension SpeakerHints {
    /// Field-specific spelling terms implied by the roles in the participants line.
    public var roleTerms: [String] { RoleTermPacks.terms(forParticipants: participants) }
}
