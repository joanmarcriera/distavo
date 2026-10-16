import Foundation

// Automatic offer to clear stale vocabulary terms when the meeting context changes (Vikunja #3584).
//
// A glossary written for one set of people or one language keeps steering later meetings (the
// 2026-10-16 field test fed stale terms to the summariser). After each transcript the pipeline
// compares this meeting's language and participant first names with the previous meeting's. When the
// language differs, or both meetings list people and share none, the global terms that did NOT occur
// in this transcript are written to a pending offer. Settings shows it as "Clear N terms / Keep";
// nothing is ever removed without the user's click. All state is two small JSON files in the work
// folder; everything here is best-effort and never throws.

public enum VocabularyClearOffer {
    public enum Reason: String, Codable, Equatable { case language, participants }

    /// What the previous meeting looked like.
    struct Context: Codable, Equatable {
        var language: String
        var names: [String]
    }

    /// The offer Settings shows.
    public struct Offer: Codable, Equatable {
        public var reason: Reason
        /// Global terms not heard in the meeting that triggered the offer.
        public var terms: [String]
        public var created: Date
    }

    static let contextFile = "vocabulary.context.json"
    static let offerFile = "vocabulary.clearoffer.json"

    private static func url(_ name: String, _ workDir: URL) -> URL { workDir.appendingPathComponent(name) }

    /// Why `now` differs from `previous`, or nil. Language differs only when both are known; people
    /// differ only when both meetings list someone and share no first name.
    static func change(from previous: Context, to now: Context) -> Reason? {
        if !previous.language.isEmpty, !now.language.isEmpty, previous.language != now.language { return .language }
        let a = Set(previous.names), b = Set(now.names)
        if !a.isEmpty, !b.isEmpty, a.isDisjoint(with: b) { return .participants }
        return nil
    }

    /// Record this meeting and, when it differs from the previous one, queue an offer to clear the
    /// global `terms` not heard in `transcript`. Returns the new offer, if one was queued.
    @discardableResult
    public static func observe(language: String?, participants: String?, terms: [String], transcript: String,
                               workDir: URL, now: Date = Date()) -> Offer? {
        let current = Context(language: (language ?? "").lowercased(),
                              names: SpeakerHints.listedNames(participants).sorted())
        let previous = load(Context.self, contextFile, workDir)
        // Keep the last known value when this meeting did not say (no detection, no participants), so
        // a gap does not look like a change next time.
        var stored = current
        if let previous {
            if stored.language.isEmpty { stored.language = previous.language }
            if stored.names.isEmpty { stored.names = previous.names }
        }
        save(stored, contextFile, workDir)
        guard let previous, let reason = change(from: previous, to: current) else { return nil }
        let heard = Set(VocabularyUsage.terms(terms, in: transcript).map { $0.lowercased() })
        let unheard = Vocabulary.normalisedTerms(terms).filter { !heard.contains($0.lowercased()) }
        guard !unheard.isEmpty else { return nil }
        let offer = Offer(reason: reason, terms: unheard, created: now)
        save(offer, offerFile, workDir)
        return offer
    }

    /// The pending offer, narrowed to terms that are still in `current` vocabulary; nil when none.
    public static func pending(workDir: URL, currentTerms: [String]) -> Offer? {
        guard var offer = load(Offer.self, offerFile, workDir) else { return nil }
        let have = Set(Vocabulary.normalisedTerms(currentTerms).map { $0.lowercased() })
        offer.terms = offer.terms.filter { have.contains($0.lowercased()) }
        return offer.terms.isEmpty ? nil : offer
    }

    /// Drop the pending offer (the user cleared the terms or chose Keep).
    public static func dismiss(workDir: URL) {
        try? FileManager.default.removeItem(at: url(offerFile, workDir))
    }

    /// `vocabulary` without the offer's terms (case-insensitive).
    public static func applying(_ offer: Offer, to vocabulary: [String]) -> [String] {
        let drop = Set(offer.terms.map { $0.lowercased() })
        return Vocabulary.normalisedTerms(vocabulary).filter { !drop.contains($0.lowercased()) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ name: String, _ workDir: URL) -> T? {
        guard let data = try? Data(contentsOf: url(name, workDir)) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, _ name: String, _ workDir: URL) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try? e.encode(value).write(to: url(name, workDir), options: .atomic)
    }
}
