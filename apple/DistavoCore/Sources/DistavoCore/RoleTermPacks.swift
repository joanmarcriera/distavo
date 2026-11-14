import Foundation

// RoleTermPacks.swift — spelling terms seeded from a role named in the participants line
// (Vikunja #3950). "Sam (accountant for ...)" means the call will say VAT, PAYE, IR35, FreeAgent;
// the models otherwise write "bat registration" and "POYE". The terms ride the per-meeting glossary,
// which the prompt already frames as a spelling aid and never as facts, so a term that is not in the
// transcript never reaches the note. Role terms are kept out of the fuzzy vocabulary post-pass (Pipeline), so
// a word is only ever suggested to the transcriber, never rewritten.
//
// The packs are English (UK tax and finance). A vocabulary prompt in the wrong language is what collapses the
// Barcelona Supercomputing Center Catalan chunks (#3579), so they apply only when the meeting is English or its
// language is not pinned (`RoleTermPacks.appliesTo`; drive review C, 2026-11-09).
// Known residual: with the language on Automatic and no per-recording override, the spoken language is unknown before
// transcription, so a Catalan meeting with an accountant still gets the pack (the #3579 risk stays on that path).

public struct RoleTermPack: Equatable, Sendable {
    public let id: String
    /// Whole lowercase words in the participants line that select this pack.
    public let triggers: [String]
    public let terms: [String]
}

public enum RoleTermPacks {
    public static let maxTerms = 12

    /// True when the English role packs may be added for this recording.
    /// - `override`: the per-recording `LanguageOverride`; its SPOKEN `code` (when set) is the owner's own answer
    ///   and decides alone: English -> yes, anything else -> no. A note-only override says nothing about speech.
    /// - `configured`: `transcribe.language`. "auto" or empty (not pinned) keeps the packs; "en" / "en-GB" keep
    ///   them; any other code ("ca", "es", ...) drops them.
    public static func appliesTo(configuredLanguage configured: String, override: LanguageOverride? = nil) -> Bool {
        // The language the transcriber will run with: the override counts only when the configured language is
        // Automatic, exactly as `LanguageOverride.applying` does (review of 40538ca).
        let c = configured.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let automatic = c.isEmpty || EmbeddedModelCatalog.isAutomatic(c)
        if automatic, let code = override?.code, !code.isEmpty { return isEnglish(code) }
        return automatic || isEnglish(c)
    }

    private static func isEnglish(_ code: String) -> Bool {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return c == "en" || c.hasPrefix("en-") || c.hasPrefix("en_")
    }

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

    /// `roleTerms` when the meeting's language allows the English packs (`RoleTermPacks.appliesTo`), else none.
    public func roleTerms(configuredLanguage: String, override: LanguageOverride?) -> [String] {
        RoleTermPacks.appliesTo(configuredLanguage: configuredLanguage, override: override) ? roleTerms : []
    }
}
