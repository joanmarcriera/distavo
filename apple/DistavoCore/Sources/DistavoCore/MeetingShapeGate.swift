import Foundation

/// Pre-summary gate (Vikunja #4015): decides whether a transcript looks like a meeting at all.
/// Film/TV audio picked up by a phone, or a solo voice memo, used to get a full interview note with an
/// invented candidate. Pure and dependency-free; `Pipeline` only calls it when
/// `summarise.non_meeting_guard` is on (default off, inert for any config predating the key).
///
/// Signals (all read from the diarised segments, never from audio):
/// - many distinct speakers and no participants sheet -> `.notAMeeting` (a scene with a cast);
/// - mostly non-speech tags (music/applause/...) -> `.notAMeeting`;
/// - low speaker confidence (more than half of the spoken words have no speaker although diarisation did
///   label some, or 3+ voices that trade turns every few words, as in a film scene) and no sheet
///   -> `.notAMeeting`; all-unlabelled (diarisation off) is NOT low confidence and stays a meeting;
/// - exactly one real speaker label -> `.soloMemo` (no labels at all = unknown = `.meeting`) (memo template, no candidate/role invention);
/// - anything else -> `.meeting` (the normal path, unchanged).
/// A participants sheet (the owner said who was there) always wins: then it is a meeting.
public enum MeetingShapeGate {
    public enum Verdict: Equatable, Sendable {
        case meeting
        case soloMemo
        /// A recorded course, video or narrated walkthrough played back: scripted prompts, one voice leading.
        case playback(reason: String)
        case notAMeeting(reason: String)
    }

    /// More distinct speakers than this, with no sheet, is a cast rather than a meeting.
    public static let maxPlausibleSpeakers = 6
    /// Share of segments that are only a sound tag above which the audio is not speech.
    public static let maxTagShare = 0.5
    /// Below this many words in total there is nothing to judge: stay on the normal path.
    public static let minWords = 40

    /// Share of spoken words without a speaker label above which the labels cannot be trusted.
    public static let maxUnlabelledShare = 0.5
    /// With 3+ voices, fewer words than this per turn on average is crosstalk, not a conversation.
    public static let minWordsPerTurn = 4.0
    /// A label counts as a voice for the "cast" rule only above this share of the labelled words.
    public static let minVoiceShare = 0.05

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
        if let why = lowSpeakerConfidence(spoken: spoken, speakers: speakers) {
            return .notAMeeting(reason: why)
        }
        // Over-segmented diarisation spawns many labels; only those holding a real share of the speech
        // count as voices (a cast has many substantial ones, a long meeting a few plus slivers).
        let voices = substantialVoices(spoken: spoken)
        if voices > maxPlausibleSpeakers {
            return .notAMeeting(reason: "\(voices) different voices and no participants list")
        }
        if let why = playbackReason(spoken: spoken) { return .playback(reason: why) }
        // No usable label (diarisation off, failed or all SPEAKER_UNKNOWN) says nothing about the number
        // of people: stay on the normal meeting path. Only exactly one real label is a solo memo.
        if speakers.count == 1 { return .soloMemo }
        return .meeting
    }

    /// Phrases a course or tutorial narrator says to a learner, never one colleague to another.
    /// Only phrases that a live colleague does not say: on-screen course prompts and course framing. Everyday
    /// work speech ("by the end of this week", "this training budget", "click next" in a screen share) is left out.
    static let playbackCues: [String] = [
        "press the start button", "click the start button", "click the next button", "pause the video",
        "knowledge check", "select the correct answer", "in the next lesson", "welcome to this course",
        "welcome to this module", "at the end of this module", "in this module you will",
        "in this lesson you will", "in this course you will", "in this course we will",
    ]
    /// Distinct cues needed, and the share of the words the leading voice must hold (a narrator, not a conversation).
    public static let minPlaybackCues = 3
    public static let minNarratorShare = 0.8

    /// Why this reads as a played-back course or video rather than a live conversation, or nil.
    /// Needs both signals: scripted learner prompts AND one voice carrying the talk.
    static func playbackReason(spoken: [Segment]) -> String? {
        // Without real speaker labels (diarisation off) one voice cannot be told from many: never playback.
        guard spoken.contains(where: { $0.speaker != "SPEAKER_UNKNOWN" && !$0.speaker.isEmpty }) else { return nil }
        let text = spoken.map { TranscriptCleaner.normaliseSpace($0.text).lowercased() }.joined(separator: " ")
        let hits = playbackCues.filter { text.contains($0) }
        guard hits.count >= minPlaybackCues else { return nil }
        var perLabel: [String: Int] = [:]
        for seg in spoken {
            perLabel[seg.speaker.isEmpty ? "SPEAKER_UNKNOWN" : seg.speaker, default: 0] +=
                TranscriptCleaner.normaliseSpace(seg.text).split(separator: " ").count
        }
        let total = perLabel.values.reduce(0, +)
        guard total > 0, let top = perLabel.values.max(), Double(top) / Double(total) >= minNarratorShare else { return nil }
        return "scripted prompts such as '" + hits[0] + "' and one narrating voice"
    }

    /// Labels holding at least `minVoiceShare` of the labelled words.
    static func substantialVoices(spoken: [Segment]) -> Int {
        var perLabel: [String: Int] = [:]
        for seg in spoken where seg.speaker != "SPEAKER_UNKNOWN" && !seg.speaker.isEmpty {
            perLabel[seg.speaker, default: 0] += TranscriptCleaner.normaliseSpace(seg.text).split(separator: " ").count
        }
        let total = perLabel.values.reduce(0, +)
        guard total > 0 else { return 0 }
        return perLabel.values.filter { Double($0) / Double(total) >= minVoiceShare }.count
    }

    /// The low-speaker-confidence signal (#4015): nil when the labels look usable.
    static func lowSpeakerConfidence(spoken: [Segment], speakers: Set<String>) -> String? {
        func words(_ seg: Segment) -> Int { TranscriptCleaner.normaliseSpace(seg.text).split(separator: " ").count }
        let isLabelled: (Segment) -> Bool = { $0.speaker != "SPEAKER_UNKNOWN" && !$0.speaker.isEmpty }
        let total = spoken.reduce(0) { $0 + words($1) }
        let unlabelled = spoken.filter { !isLabelled($0) }.reduce(0) { $0 + words($1) }
        if total > 0, !speakers.isEmpty, Double(unlabelled) / Double(total) > maxUnlabelledShare {
            return "the speakers could not be told apart"
        }
        if speakers.count >= 3 {
            var turns = 0, last: String?
            for seg in spoken where isLabelled(seg) { if seg.speaker != last { turns += 1; last = seg.speaker } }
            if turns > 0, Double(total - unlabelled) / Double(turns) < minWordsPerTurn {
                return "the voices change every few words"
            }
        }
        return nil
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

    /// Template for a played-back course or video (also bundled as id `playback`, pickable per recording).
    public static var playbackTemplate: SummaryTemplate { SummaryTemplateCatalog.playback }
}
