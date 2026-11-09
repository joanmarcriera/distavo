import Foundation

/// A single speaker turn extracted from a WhisperX result.
public struct Segment: Equatable {
    public var speaker: String
    public var text: String
    public var start: Double?
    public var end: Double?

    public init(speaker: String, text: String, start: Double? = nil, end: Double? = nil) {
        self.speaker = speaker
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Port of `meeting_pipeline/cleaning.py`: turn a WhisperX result into a
/// speaker-grouped, timestamp-free transcript.
public enum TranscriptCleaner {

    public static func normaliseSpace(_ value: String) -> String {
        let collapsed = value.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func speakerOrUnknown(_ value: Any?) -> String {
        if let s = value as? String, !s.isEmpty { return s }
        return "SPEAKER_UNKNOWN"
    }

    /// Accepts a JSON object (as produced by `JSONSerialization`) and handles the
    /// three response shapes WhisperX services emit, mirroring the Python logic.
    public static func segments(from result: [String: Any]) -> [Segment] {
        if let raw = result["segments"] as? [Any] {
            var out: [Segment] = []
            for item in raw {
                guard let dict = item as? [String: Any] else { continue }
                let text = normaliseSpace((dict["text"] as? String) ?? "")
                if text.isEmpty { continue }
                out.append(Segment(
                    speaker: speakerOrUnknown(dict["speaker"]),
                    text: text,
                    start: dict["start"] as? Double,
                    end: dict["end"] as? Double))
            }
            return out
        }

        if let textList = result["text"] as? [Any] {
            var out: [Segment] = []
            for item in textList {
                let lineText: String
                let speaker: String
                if let dict = item as? [String: Any] {
                    lineText = normaliseSpace((dict["text"] as? String) ?? "")
                    speaker = speakerOrUnknown(dict["speaker"])
                } else {
                    lineText = normaliseSpace((item as? String) ?? "")
                    speaker = "SPEAKER_UNKNOWN"
                }
                if !lineText.isEmpty {
                    out.append(Segment(speaker: speaker, text: lineText))
                }
            }
            return out
        }

        let textValue = normaliseSpace((result["text"] as? String) ?? "")
        return textValue.isEmpty ? [] : [Segment(speaker: "SPEAKER_UNKNOWN", text: textValue)]
    }

    /// Removes sound tags Whisper hallucinates on room noise (Vikunja #4016): `*music*`, `*pain*`,
    /// `[Music]`, `[BLANK_AUDIO]`, `(applause)`. Asterisk tags are 1-3 plain words; bracketed ones are
    /// limited to a known list so real parenthetical speech is never touched.
    public static func stripSoundTags(_ value: String) -> String {
        var out = value
        out = out.replacingOccurrences(of: #"\*[A-Za-z]+(?: [A-Za-z]+){0,2}\*"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(
            of: #"(?i)[\[(]\s*(?:blank[_ ]audio|music|applause|laughter|silence|noise|inaudible|background noise)\s*[\])]"#,
            with: " ", options: .regularExpression)
        return out == value ? value : normaliseSpace(out)
    }

    /// Whole-segment phrases Whisper emits on silence (Vikunja #4025): an 80-minute recording with the
    /// mic in its case came back as "Thank you for watching" ~20 times and "you you you", and the summary
    /// invented a meeting from it. Compared case- and accent-folded, punctuation dropped, against the
    /// WHOLE segment, so "Thank you." or "thank you for watching the demo" (real speech) is never touched.
    static let silencePhrases: Set<String> = [
        "thank you for watching", "thanks for watching", "thank you so much for watching",
        "thank you for watching this video", "thanks for watching this video",
        "please subscribe", "like and subscribe", "please like and subscribe",
        "gracias por ver", "gracias por ver el video", "gracias por vernos",
        "gracies per veure", "gracies per veure el video",
    ]

    /// True when `value` is, as a whole, a stock Whisper silence hallucination: one of
    /// `silencePhrases`, an Amara.org subtitle credit (any language), or "you" said 3+ times and nothing else.
    public static func isSilenceHallucination(_ value: String) -> Bool {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if folded.contains("amara.org") { return true }
        let words = folded.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }
        if words.count >= 3, words.allSatisfy({ $0 == "you" }) { return true }
        return silencePhrases.contains(words.joined(separator: " "))
    }

    /// Group consecutive same-speaker turns under one `[SPEAKER_xx]` header,
    /// flushing on speaker change or when a turn would exceed `maxTurnChars`.
    ///
    /// `replacements` (Vikunja #2939) is the user's find/replace map, applied to
    /// each finished turn's text (never the speaker header). Empty = untouched,
    /// so the output is byte-identical to before the feature.
    public static func clean(_ segments: [Segment], maxTurnChars: Int = 1800,
                             replacements: [ReplacementRule] = []) -> String {
        var grouped: [(String, String)] = []
        var currentSpeaker: String?
        var parts: [String] = []
        var currentLen = 0

        func flush() {
            if let speaker = currentSpeaker, !parts.isEmpty {
                grouped.append((speaker, normaliseSpace(parts.joined(separator: " "))))
            }
            currentSpeaker = nil
            parts = []
            currentLen = 0
        }

        for segment in segments {
            let speaker = segment.speaker.isEmpty ? "SPEAKER_UNKNOWN" : segment.speaker
            let text = normaliseSpace(stripSoundTags(segment.text))
            if text.isEmpty || isSilenceHallucination(text) { continue }
            if let cs = currentSpeaker, speaker != cs || currentLen + text.count > maxTurnChars {
                flush()
            }
            if currentSpeaker == nil { currentSpeaker = speaker }
            parts.append(text)
            currentLen += text.count + 1
        }
        flush()

        // Compiled once for all turns (regex construction dominates the cost).
        let compiled = CompiledReplacements(replacements)
        if !compiled.isEmpty {
            grouped = grouped.map { ($0.0, compiled.apply($0.1)) }
        }
        return grouped.map { "[\($0.0)]\n\($0.1)" }.joined(separator: "\n\n")
    }
}
