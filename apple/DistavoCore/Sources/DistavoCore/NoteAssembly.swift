import Foundation

// Assembles the final note text from the summary body (Vikunja #2954):
//
//     frontmatter, model body (with ## Highlights), ## Key moments, ## Tracked terms, provenance footer
//     (the body handed in already includes Highlights and Key moments; each section appears once)
//
// Used by `Pipeline.processOne` and `Pipeline.regenerate`. With `NotesConfig` at its
// defaults (everything off / empty) `assemble` returns exactly `body + footer`, so an
// existing user's notes are byte-identical to before. The validator runs on the summary
// BEFORE this, so frontmatter and the tracked-terms list never count towards (or trip) it.

public enum NoteAssembly {

    public struct Inputs: Sendable {
        /// The summariser's output with the Distavo-Title/Tags lines already removed.
        public var body: String
        /// The provenance footer ("" for WhisperX results); kept last.
        public var footer: String
        public var title: String?
        public var llmTags: [String]
        /// Timed (or, failing that, untimed) transcript turns for tracked terms.
        public var turns: [TrackedTerms.Turn]
        public var meetingDate: Date?
        public var participants: String?
        /// The recording's file name.
        public var sourceName: String?
        public var durationSeconds: Double?
        public var templateID: String?
        public var languageCode: String?
        /// The note currently on disk (regenerate / re-run): its unmanaged frontmatter
        /// keys are preserved, and its date/source fill what the caller does not know.
        public var existingNote: String?
        /// Calendar attendee names (#2946): data for the frontmatter `attendees:` list, whether or
        /// not the owner confirmed them (they never reach the prompt through this path).
        public var calendarAttendees: [String]

        public init(body: String, footer: String = "", title: String? = nil, llmTags: [String] = [],
                    turns: [TrackedTerms.Turn] = [], meetingDate: Date? = nil, participants: String? = nil,
                    sourceName: String? = nil, durationSeconds: Double? = nil, templateID: String? = nil,
                    languageCode: String? = nil, existingNote: String? = nil,
                    calendarAttendees: [String] = []) {
            self.calendarAttendees = calendarAttendees
            self.body = body; self.footer = footer; self.title = title; self.llmTags = llmTags
            self.turns = turns; self.meetingDate = meetingDate; self.participants = participants
            self.sourceName = sourceName; self.durationSeconds = durationSeconds
            self.templateID = templateID; self.languageCode = languageCode; self.existingNote = existingNote
        }
    }

    public static func assemble(_ i: Inputs, notes: NotesConfig, timeZone: TimeZone = .current) -> String {
        // Tracked terms: independent of the frontmatter switch.
        let reports = notes.terms.isEmpty ? [] : TrackedTerms.find(terms: notes.terms, in: i.turns)
        let section = TrackedTerms.section(reports)
        let text: String
        if section.isEmpty {
            text = i.body + i.footer
        } else {
            // One blank line between the notes and the section, whatever the body ended with.
            let trimmed = i.body.trimmingCharacters(in: .whitespacesAndNewlines)
            text = trimmed + "\n" + section + i.footer
        }
        guard notes.frontmatter else { return text }

        // Deterministic tags first, then the model's; Obsidian-safe and de-duplicated.
        var tags = ["meeting"]
        if let t = i.templateID, let s = NoteMeta.slug(t) { tags.append(s) }
        if let l = i.languageCode, let s = NoteMeta.slug(l) { tags.append("lang/" + s) }
        tags += TrackedTerms.tags(reports)
        tags += i.llmTags
        var seen = Set<String>()
        tags = tags.filter { seen.insert($0).inserted }

        let previous = i.existingNote
        let fields = NoteFrontmatterFields(
            date: i.meetingDate.map { NoteFrontmatter.dateString($0, timeZone: timeZone) }
                ?? previous.flatMap { NoteFrontmatter.value("date", in: $0) },
            title: i.title,
            attendees: mergeAttendees(NoteFrontmatter.attendees(fromParticipants: i.participants), i.calendarAttendees),
            tags: tags,
            source: i.sourceName ?? previous.flatMap { NoteFrontmatter.value("source", in: $0) },
            durationMinutes: i.durationSeconds.flatMap(minutes))
        // The user's own keys come from the note being replaced; a body that somehow
        // still carries a block of its own (it never should) is stripped, never doubled.
        let preserved = previous.flatMap { NoteFrontmatter.split($0).block }
        return NoteFrontmatter.render(fields, preserving: preserved) + NoteFrontmatter.strip(text)
    }

    /// `base` plus any calendar name not already present (case-insensitive); `base` unchanged when none.
    static func mergeAttendees(_ base: [String], _ calendar: [String]) -> [String] {
        var seen = Set(base.map { $0.lowercased() })
        var out = base
        for name in calendar where seen.insert(name.lowercased()).inserted { out.append(name) }
        return out
    }

    /// Whole minutes, rounded, at least 1 for any audio; nil for no/invalid duration.
    static func minutes(_ seconds: Double) -> Int? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        return max(1, Int((seconds / 60).rounded()))
    }

    /// The length of the timed transcript: the last segment end.
    public static func durationSeconds(of segments: TranscriptSegments?) -> Double? {
        segments?.segments.map(\.end).max()
    }
}
