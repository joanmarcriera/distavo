import Foundation

/// One language-identification result from one audio window.
public struct LanguageDetection: Equatable, Sendable {
    public let code: String
    public let probability: Float
    public init(code: String, probability: Float) { self.code = code; self.probability = probability }
}

/// Where the language hint came from (Vikunja #2667).
public enum LanguageSource: Equatable, Sendable {
    case fixed          // the user set a language in Settings
    case detected       // the whisper-tiny detector found it above the confidence floor
    case modelDetects   // no hint: the transcribing model must detect it itself
}

/// What the app should run: which catalog model, and the language to tell it
/// (a real code or nil — never "auto"). `note` explains a fallback to the user.
public struct RoutingDecision: Equatable, Sendable {
    public let model: EmbeddedModel
    public let languageHint: String?
    public let note: String?
    /// True when the model was chosen explicitly in Settings (not by the router).
    public let pinned: Bool
    public let languageSource: LanguageSource
    /// Highest window probability of `languageHint`; nil unless `.detected`.
    public let confidence: Float?
    /// A user-facing suggestion, set only for a pinned model (see `EngineRouter.recommendation`).
    public let recommendation: String?

    public init(model: EmbeddedModel, languageHint: String?, note: String?,
                pinned: Bool = false, languageSource: LanguageSource = .modelDetects,
                confidence: Float? = nil, recommendation: String? = nil) {
        self.model = model; self.languageHint = languageHint; self.note = note
        self.pinned = pinned; self.languageSource = languageSource
        self.confidence = confidence; self.recommendation = recommendation
    }

    /// One activity-log line. Keeps the "Using " prefix — WatcherController's
    /// icon logic looks for it.
    public var logLine: String {
        let language: String
        switch languageSource {
        case .fixed: language = "\(languageHint ?? "?") (set in Settings)"
        case .detected:
            let pct = confidence.map { ", \(Int(($0 * 100).rounded()))% confidence" } ?? ""
            language = "\(languageHint ?? "?") (detected\(pct))"
        case .modelDetects: language = "not detected; the model detects it itself"
        }
        return "Using \(model.id) (\(pinned ? "pinned" : "automatic")) \u{2014} language \(language)"
    }
}

/// How to drive WhisperKit's language options for a router hint. Invariant:
/// `language != nil || detectLanguage` — with both off, WhisperKit's prefill
/// silently falls back to "en" and translates the audio (Vikunja #2667).
public struct WhisperLanguagePlan: Equatable, Sendable {
    public let language: String?
    public let detectLanguage: Bool
    public init(language: String?, detectLanguage: Bool) {
        self.language = language; self.detectLanguage = detectLanguage
    }
}

/// Spec §5.2. Pure: no I/O, no SDK types. The app layer feeds it detections
/// from the whisper-tiny detector and dispatches on `model.engine`.
public enum EngineRouter {
    public static let confidenceFloor: Float = 0.5

    /// Detection is needed whenever the language is automatic — also with a
    /// pinned model, whose language would otherwise fall to WhisperKit's "en"
    /// prefill default. A fixed language still skips it.
    public static func needsDetection(_ config: TranscribeConfig) -> Bool {
        EmbeddedModelCatalog.isAutomatic(config.language)
    }

    /// Whether a detector outage should defer the recording. With a pinned
    /// model the detector is advisory only, so its failure must not defer.
    public static func deferOnDetectorOutage(_ c: TranscribeConfig) -> Bool {
        EmbeddedModelCatalog.isAutomatic(c.embeddedModel)
    }

    /// nil, "" and "auto" → let the model detect; a real code → fix it.
    public static func whisperLanguagePlan(hint: String?) -> WhisperLanguagePlan {
        guard let hint, !hint.isEmpty, !EmbeddedModelCatalog.isAutomatic(hint) else {
            return WhisperLanguagePlan(language: nil, detectLanguage: true)
        }
        return WhisperLanguagePlan(language: hint, detectLanguage: false)
    }

    /// Advice for a PINNED model (nil otherwise): (a) Catalan/Galician/Basque
    /// on a non-BSC model → use the BSC model; (b) a language the pinned model
    /// does not cover → Automatic. The pinned model still runs either way.
    static func recommendation(model: EmbeddedModel, confident hint: String?) -> String? {
        guard let hint else { return nil }
        let name = WhisperLanguageCatalog.language(forCode: hint)?.englishName ?? hint
        if EmbeddedModelCatalog.catalanFamily.contains(hint) {
            return model.id.hasPrefix("bsc-") ? nil
                : "\(name) detected \u{2014} the BSC model is recommended."
        }
        if !model.languages.covers(hint) {
            return "\(name) detected \u{2014} \(model.displayName) does not cover it; Automatic is recommended."
        }
        return nil
    }

    public static func choose(detections: [LanguageDetection], config: TranscribeConfig,
                              memoryBytes: UInt64) -> RoutingDecision {
        let fixedLanguage = EmbeddedModelCatalog.isAutomatic(config.language) ? nil
            : (config.language.isEmpty ? nil : config.language)
        let confident = fixedLanguage.map { [$0] }
            ?? detections.filter { $0.probability >= confidenceFloor }.map(\.code)
        let set = Set(confident)
        let dominant = fixedLanguage ?? dominantCode(detections)
        let pinned = !EmbeddedModelCatalog.isAutomatic(config.embeddedModel)

        let fallback = EmbeddedModelCatalog.recommended(memoryBytes: memoryBytes)
        let catalan = set.intersection(EmbeddedModelCatalog.catalanFamily)

        // The hint follows the automatic rules whether or not the model is
        // pinned (a pinned model keeps itself but gets the same hint).
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

        // Where the hint came from, and how sure the detector was.
        let source: LanguageSource = fixedLanguage != nil ? .fixed
            : (hint == nil ? .modelDetects : .detected)
        let confidence: Float? = source == .detected
            ? detections.filter { $0.code == hint }.map(\.probability).max() : nil

        // Rule 1: an explicit model is always honoured (no memory gate), but
        // it now gets the detected hint plus a recommendation when another
        // choice would serve the audio better.
        if pinned {
            let model = EmbeddedModelCatalog.model(id: config.embeddedModel)
            return RoutingDecision(
                model: model, languageHint: hint, note: nil, pinned: true,
                languageSource: source, confidence: confidence,
                recommendation: source == .detected ? recommendation(model: model, confident: hint) : nil)
        }

        // Rule 7: memory gate.
        let gb = Int(memoryBytes / (1024 * 1024 * 1024))
        if chosen.minimumMemoryGB > gb {
            return RoutingDecision(
                model: fallback, languageHint: hint,
                note: "\(chosen.displayName) needs \(chosen.minimumMemoryGB) GB of memory; using \(fallback.displayName) on this Mac.",
                languageSource: source, confidence: confidence)
        }
        return RoutingDecision(model: chosen, languageHint: hint, note: nil,
                               languageSource: source, confidence: confidence)
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
