import SwiftUI
import DistavoCore

/// "Obsidian & frontmatter" (Vikunja #2954), shown in the Notes pane: a YAML frontmatter block,
/// an AI title and tags, terms to flag with timestamps, and an optional second copy of each
/// note in a vault folder. All logic lives in DistavoCore (`NoteFrontmatter`, `NoteMeta`,
/// `TrackedTerms`, `VaultExport`); this view only edits `draft.notes`. Everything defaults to off.
struct ObsidianSection: View {
    @ObservedObject var model: SettingsModel

    /// Tracked terms as editable text, one per line (blank lines kept while typing).
    private var termsText: Binding<String> {
        Binding(
            get: { model.draft.notes.trackedTerms.joined(separator: "\n") },
            set: { model.draft.notes.trackedTerms = $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) })
    }

    var body: some View {
        Section("Obsidian & frontmatter") {
            Toggle("Add frontmatter to notes", isOn: $model.draft.notes.frontmatter)
                .withHelp("Starts every note with a small YAML block (date, title, attendees, tags, source recording, duration) that Obsidian shows as Properties and uses for search and tag lists. Turn this on if you keep your notes in Obsidian. If you regenerate a note, these keys are rewritten but any other keys you added to the block are kept.")
            Toggle("Suggest a title", isOn: $model.draft.notes.autoTitle)
                .withHelp("Asks the summary model for a short title, stored as the frontmatter title and used in the vault copy’s file name. The note keeps its normal file name in the notes folder. Adds one short instruction to the summary prompt; if the model ignores it, nothing is lost.")
            Toggle("Suggest tags", isOn: $model.draft.notes.autoTags)
                .withHelp("Asks the summary model for 3 to 6 topic tags, added to the frontmatter tags next to meeting, the note’s language and any tracked terms. Needs “Add frontmatter to notes” to show up in the note.")
            SettingCaption("Turn frontmatter on if you use Obsidian. Title and tags need a summary model that follows instructions; they are never required.")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Tracked terms").font(.callout)
                    HelpButton(text: "Words you want flagged wherever they come up (a project, “GDPR”, “pricing”). Each one found in the transcript becomes a tag and a line in a “Tracked terms” section at the end of the note with its timestamp, the sentence around it and who said it (up to 10 mentions per term, then “and N more”). Matches whole words, ignoring capitals. Works with every engine and does not use the summary model. Without timed transcripts (a WhisperX server that sends no timings) the lines have no timestamp.")
                }
                TextEditor(text: termsText)
                    .font(.body)
                    .frame(minHeight: 50, maxHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
            SettingCaption("One per line, for example pricing or GDPR.")

            HStack {
                Text("Vault folder")
                Spacer()
                Text(model.draft.notes.vaultDir.isEmpty ? "None" : model.draft.notes.vaultDir)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Choose…") {
                    if let url = SandboxFolders.chooseVault() { model.draft.notes.vaultDir = url.path }
                }
                Button("Clear") {
                    SandboxFolders.clearVault()
                    model.draft.notes.vaultDir = ""
                }
                .disabled(model.draft.notes.vaultDir.isEmpty)
                HelpButton(text: "Every finished (or regenerated) note is also copied into this folder as “<date> <title>.md”, so Obsidian picks it up. It is the same text as the note, so turn on frontmatter above. Existing files are never overwritten: a regenerated note replaces its own earlier copy unless you edited that copy, in which case it is saved as a numbered file beside it. If the folder is missing (for example an unmounted drive) the copy is skipped with a notification and the note itself is unaffected. Nothing leaves your Mac.")
            }
            if let why = VaultExport.conflict(
                vaultDir: model.draft.notes.vaultDir, notesDir: model.draft.notesDir,
                recordingsDir: model.draft.recordingsDir, workDir: model.draft.workDir) {
                SettingCallout(symbol: "exclamationmark.triangle") {
                    Text("Copies will be skipped: \(why).").font(.caption)
                }
            }
            if !model.draft.notes.vaultDir.isEmpty {
                TextField("Sub-folder inside the vault (optional)", text: $model.draft.notes.vaultSubfolder)
                SettingCaption("For example Meetings. Created if it does not exist.")
            }
        }
    }
}
