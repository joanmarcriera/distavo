# Note language: manual checks (Vikunja #2956)

Prompt construction, the resolver, the sidecar and the pipeline wiring are unit-tested
(`NoteLanguageTests`, `PipelineTests`, `LanguageOverrideTests`, `ConfigMigrationTests`). What
cannot be checked headlessly is listed here. Use a throwaway recordings folder; every build shares
Marc's real config, so restore `summarise.note_language` afterwards.

## Settings (Notes > Write notes in)
- [ ] Picker offers: Match the meeting language, English, then "Always <language>" for every
      Whisper language. A hand-edited unknown value shows as "<value> (unrecognised, writes English)".
- [ ] Transcription > Spoken language caption points to Notes > Write notes in, and vice versa.
- [ ] Search "language" / "translate" finds the Notes pane.

## Real summaries (needs a model, so human-only)
- [ ] Ollama: a French recording with "Match the meeting language" gives a French note with
      English headings (`# Meeting notes`, `## Action items`, ...); with "English" gives English.
- [ ] Gemma (Direct only): same two cases; check the validator does not flag missing headings.
- [ ] Apple Intelligence: with "Always French" (supported on the Mac) the note is French; with
      "Always Catalan" the note is English and the activity log shows no language on the
      on-device routing line. Confirm `SystemLanguageModel.supportsLocale` really reports
      false for Catalan and true for French on a macOS 26 Mac.

## Per-recording override ("Who was in this meeting?" window after Stop)
- [ ] A new "Write notes in" popup sits under the language row; the window is tall enough
      (no clipped rows) with and without the "Meeting language" row.
- [ ] Untouched popup + Save writes no `<base>.language.json`.
- [ ] Choosing "Always German" writes `{"code":"","note_language":"de"}` into the work folder
      and that recording's note is German while the Settings default is unchanged.
- [ ] Choosing a spoken language AND a note language keeps both in one sidecar.
