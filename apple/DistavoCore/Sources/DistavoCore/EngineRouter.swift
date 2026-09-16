import Foundation

/// One language-identification result from one audio window.
public struct LanguageDetection: Equatable, Sendable {
    public let code: String
    public let probability: Float
    public init(code: String, probability: Float) { self.code = code; self.probability = probability }
}

/// What the app should run: which catalog model, and the language to tell it
/// (a real code or nil — never "auto"). `note` explains a fallback to the user.
public struct RoutingDecision: Equatable, Sendable {
    public let model: EmbeddedModel
    public let languageHint: String?
    public let note: String?
}

/// Spec §5.2. Pure: no I/O, no SDK types. The app layer feeds it detections
/// from the whisper-tiny detector and dispatches on `model.engine`.
public enum EngineRouter {
    public static let confidenceFloor: Float = 0.5

    public static func needsDetection(_ config: TranscribeConfig) -> Bool {
        EmbeddedModelCatalog.isAutomatic(config.embeddedModel)
            && EmbeddedModelCatalog.isAutomatic(config.language)
    }

    public static func choose(detections: [LanguageDetection], config: TranscribeConfig,
                              memoryBytes: UInt64) -> RoutingDecision {
        let fixedLanguage = EmbeddedModelCatalog.isAutomatic(config.language) ? nil
            : (config.language.isEmpty ? nil : config.language)
        let confident = fixedLanguage.map { [$0] }
            ?? detections.filter { $0.probability >= confidenceFloor }.map(\.code)
        let set = Set(confident)
        let dominant = fixedLanguage ?? dominantCode(detections)

        // Rule 1: an explicit model is always honoured.
        if !EmbeddedModelCatalog.isAutomatic(config.embeddedModel) {
            return RoutingDecision(model: EmbeddedModelCatalog.model(id: config.embeddedModel),
                                   languageHint: dominant, note: nil)
        }

        let fallback = EmbeddedModelCatalog.recommended(memoryBytes: memoryBytes)
        let catalan = set.intersection(EmbeddedModelCatalog.catalanFamily)

        var chosen: EmbeddedModel
        var hint: String? = dominant
        if !catalan.isEmpty {
            // Rules 3–4: any confident Catalan/Galician/Basque → a BSC model, never Parakeet.
            let onlyCatalan = set == ["ca"]
            chosen = EmbeddedModelCatalog.model(id: onlyCatalan
                ? config.effectivePreferredCatalanModel : "bsc-los")
            hint = catalan.contains("ca") ? "ca" : (catalan.contains("gl") ? "gl" : "eu")
        } else if set == ["es"] {
            chosen = EmbeddedModelCatalog.model(id: "bsc-los")          // rule 5a
            hint = "es"
        } else if let (code, packModel) = packHit(confident, config: config) {
            // Rule 5p (Vikunja #2124): any confident language covered by an
            // ENABLED language pack goes to that pack — like Catalan, never to
            // Parakeet, which would silently drop the pack language's speech.
            // The hint is the covered code, not the dominant one, so a Hebrew
            // meeting with English asides is transcribed as Hebrew.
            chosen = packModel
            hint = code
        } else if !set.isEmpty, set.isSubset(of: EmbeddedModelCatalog.parakeetLanguages) {
            chosen = EmbeddedModelCatalog.model(id: "parakeet-tdt-v3")  // rule 5b
        } else {
            chosen = fallback                                           // rule 6
            hint = set.isEmpty ? nil : dominant
        }

        // Rule 7: memory gate.
        let gb = Int(memoryBytes / (1024 * 1024 * 1024))
        if chosen.minimumMemoryGB > gb {
            return RoutingDecision(
                model: fallback, languageHint: hint,
                note: "\(chosen.displayName) needs \(chosen.minimumMemoryGB) GB of memory; using \(fallback.displayName) on this Mac.")
        }
        return RoutingDecision(model: chosen, languageHint: hint, note: nil)
    }

    /// The first confident code (in detection order) that an enabled pack
    /// covers, with that pack's model. Explicit language (`fixedLanguage`)
    /// arrives here as the single confident code, so a user who picks
    /// "Hebrew" with an enabled Hebrew pack gets the pack too.
    static func packHit(_ confident: [String], config: TranscribeConfig) -> (String, EmbeddedModel)? {
        guard !config.languagePacks.isEmpty else { return nil }
        for code in confident {
            if let model = EmbeddedModelCatalog.packModel(for: code, enabled: config.languagePacks) {
                return (code, model)
            }
        }
        return nil
    }

    /// The code with the highest summed probability, or nil when nothing was detected.
    static func dominantCode(_ detections: [LanguageDetection]) -> String? {
        var score: [String: Float] = [:]
        for d in detections { score[d.code, default: 0] += d.probability }
        return score.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key
    }
}
