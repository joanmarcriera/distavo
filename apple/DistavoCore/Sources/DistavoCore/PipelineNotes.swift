import Foundation

// Glue between `Pipeline` / `Regenerate` and the Obsidian-friendly output (Vikunja #2954).
// Kept out of Pipeline.swift so its hunks stay tiny.

extension Pipeline {

    /// Remember the model's title beside the note (see `NoteMeta.storeTitle`), only while a
    /// title is wanted; a regenerate without one clears a stale title.
    static func rememberTitle(_ meta: NoteMeta.Extracted?, config: Config, workDir: URL, base: String) {
        guard config.notes.wantsTitle else { return }
        NoteMeta.storeTitle(meta?.title, workDir: workDir, base: base)
    }

    /// The text to write for a validated summary: the body (title/tags lines already
    /// extracted) + footer, with frontmatter and tracked terms when configured. With the
    /// default `NotesConfig` this is exactly `body + footer`.
    static func composeNote(
        body: String, footer: String, meta: NoteMeta.Extracted?, config: Config,
        context: NoteContext, sourceName: String?,
        timed: TranscriptSegments?, cleanTranscript: String,
        dominantCode: String?, existingNote: String?
    ) -> String {
        let notes = config.notes
        if notes == NotesConfig() { return body + footer }
        let spoken = EmbeddedModelCatalog.isAutomatic(config.transcribe.language)
            || config.transcribe.language.isEmpty ? nil : config.transcribe.language
        let turns = timed.map(TrackedTerms.turns(from:)) ?? TrackedTerms.turns(fromCleanTranscript: cleanTranscript)
        return NoteAssembly.assemble(
            NoteAssembly.Inputs(
                body: body, footer: footer,
                title: notes.wantsTitle ? meta?.title : nil,
                llmTags: notes.wantsTags ? (meta?.tags ?? []) : [],
                turns: turns, meetingDate: context.meetingDate, participants: context.participants,
                sourceName: sourceName, durationSeconds: NoteAssembly.durationSeconds(of: timed),
                templateID: context.template?.id, languageCode: dominantCode ?? spoken,
                existingNote: existingNote),
            notes: notes)
    }
}
