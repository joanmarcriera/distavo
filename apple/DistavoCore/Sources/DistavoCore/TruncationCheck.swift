// TruncationCheck.swift — does the recording stop before the call did? (Vikunja #4013)
//
// Pure. A recorder that stops at a calendar slot end leaves the last sentence unfinished; the summariser
// then writes a confident "Next steps" from nothing. Rule: the last timed segment ends within
// `edgeSeconds` (2 s) of the audio end AND its text has no sentence-closing punctuation or closing
// phrase ("thanks, bye"). Only then is the recording flagged; the check never invents anything, it only
// warns and tells the summariser what is missing. Numbers only in logs.
import Foundation

public enum TruncationCheck {
    public static let edgeSeconds = 2.0
    /// Ignore recordings too short to judge.
    public static let minAudioSeconds = 60.0

    /// Footer / banner sentence for the note.
    public static let banner = "Recording may end before the call did"

    /// Prompt block appended when truncated; "" otherwise so every other prompt stays byte-identical.
    public static func promptBlock(_ truncated: Bool) -> String {
        guard truncated else { return "" }
        return """

        The transcript below appears to be CUT OFF: the recording stopped while people were still talking, so the end of the conversation is missing. Do not invent what was said after it. Under any next steps, decisions, dates or timeline that the transcript does not state, write exactly "not recorded". Never quote a sentence that is not in the transcript.

        """
    }

    /// True when the last segment runs to the end of the audio without closing.
    public static func isTruncated(lastSegmentEnd: Double?, lastText: String?, audioSeconds: Double?) -> Bool {
        guard let end = lastSegmentEnd, let text = lastText, let audio = audioSeconds,
              audio >= minAudioSeconds, audio - end <= edgeSeconds, end <= audio + edgeSeconds else { return false }
        return !closesConversation(text)
    }

    /// Ends in sentence punctuation, or contains a closing phrase near its end.
    static func closesConversation(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return false }
        let closings = ["bye", "goodbye", "thank you", "thanks", "take care", "speak soon", "talk soon",
                        "see you", "cheers", "have a good", "adeu", "gràcies", "gracias", "hasta luego"]
        let tail = t.lowercased().suffix(60)
        if closings.contains(where: { tail.contains($0) }) { return true }
        // A full stop alone is not enough: Whisper punctuates mid-sentence cuts too, but an unfinished
        // clause usually has no terminal mark at all; a clause ending ",", "-" or a lone conjunction is open.
        if ".?!…".contains(last) { return true }
        return false
    }

    /// Convenience over timed segments.
    public static func isTruncated(segments: [TranscriptSegments.Segment], audioSeconds: Double?) -> Bool {
        guard let last = segments.last(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
        return isTruncated(lastSegmentEnd: last.end, lastText: last.text, audioSeconds: audioSeconds)
    }

    /// One log line, numbers only.
    public static func logLine(lastSegmentEnd: Double, audioSeconds: Double) -> String {
        "Recording may be cut off: last speech ends \(Int(lastSegmentEnd.rounded())) s into \(Int(audioSeconds.rounded())) s of audio"
    }
}
