import Foundation

/// The "Note template" row of the sheet shown when a recording stops (Vikunja #6667).
///
/// A stale `summarise.template = interview` from the job-search weeks produced candidate-shaped notes for
/// onboarding calls, because the sheet's first row ("Default from Settings") was preselected and nobody
/// looked at it. Rules, all pure so the AppKit sheet only renders them:
///
/// * **Auto is the first row.** The second row is still "Default from Settings (…)" (value nil) so a
///   deliberate fixed template stays one click away.
/// * **Preselection** is, in order: the last pick the owner made for this recordings subfolder (if it
///   still exists), the folder rule from `summarise.folder_templates`, otherwise Auto. A fixed global
///   Settings template is therefore not preselected (it is the stale-default trap); an untouched sheet
///   summarises with Auto, and the sheet always writes the preselected id, so the choice is in the sidecar.
/// * The pipeline logs the template it used (`StopSheetTemplate.logLine`).
/// * `hint` is the one-line Settings warning for a fixed template used 5+ times on recordings whose
///   participants text has no matching words.
public enum StopSheetTemplate {

    /// One popup row. `value == nil` means "no override: folder rule / Settings decide".
    public struct Choice: Equatable, Sendable {
        public let title: String
        public let value: String?
    }

    /// Rows in popup order: Auto, the Settings default, "No template", the bundled templates, Custom (if usable).
    public static func choices(config: Config, folder: String = "") -> [Choice] {
        var rows: [Choice] = [
            Choice(title: "Auto (from the participants)", value: SummaryTemplateCatalog.autoID),
            Choice(title: SettingsDefaults.templateLabel(config, folder: folder), value: nil),
            Choice(title: "No template", value: SummaryTemplateCatalog.noneID),
        ]
        rows += SummaryTemplateCatalog.bundledTemplates.map { Choice(title: $0.name, value: $0.id) }
        if SummaryTemplateCatalog.customTemplate(config: config) != nil {
            rows.append(Choice(title: "Custom", value: SummaryTemplateCatalog.customID))
        }
        return rows
    }

    /// The row index to preselect. `lastPicks` maps a normalised folder key to the last id picked there.
    public static func preselectedIndex(config: Config, folder: String, lastPicks: [String: String]) -> Int {
        let rows = choices(config: config, folder: folder)
        func index(of id: String?) -> Int? {
            guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !id.isEmpty else { return nil }
            return rows.firstIndex { $0.value == id }
        }
        if let i = index(of: lastPicks[folderKey(folder)]) { return i }
        if let i = index(of: SummaryTemplateCatalog.folderTemplateID(folder: folder, map: config.summarise.folderTemplates)) {
            return i
        }
        return 0   // Auto
    }

    /// The id the sheet writes to the sidecar for the selected row: the row's own id, or - for the
    /// "Default from Settings" row - nil (nothing is saved, Settings decide as before).
    public static func valueToSave(choices: [Choice], selectedIndex: Int) -> String? {
        guard choices.indices.contains(selectedIndex) else { return nil }
        return choices[selectedIndex].value
    }

    // MARK: Remembering the last pick per folder

    /// Lower-cased "/"-joined folder; "" (the recordings root) is its own key.
    public static func folderKey(_ folder: String) -> String {
        folder.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// `picks` with `id` remembered for `folder`. A nil id (the Settings row) forgets the folder's pick.
    public static func remembering(_ id: String?, folder: String, in picks: [String: String]) -> [String: String] {
        var out = picks
        let key = folderKey(folder)
        if let id, !id.isEmpty { out[key] = id.lowercased() } else { out.removeValue(forKey: key) }
        return out
    }

    // MARK: Settings hint

    /// How many recordings a fixed template must have been used for before the hint can show.
    public static let hintThreshold = 5

    /// A recording as far as the hint cares: the template id its note used and the participants text.
    public struct UsedRecording: Equatable, Sendable {
        public let templateID: String
        public let participants: String
        public init(templateID: String, participants: String) {
            self.templateID = templateID; self.participants = participants
        }
    }

    /// One line for Settings, or nil. Shows when `summarise.template` is a fixed bundled template, at
    /// least `hintThreshold` of the `recent` recordings used it, and none of their participants texts
    /// points at that template (`TemplateAutoPick`: an "interview" template needs recruiter/candidate words).
    public static func hint(config: Config, recent: [UsedRecording]) -> String? {
        let fixed = config.summarise.template.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !fixed.isEmpty, fixed != SummaryTemplateCatalog.autoID, fixed != SummaryTemplateCatalog.noneID,
              let template = SummaryTemplateCatalog.template(id: fixed, config: config) else { return nil }
        let used = recent.filter { $0.templateID.lowercased() == fixed }
        guard used.count >= hintThreshold else { return nil }
        let matches = used.contains { TemplateAutoPick.pick(participants: $0.participants, transcript: "")?.id == fixed }
        guard !matches else { return nil }
        return "\"\(template.name)\" has been used for \(used.count) recent recordings whose participants do not look like it. "
            + "Choose Auto to pick the template per recording."
    }

    // MARK: Log line

    /// "Summary template for <base>: Project meeting (auto, matched project, deployment)" - no content, only names.
    public static func logLine(base: String, template: SummaryTemplate?, autoNote: String?) -> String {
        let name = template?.name ?? "standard notes"
        var line = "Summary template for \(base): \(name)"
        if let note = autoNote, let open = note.range(of: "(") { line += " " + note[open.lowerBound...] }
        return line
    }
}
