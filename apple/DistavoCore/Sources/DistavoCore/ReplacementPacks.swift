import Foundation

// Built-in, opt-in replacement packs (Vikunja #3584).
//
// `transcribe.replacements` is the user's own find/replace list. A pack is a ready-made list for a
// field where the speech-to-text models keep misspelling the same words, switched on with
// `transcribe.replacement_packs` (empty by default: nothing changes until the user opts in). The
// user's own rules are applied first, the packs after, so a user rule always wins.
//
// Rules match case-insensitively as whole words (`CompiledReplacements`). Only unambiguous
// misreadings are listed: a pack must not rewrite a real word ("Haiti" -> "IT" would corrupt
// every mention of the country, so it is not in the list).
public struct ReplacementPack: Equatable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let rules: [ReplacementRule]
}

public enum ReplacementPacks {
    public static let catalanIT = ReplacementPack(
        id: "ca_it", name: "Catalan IT",
        summary: "Corrects IT terms the Catalan models keep mishearing (ERP, SonicWall, WatchGuard, Entra ID, backups, firewall...).",
        rules: [
            // Seen on the 2026-10-16 Catalan consultancy field test (BSC model, ~50 min).
            ReplacementRule(from: "l'rp", to: "l'ERP"),
            ReplacementRule(from: "l'rpa", to: "l'ERP"),
            ReplacementRule(from: "er p", to: "ERP"),
            ReplacementRule(from: "r&p", to: "ERP"),
            ReplacementRule(from: "sonic world", to: "SonicWall"),
            ReplacementRule(from: "sonic wall", to: "SonicWall"),
            ReplacementRule(from: "sonicwal", to: "SonicWall"),
            ReplacementRule(from: "watch guard", to: "WatchGuard"),
            ReplacementRule(from: "watchgard", to: "WatchGuard"),
            ReplacementRule(from: "entre id", to: "Entra ID"),
            ReplacementRule(from: "entra-id", to: "Entra ID"),
            ReplacementRule(from: "i v p f", to: "eBPF"),
            ReplacementRule(from: "becup", to: "backup"),
            ReplacementRule(from: "becups", to: "backups"),
            ReplacementRule(from: "fèrgol", to: "firewall"),
            ReplacementRule(from: "business centre", to: "Business Central"),
            ReplacementRule(from: "business center", to: "Business Central"),
        ])

    public static let all: [ReplacementPack] = [catalanIT]

    public static func pack(id: String) -> ReplacementPack? { all.first { $0.id == id } }

    /// Rules of the named packs, in catalog order; unknown ids are ignored (a hand-edited or
    /// future id never breaks a run).
    public static func rules(for ids: [String]) -> [ReplacementRule] {
        all.filter { ids.contains($0.id) }.flatMap(\.rules)
    }
}
