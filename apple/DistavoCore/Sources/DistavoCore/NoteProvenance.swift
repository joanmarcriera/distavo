import Foundation

/// Builds the footer Pipeline appends to a note when the transcribe result
/// carries engine/detection metadata (spec: "which engine transcribed this
/// meeting, what language did it detect"). Pure and dependency-free so it is
/// unit-tested directly, without going through the pipeline.
public enum NoteProvenance {

    /// - Parameters:
    ///   - engine: a human label for the engine that transcribed the meeting
    ///     (e.g. "Languages of Spain (BSC)").
    ///   - detections: raw per-window detections (the detector runs on up to
    ///     three windows, so the same code can repeat). Deduplicated here —
    ///     kept at its highest probability, ordered by that probability
    ///     descending (ties broken by code) — before display. Empty omits
    ///     the "Detected language" sentence entirely.
    /// - Returns: a footer block (leading blank line + `---` + one italic
    ///   line) ready to append verbatim to the note text.
    ///   - languageUsed: the language the transcriber was actually told (Vikunja
    ///     #2667), e.g. "Catalan (detected, 92% confidence)"; nil omits it.
    ///   - recommendation: advice for a pinned model; nil omits it.
    ///   - notes: transcriber remarks (the result's `footer_notes`), each a sentence; empty omits them.
    public static func footer(engine: String, detections: [(code: String, probability: Double)],
                              languageUsed: String? = nil, recommendation: String? = nil,
                              notes: [String] = []) -> String {
        var line = "_Transcribed on this Mac with \(engine)."
        // When the language used IS the detected one ("Catalan (detected, 92% confidence)"), saying both
        // repeats itself (#2675): one sentence, "Detected language: Catalan 92% (used)."
        let usedIsDetected = languageUsed?.contains("(detected") == true
        if let summary = detectedLanguages(detections) {
            line += " Detected language: \(summary)\(usedIsDetected ? " (used for transcription)" : "")."
        }
        if let languageUsed, !(usedIsDetected && detectedLanguages(detections) != nil) {
            line += " Language used: \(languageUsed)."
        }
        if let recommendation { line += " \(recommendation)" }
        // Transcriber remarks (1.19), e.g. "Recovered 52 s of speech the first pass missed."
        for note in notes where !note.isEmpty { line += " \(note)" }
        line += "_"
        return "\n\n---\n\(line)"
    }

    /// "Catalan 92%, English 71%" - one entry per language, ordered by its highest probability (ties by
    /// code); nil when there are no detections. Shared by the note footer and the menu's activity line
    /// (Vikunja #2161) so both read the same.
    ///
    /// The detector samples up to three 30 s windows, each giving its own top language, so the numbers are
    /// confidences of separate samples, NOT shares of the meeting (Vikunja #3586). When a language was seen
    /// in several windows or only with low confidence (< 50 %) the line says so:
    /// "3 samples: Catalan x2 (87%, 97%), English 23% (low confidence)". With one reading per language, all
    /// confident, it stays "Catalan 92%, English 71%".
    public static func detectedLanguages(_ detections: [(code: String, probability: Double)]) -> String? {
        guard !detections.isEmpty else { return nil }
        var all: [String: [Double]] = [:]
        for detection in detections { all[detection.code, default: []].append(detection.probability) }
        let ordered = all.sorted { a, b in
            let (ma, mb) = (a.value.max() ?? 0, b.value.max() ?? 0)
            return ma == mb ? a.key < b.key : ma > mb
        }
        let needsDetail = ordered.contains { $0.value.count > 1 || ($0.value.max() ?? 0) < lowConfidence }
        let entries = ordered.map { code, probabilities -> String in
            let name = WhisperLanguageCatalog.language(forCode: code)?.englishName ?? code
            let percents = probabilities.sorted().map { "\(Int(($0 * 100).rounded()))%" }
            let low = (probabilities.max() ?? 0) < lowConfidence
            if probabilities.count > 1 {
                return "\(name) \u{00D7}\(probabilities.count) (\(percents.joined(separator: ", "))\(low ? ", low confidence" : ""))"
            }
            return "\(name) \(percents[0])" + (low ? " (low confidence)" : "")
        }.joined(separator: ", ")
        return needsDetail ? "\(detections.count) sample\(detections.count == 1 ? "" : "s"): " + entries : entries
    }

    /// Below this a window's top language is only a weak guess.
    static let lowConfidence = 0.5

    /// Human wording for the language the router handed the transcriber.
    public static func languageUsed(_ d: RoutingDecision) -> String {
        let name = d.languageHint.map { WhisperLanguageCatalog.language(forCode: $0)?.englishName ?? $0 } ?? ""
        switch d.languageSource {
        case .fixed: return "\(name) (set in Settings)"
        case .detected:
            let pct = d.confidence.map { ", \(Int(($0 * 100).rounded()))% confidence" } ?? ""
            return "\(name) (detected\(pct))"
        case .modelDetects: return "detected by the model"
        }
    }
}
