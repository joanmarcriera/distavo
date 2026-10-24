import Foundation

/// Pre-summary gate (Vikunja #4015): decides whether a transcript looks like a meeting at all.
/// Film/TV audio picked up by a phone, or a solo voice memo, used to get a full interview note with an
/// invented candidate. Pure and dependency-free; `Pipeline` only calls it when
/// `summarise.non_meeting_guard` is on (default off, inert for any config predating the key).
///
/// Signals (all read from the diarised segments, never from audio):
/// - many distinct speakers and no participants sheet -> `.notAMeeting` (a scene with a cast);
/// - mostly non-speech tags (music/applause/...) -> `.notAMeeting`;
/// - one speaker only -> `.soloMemo` (memo template, no candidate/role invention);
/// - anything else -> `.meeting` (the normal path, unchanged).
/// A participants sheet (the owner said who was there) always wins: then it is a meeting.
public enum MeetingShapeGate {
    public enum Verdict: Equatable, Sendable {
        case meeting
        case soloMemo
        case notAMeeting(reason: String)
    }

    /// More distinct speakers than this, with no sheet, is a cast rather than a meeting.
    public static let maxPlausibleSpeakers = 6
    /// Share of segments that are only a sound tag above which the audio is not speech.
    public static let maxTagShare = 0.5
    /// Below this many words in total there is nothing to judge: stay on the normal path.
    public static let minWords = 40

    public static func assess(segments: [Segment], hasParticipantsSheet: Bool) -> Verdict {
        if hasParticipantsSheet { return .meeting }
        let spoken = segments.filter {
            !TranscriptCleaner.stripSoundTags($0.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let tagOnly = segments.count - spoken.count
        if !segments.isEmpty, Double(tagOnly) / Double(segments.count) > maxTagShare {
            return .notAMeeting(reason: "most of the recording is non-speech sound")
        }
        let words = spoken.reduce(0) {
            $0 + TranscriptCleaner.normaliseSpace($1.text).split(separator: " ").count
        }
        guard words >= minWords else { return .meeting }
        let speakers = Set(spoken.map(\.speaker).filter { $0 != "SPEAKER_UNKNOWN" })
        if speakers.count > maxPlausibleSpeakers {
            return .notAMeeting(reason: "\(speakers.count) different voices and no participants list")
        }
        if speakers.count <= 1 { return .soloMemo }
        return .meeting
    }

    /// Body of the short note written for `.notAMeeting` (transcript only, nothing invented).
    public static func notAMeetingNote(reason: String, transcript: String) -> String {
        "# Recording\n\n"
        + "> This does not look like a meeting (\(reason)), so no summary was written. "
        + "Use Regenerate Note… if it was one; the transcript is below.\n\n"
        + "## Transcript\n\n" + transcript.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Template for a one-voice recording: what was said, decisions, follow-ups; no roles or counterparts.
    public static let memoTemplate: SummaryTemplate = SummaryTemplate.parse(
        id: "memo", name: "Voice memo", summary: "A single speaker thinking aloud.", outline: """
        This is ONE person speaking alone (a voice memo). There is no counterpart: do not invent a candidate, \
        client, role or other participants, and do not claim anything is stated in metadata.

        ## What was said
        A short paragraph in the speaker's own terms.

        ## Decisions and follow-ups
        Bullets for anything the speaker decided or said they must do. Write "none stated" if there are none.
        """)!
}
