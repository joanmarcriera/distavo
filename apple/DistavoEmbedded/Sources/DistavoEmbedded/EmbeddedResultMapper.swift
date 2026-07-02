import Foundation
import WhisperKit
import SpeakerKit

/// Adapts WhisperKit / SpeakerKit output to the WhisperX JSON shape the rest of
/// the pipeline consumes (`["segments": [{speaker?, text, start, end}]]`), so
/// `TranscriptCleaner` and everything downstream stay byte-for-byte unchanged.
/// Pure functions — unit-tested without models or downloads.
public enum EmbeddedResultMapper {

    /// Whisper decoder text can carry special tokens (`<|en|>`, `<|0.00|>`, …)
    /// depending on decoding options; WhisperX never emits them, so strip.
    static func cleanText(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Non-diarized path: plain transcription segments, no speaker labels
    /// (TranscriptCleaner renders them as SPEAKER_UNKNOWN, same as a WhisperX
    /// server with diarization off).
    public static func whisperXDictionary(segments: [TranscriptionSegment]) -> [String: Any] {
        var out: [[String: Any]] = []
        for segment in segments {
            let text = cleanText(segment.text)
            guard !text.isEmpty else { continue }
            out.append([
                "text": text,
                "start": Double(segment.start),
                "end": Double(segment.end),
            ])
        }
        return ["segments": out]
    }

    /// Diarized path: SpeakerKit's speaker-labelled subsegments, labelled
    /// `SPEAKER_00`-style exactly like WhisperX/pyannote server output.
    public static func whisperXDictionary(speakerGroups: [[SpeakerSegment]]) -> [String: Any] {
        var out: [[String: Any]] = []
        for group in speakerGroups {
            for segment in group {
                let text = cleanText(segment.text)
                guard !text.isEmpty else { continue }
                var entry: [String: Any] = [
                    "text": text,
                    "start": Double(segment.startTime),
                    "end": Double(segment.endTime),
                ]
                if let id = segment.speaker.speakerId {
                    entry["speaker"] = String(format: "SPEAKER_%02d", id)
                }
                out.append(entry)
            }
        }
        return ["segments": out]
    }
}
