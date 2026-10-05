import SwiftUI
import DistavoCore

/// Notes pane > Templates (Vikunja #2940): the summary template that decides which
/// sections the note has (stand-up, 1:1, interview, sales call, lecture, or your own),
/// plus a per-subfolder override list. Per recording, the "Who was in this meeting?"
/// window after recording can pick another one. All logic (resolution order, parsing,
/// the bundled list) lives in DistavoCore's `SummaryTemplateCatalog`; this is a thin editor
/// over `summarise.template`, `summarise.custom_template` and `summarise.folder_templates`.
struct TemplatesSection: View {
    @ObservedObject var model: SettingsModel

    /// One editable folder -> template row (the stored form is a dictionary, which
    /// cannot hold a half-typed, empty or duplicate key while the user edits).
    private struct FolderRow: Identifiable, Equatable {
        let id = UUID()
        var folder: String
        var template: String
    }
    @State private var rows: [FolderRow] = []
    @State private var loaded = false

    private var bundled: [SummaryTemplate] { SummaryTemplateCatalog.bundledTemplates }

    var body: some View {
        Section("Templates") {
            Picker("Note template", selection: $model.draft.summarise.template) {
                Text("None (standard notes)").tag("")
                ForEach(bundled) { Text($0.name).tag($0.id) }
                Text("Custom").tag(SummaryTemplateCatalog.customID)
                // A stored id nothing offers (hand-edited config): keep it visible; it behaves as None.
                if !knownIDs.contains(model.draft.summarise.template) {
                    Text("\(model.draft.summarise.template) (unrecognised — standard notes)")
                        .tag(model.draft.summarise.template)
                }
            }
            .withHelp("A template changes which sections the note has, to suit the kind of meeting: Stand-up (updates, plans, blockers), 1:1, Interview, Sales call or Lecture — or your own. The rest of the prompt (note owner, speakers, language, facts ledger) is unchanged, and section headings stay in English whatever language the note is written in. Choose ‘None’ for the standard 16-section note. You can pick a different template for one recording in the “Who was in this meeting?” window after you stop recording, and per folder below. Works with Ollama, the downloaded Gemma model and Apple Intelligence.")
            SettingCaption("Which sections the note has. None keeps the standard note.")

            DisclosureGroup("Custom template") {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $model.draft.summarise.customTemplate)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 130)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    HStack {
                        Menu("Start from…") {
                            ForEach(bundled) { t in
                                Button(t.name) { model.draft.summarise.customTemplate = t.outline }
                            }
                        }
                        .fixedSize()
                        Spacer()
                        Text(customStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
            .withHelp("Write your own sections as a Markdown outline: a line per section starting with ‘## ’, optionally followed by a line or two saying what it should contain (a table is fine). Any text before the first ‘## ’ tells the model what kind of meeting this is. Example: ‘## Wins’, then ‘What went well.’, then ‘## Risks’. ‘Start from…’ copies a bundled template to edit. It is used wherever ‘Custom’ is chosen. Keep it short: on Apple’s on-device model (small window) a long custom template is ignored and that note is written with the standard sections instead.")

            VStack(alignment: .leading, spacing: 6) {
                Text("Templates by folder").font(.headline)
                SettingCaption("A recording in a subfolder of your recordings folder uses that folder’s template (the longest matching folder wins).")
                ForEach($rows) { $row in
                    HStack {
                        TextField("Folder, e.g. Sales", text: $row.folder)
                        Picker("", selection: $row.template) {
                            ForEach(bundled) { Text($0.name).tag($0.id) }
                            Text("Custom").tag(SummaryTemplateCatalog.customID)
                            Text("None (standard notes)").tag(SummaryTemplateCatalog.noneID)
                            // Hand-edited unknown id: keep it visible instead of a blank picker.
                            if !knownFolderIDs.contains(row.template) {
                                Text("\(row.template) (unrecognised — standard notes)").tag(row.template)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        Button(role: .destructive) {
                            rows.removeAll { $0.id == row.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove this folder rule")
                    }
                }
                HStack {
                    Button("Add a folder…") {
                        rows.append(FolderRow(folder: "", template: bundled[0].id))
                    }
                    HelpButton(text: "The folder is a path inside your recordings folder, like ‘Sales’ or ‘Clients/Acme’ (case does not matter). Recordings placed in that folder — or in folders below it — get that template; a template chosen for one recording after recording still wins, and recordings elsewhere use the ‘Note template’ above. A rule set to ‘None’ keeps standard notes for that folder.")
                }
            }
        }
        .onAppear(perform: loadRows)
        .onChange(of: rows) { _, new in storeRows(new) }
    }

    private var knownIDs: Set<String> {
        Set([""] + bundled.map(\.id) + [SummaryTemplateCatalog.customID])
    }

    private var knownFolderIDs: Set<String> {
        Set(bundled.map(\.id) + [SummaryTemplateCatalog.customID, SummaryTemplateCatalog.noneID])
    }

    private var customStatus: String {
        let text = model.draft.summarise.customTemplate
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Empty — Custom behaves as None." }
        guard let t = SummaryTemplate.parse(id: "custom", name: "Custom", outline: text) else {
            return "No ‘## ’ section headings yet — Custom behaves as None."
        }
        return "\(t.sections.count) section\(t.sections.count == 1 ? "" : "s")"
    }

    private func loadRows() {
        guard !loaded else { return }
        loaded = true
        rows = model.draft.summarise.folderTemplates
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { FolderRow(folder: $0.key, template: $0.value) }
    }

    /// Rows with an empty folder are kept in the editor but not saved; a duplicate
    /// folder keeps its first row.
    private func storeRows(_ rows: [FolderRow]) {
        var map: [String: String] = [:]
        for r in rows {
            let key = r.folder.trimmingCharacters(in: CharacterSet(charactersIn: " /\t"))
            guard !key.isEmpty, map[key] == nil else { continue }
            map[key] = r.template
        }
        if model.draft.summarise.folderTemplates != map { model.draft.summarise.folderTemplates = map }
    }
}
