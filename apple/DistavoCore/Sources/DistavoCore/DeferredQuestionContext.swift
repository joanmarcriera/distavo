// DeferredQuestionContext.swift — everything the deferred "who was there?" form shows, assembled (Vikunja #4021).
//
// Pure: no UI, no audio, no clock, no file reads (the app loads the sidecars and passes values in). It joins
// the pieces that already exist: `SpeakerRecallAids` (context line + distinctive lines per speaker),
// `CalendarMatch` (`<base>.calendar.json`), `ScratchpadNotes` (`<base>.scratchpad.json`) and
// `RecordingBookmarks` (`<base>.bookmarks.json`).
//
// Trust rules (CLAUDE.md "Calendar content is untrusted"): the form is for a human, never for the model, but the
// attendee names still pass `CalendarAttendees.plausibleName` so a hostile invitation cannot put markup, links or
// a wall of text into the window; the event title is shown only after the same control-character cleaning. Nothing
// here ever reaches `Prompt.build`.
// Everything is local: the speaker lines come from the recording's own segments.
import Foundation

public struct DeferredQuestionContext: Equatable, Sendable {
    /// "Teams, 15:15–15:30, 15 min".
    public var contextLine: String
    /// The matched calendar event's title, cleaned; nil without a match or when nothing printable remains.
    public var eventTitle: String?
    /// Plausible attendee names only (at most `maxAttendees`).
    public var attendees: [String]
    /// Quick Notes typed during the call, flagged lines first, in the order typed otherwise.
    public var typedNotes: [String]
    /// Key moment labels (or "mm:ss" when a mark has no label), in time order.
    public var keyMoments: [String]
    public var speakers: [SpeakerRecallAids.SpeakerLines]

    public static let maxAttendees = 12
    public static let maxNotes = 5
    public static let maxMoments = 5
    static let maxTitleChars = 100

    public var isEmpty: Bool {
        eventTitle == nil && attendees.isEmpty && typedNotes.isEmpty && keyMoments.isEmpty && speakers.isEmpty
    }

    public static func build(callApp: String?, recordingStart: Date, durationSeconds: Double, timeZone: TimeZone,
                             calendar: CalendarMatch?, scratchpad: ScratchpadNotes?, bookmarks: RecordingBookmarks?,
                             segments: [TranscriptSegments.Segment], audioSeconds: Double? = nil,
                             linesPerSpeaker: Int = 3) -> DeferredQuestionContext {
        var seen = Set<String>()
        let attendees = (calendar?.attendees ?? []).compactMap { CalendarAttendees.plausibleName($0) }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(maxAttendees)

        let notes: [String] = {
            guard let lines = scratchpad?.sanitised().lines else { return [] }
            let flagged = lines.filter(\.flagged), plain = lines.filter { !$0.flagged }
            return (flagged + plain).map(\.text).filter { !$0.isEmpty }.prefix(maxNotes).map { $0 }
        }()

        let moments: [String] = (bookmarks?.marks ?? []).sorted { $0.offsetSeconds < $1.offsetSeconds }
            .prefix(maxMoments).map { mark in
                let label = mark.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return label.isEmpty ? ScratchpadNotes.timestamp(Int(max(0, mark.offsetSeconds))) : label
            }

        return DeferredQuestionContext(
            contextLine: SpeakerRecallAids.contextLine(callApp: callApp, start: recordingStart,
                                                       durationSeconds: durationSeconds, timeZone: timeZone),
            eventTitle: calendar.flatMap { cleanTitle($0.title) },
            attendees: Array(attendees),
            typedNotes: notes,
            keyMoments: moments,
            speakers: SpeakerRecallAids.distinctiveLines(segments: segments, perSpeaker: linesPerSpeaker,
                                                         audioSeconds: audioSeconds))
    }

    /// Control, format and bidi characters removed, whitespace collapsed, capped; nil when empty.
    static func cleanTitle(_ raw: String) -> String? {
        var out = String.UnicodeScalarView()
        for u in raw.unicodeScalars {
            if u.properties.isWhitespace { out.append(" "); continue }
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: continue
            default: out.append(u)
            }
        }
        let t = String(out).split(separator: " ").joined(separator: " ")
        guard !t.isEmpty else { return nil }
        return t.count > maxTitleChars ? String(t.prefix(maxTitleChars)) + "…" : t
    }
}
