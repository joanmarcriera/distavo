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
    public static func footer(engine: String, detections: [(code: String, probability: Double)]) -> String {
        var line = "_Transcribed on this Mac with \(engine)."
        if let summary = detectedLanguages(detections) {
            line += " Detected language: \(summary)."
        }
        line += "_"
        return "\n\n---\n\(line)"
    }

    /// "Catalan 92%, English 71%" — one entry per language at its highest
    /// probability, ordered by probability (ties by code); nil when there are
    /// no detections. Shared by the note footer and the menu's activity line
    /// (Vikunja #2161) so both read the same.
    public static func detectedLanguages(_ detections: [(code: String, probability: Double)]) -> String? {
        guard !detections.isEmpty else { return nil }
        var best: [String: Double] = [:]
        for detection in detections {
            best[detection.code] = max(best[detection.code] ?? -.infinity, detection.probability)
        }
        let deduped = best.sorted { a, b in
            a.value == b.value ? a.key < b.key : a.value > b.value
        }
        return deduped.map { code, probability -> String in
            let name = WhisperLanguageCatalog.language(forCode: code)?.englishName ?? code
            let percent = Int((probability * 100).rounded())
            return "\(name) \(percent)%"
        }.joined(separator: ", ")
    }

}
