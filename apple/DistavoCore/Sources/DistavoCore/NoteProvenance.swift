import Foundation

/// Builds the footer Pipeline appends to a note when the transcribe result
/// carries engine/detection metadata (spec: "which engine transcribed this
/// meeting, what language did it detect"). Pure and dependency-free so it is
/// unit-tested directly, without going through the pipeline.
public enum NoteProvenance {

    /// - Parameters:
    ///   - engine: a human label for the engine that transcribed the meeting
    ///     (e.g. "Languages of Spain (BSC)").
    ///   - detections: detected languages in the order to display them. Empty
    ///     omits the "Detected language" sentence entirely.
    /// - Returns: a footer block (leading blank line + `---` + one italic
    ///   line) ready to append verbatim to the note text.
    public static func footer(engine: String, detections: [(code: String, probability: Double)]) -> String {
        var line = "_Transcribed on this Mac with \(engine)."
        if !detections.isEmpty {
            let parts = detections.map { detection -> String in
                let name = WhisperLanguageCatalog.language(forCode: detection.code)?.englishName ?? detection.code
                let percent = Int((detection.probability * 100).rounded())
                return "\(name) \(percent)%"
            }
            line += " Detected language: \(parts.joined(separator: ", "))."
        }
        line += "_"
        return "\n\n---\n\(line)"
    }
}
