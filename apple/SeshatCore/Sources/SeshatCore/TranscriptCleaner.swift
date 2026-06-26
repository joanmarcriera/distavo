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

    /// Group consecutive same-speaker turns under one `[SPEAKER_xx]` header,
    /// flushing on speaker change or when a turn would exceed `maxTurnChars`.
    public static func clean(_ segments: [Segment], maxTurnChars: Int = 1800) -> String {
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
            let text = normaliseSpace(segment.text)
            if text.isEmpty { continue }
            if let cs = currentSpeaker, speaker != cs || currentLen + text.count > maxTurnChars {
                flush()
            }
            if currentSpeaker == nil { currentSpeaker = speaker }
            parts.append(text)
            currentLen += text.count + 1
        }
        flush()

        return grouped.map { "[\($0.0)]\n\($0.1)" }.joined(separator: "\n\n")
    }
}
