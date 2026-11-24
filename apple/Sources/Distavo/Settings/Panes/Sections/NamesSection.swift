import SwiftUI
import AppKit
import DistavoCore

/// "Names and owners" (drive 2026-11-23), in the Notes pane: the name check (owner pinned, one person under several
/// spellings merged, task owners only when the transcript names them) and the plain-text glossary `names.txt`.
/// Logic: `OwnerName`, `NameConsistency`, `NameGlossary`, `ActionItemOwners` in DistavoCore; this view edits
/// `draft.summarise.nameCheck` and opens the file.
struct NamesSection: View {
    @ObservedObject var model: SettingsModel

    private static let starter = """
    # Names and terms for your notes. One per line.
    # Canonical name, then a colon and the spellings to merge into it (comma or semicolon between them):
    #   Jordan Ellis: Jordon Ellis, Jordan Elis
    # A line with just a name or term is only given to the summary as a spelling aid.

    """

    var body: some View {
        Section("Names and owners") {
            Toggle("Check names in notes", isOn: $model.draft.summarise.nameCheck)
                .withHelp("Pins your name from “Note owner” below in the summary instructions (when it is a real name, not “Me”), merges the spellings you list in your names file into one name, says in the footer when one person still appears under several spellings, and sets a task’s owner to “unassigned” when nobody by that name appears in the transcript. Highlights and quoted evidence are never rewritten.")
            HStack {
                Text("Names file")
                Spacer()
                Text(NameGlossary.fileName).foregroundStyle(.secondary)
                Button("Open…") { Self.openNamesFile() }
                    .disabled(!model.draft.summarise.nameCheck)
                HelpButton(text: "A plain text file in ~/Library/Application Support/Distavo. One line per person or term: the right spelling, a colon, then the wrong spellings the transcript produces (Jordan Ellis: Jordon Ellis, Jordan Elis). Whole words only, any capitals. It stays on your Mac.")
            }
            SettingCaption("Needs “Check names in notes”. Takes effect on the next note or regenerate.")
            Toggle("Update my people pages after every note", isOn: $model.draft.notes.refreshPeoplePages)
                .withHelp("After each note, the pages in the “people” folder of your notes are brought up to date: new people you named get a page, and the meetings list of the others grows. Off: the pages change only when you choose Update People Pages in the menu. Only the meetings list and an empty role or organisation are ever rewritten; your own text stays.")
            Toggle("Use my people pages in summaries", isOn: $model.draft.summarise.knownPeople)
                .withHelp("When someone in a meeting has a page in the “people” folder of your notes (menu: Update People Pages), the role and organisation you wrote there are given to the summary, so it does not guess who works where. It applies to the people you list after a recording and to speakers named by a rename or a remembered voice. Only your own pages are used; nothing is looked up.")
        }
    }

    private static func openNamesFile() {
        let dir = NameGlossary.defaultSupportDir
        let url = dir.appendingPathComponent(NameGlossary.fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? starter.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }
}
