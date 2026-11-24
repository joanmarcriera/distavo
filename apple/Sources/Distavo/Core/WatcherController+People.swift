import AppKit
import DistavoCore

// "Update People Pages" (drive 2026-11-23): `notes/people/<Name>.md` for everyone the owner named (renamed
// speakers, the participants answer) plus the `_People.md` index. Everything a page says is decided by
// `PeoplePages` (DistavoCore); this file only resolves the folders, writes off the main actor and opens the index.
// Nothing leaves the Mac: the LinkedIn link in a page is a search the owner opens in their own browser.
extension WatcherController {

    /// After a note is written, with `notes.refresh_people_pages` on: the pages follow quietly (no window, no
    /// notification unless a page could not be read). Off = nothing is written to the people folder unasked.
    func refreshPeoplePagesAfterNote() {
        guard config.notes.refreshPeoplePages else { return }
        updatePeoplePages(open: false)
    }

    func updatePeoplePages() { updatePeoplePages(open: true) }

    /// Every people-pages update of the app goes through here, one at a time (the menu, the refresh after a
    /// note, Name Voices): two updates reading and writing the same pages at once could put back an older state.
    static let peoplePagesTurn = NSLock()
    nonisolated static func updatePeoplePagesInTurn(notes: URL, work: URL, owner: String) -> Result<PeoplePages.Summary, Error> {
        peoplePagesTurn.lock(); defer { peoplePagesTurn.unlock() }
        return Result {
            try PeoplePages.update(notesDir: notes, workDir: work, ownerName: owner,
                                   glossary: NameGlossary.load(supportDir: NameGlossary.defaultSupportDir))
        }
    }

    /// Menu "Meeting Brief…": who is coming? -> `notes/people/_Brief.md` (last meetings and open tasks per
    /// person, `MeetingBrief`, no model), opened in the owner's editor.
    func showMeetingBrief() {
        let alert = NSAlert()
        alert.messageText = "Who are you about to meet?"
        alert.informativeText = "Names separated by commas. Distavo lists your last meetings with each of them and what is still open, from your own notes. Nothing is looked up."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "Anna Berg, Pere"
        alert.accessoryView = field
        alert.addButton(withTitle: "Write Brief")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        writeMeetingBrief(for: field.stringValue)
    }

    /// Writes and opens the brief for a typed list of people (also used by Quick Notes during a recording).
    func writeMeetingBrief(for typed: String) {
        let names = MeetingBrief.names(in: typed)
        guard !names.isEmpty else { return }
        let notes = Config.resolvePath(config.notesDir), work = Config.resolvePath(config.workDir)
        let owner = config.noteOwner
        Task {
            let url = await Task.detached(priority: .userInitiated) {
                try? MeetingBrief.write(for: names, notesDir: notes, workDir: work, ownerName: owner,
                                        glossary: NameGlossary.load(supportDir: NameGlossary.defaultSupportDir))
            }.value
            self.log("Meeting brief written for \(names.count) people")   // a count only
            if let url { NSWorkspace.shared.open(url) } else {
                self.notifyUser(title: "Brief not written", body: "The people folder of your notes could not be written.")
            }
        }
    }

    private func updatePeoplePages(open: Bool) {
        let notes = Config.resolvePath(config.notesDir), work = Config.resolvePath(config.workDir)
        let owner = config.noteOwner
        Task {
            let result: Result<PeoplePages.Summary, Error> = await Task.detached(priority: .userInitiated) {
                Self.updatePeoplePagesInTurn(notes: notes, work: work, owner: owner)
            }.value
            switch result {
            case .success(let s):
                self.log("People pages: \(s.created.count) new, \(s.updated.count) updated, \(s.unchanged) unchanged, \(s.unreadable.count) unreadable")
                if !s.unreadable.isEmpty {
                    // The file is the owner's and is not UTF-8 text: left untouched, and said so.
                    self.notifyUser(title: "\(s.unreadable.count) people page\(s.unreadable.count == 1 ? "" : "s") left untouched",
                                    body: "Not saved as UTF-8 text, so Distavo did not change: " + s.unreadable.joined(separator: ", "))
                }
                if open { NSWorkspace.shared.open(s.index) }
            case .failure(let error):
                // The system's message names the file, which is a person's name: the kind of error only.
                self.log("People pages could not be written (\(type(of: error)) \((error as NSError).domain) \((error as NSError).code))")
            }
        }
    }
}
