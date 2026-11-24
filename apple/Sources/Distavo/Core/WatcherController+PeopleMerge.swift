import AppKit
import DistavoCore

// "Merge People…" (2026-11-23): one person ended up as two people pages. What a merge and its undo do to the
// pages is decided by `PeopleMerge` (DistavoCore); this file asks which two, warns when they both spoke in one
// meeting (a sign they are two people), runs it in turn with the other people-page updates and moves the
// remembered voice along. Notes and transcripts are never changed here.
extension WatcherController {
    /// One Merge People conversation at a time: a second one would list people the first is about to change.
    private static var mergeFlowOpen = false

    func showMergePeople() {
        guard !Self.mergeFlowOpen else { NSApp.activate(ignoringOtherApps: true); return }
        Self.mergeFlowOpen = true
        let notes = Config.resolvePath(config.notesDir)
        Task {
            // Reading every page can wait on a synced folder (files not downloaded yet): never on the main thread.
            let (names, aside) = await Task.detached(priority: .userInitiated) {
                (PeoplePages.known(notesDir: notes).map(\.name).sorted { $0.lowercased() < $1.lowercased() },
                 PeopleMerge.setAside(notesDir: notes))
            }.value
            self.chooseMergePeople(names: names, aside: aside)
        }
    }

    private func chooseMergePeople(names: [String], aside: [PeopleMerge.SetAside]) {
        var handedOn = false
        defer { if !handedOn { Self.mergeFlowOpen = false } }
        guard names.count >= 2 || !aside.isEmpty else {
            notifyUser(title: "Nobody to merge yet", body: "There are fewer than two people pages. Use Update People Pages first.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Merge two people"
        alert.informativeText = "For when one person ended up as two pages. The first page stays and gets the meetings of both; the second becomes another spelling of it and its page is set aside, so the merge can be undone. Your notes are not changed."
        let keep = NSPopUpButton(frame: .zero, pullsDown: false), other = NSPopUpButton(frame: .zero, pullsDown: false)
        keep.addItems(withTitles: names); other.addItems(withTitles: names)
        if names.count > 1 { other.selectItem(at: 1) }
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Keep:"), keep],
                                      [NSTextField(labelWithString: "Merge into it:"), other]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        if names.count >= 2 { alert.accessoryView = grid }
        if names.count >= 2 { alert.addButton(withTitle: "Merge") }
        alert.addButton(withTitle: "Cancel")
        if !aside.isEmpty { alert.addButton(withTitle: "Undo a Merge…") }
        NSApp.activate(ignoringOtherApps: true)
        let answer = alert.runModal()
        let titles = alert.buttons.map(\.title)
        let pressed = titles.indices.contains(answer.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
            ? titles[answer.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue] : "Cancel"
        switch pressed {
        case "Merge":
            guard let k = keep.titleOfSelectedItem, let o = other.titleOfSelectedItem else { return }
            guard k.lowercased() != o.lowercased() else {
                notifyUser(title: "Nothing merged", body: "Choose two different people.")
                return
            }
            handedOn = true
            confirmMerge(o, into: k)
        case "Undo a Merge…":
            handedOn = true
            showUndoMerge(aside)
        default: return
        }
    }

    /// Says exactly what will happen, and warns when both spoke in the same meeting.
    private func confirmMerge(_ other: String, into keep: String) {
        let notes = Config.resolvePath(config.notesDir), work = Config.resolvePath(config.workDir)
        let owner = config.noteOwner
        let rememberVoice = voiceProfilesOn
        Task {
            let together = await Task.detached(priority: .userInitiated) { () -> [String] in
                // Spellings the pages already join count too.
                var spellings: [String: String] = [:]
                for p in PeoplePages.known(notesDir: notes) {
                    for s in [p.name] + p.aliases where spellings[s.lowercased()] == nil { spellings[s.lowercased()] = p.name }
                }
                let people = PeoplePages.collect(notesDir: notes, workDir: work, ownerName: owner,
                                                 glossary: NameGlossary.load(supportDir: NameGlossary.defaultSupportDir), known: spellings)
                return PeopleMerge.bothSpoke(other, keep, people: people)
            }.value
            let alert = NSAlert()
            alert.messageText = "Make \(other) part of \(keep)?"
            var text = "\(other) becomes another spelling of \(keep). The page of \(keep) lists the meetings of both and gets a copy of what you wrote on the page of \(other), which is set aside."
            text += " You can undo this from Merge People."
            if rememberVoice { text += " A remembered voice of \(other) becomes a voice of \(keep); undoing the merge does not move the voice back." }
            if !together.isEmpty {
                alert.alertStyle = .warning
                text += "\n\nThey both spoke in \(together.count) meeting\(together.count == 1 ? "" : "s") (\(together.prefix(3).joined(separator: "; "))\(together.count > 3 ? "…" : "")). If one person was split in two inside a meeting, merge the two speakers there with Rename Speakers; if they are two people, do not merge."
            }
            alert.informativeText = text
            alert.addButton(withTitle: "Merge")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { Self.mergeFlowOpen = false; return }
            self.mergePeople(other, into: keep)
        }
    }

    private func mergePeople(_ other: String, into keep: String) {
        let notes = Config.resolvePath(config.notesDir), work = Config.resolvePath(config.workDir)
        let owner = config.noteOwner
        let voices = voiceProfilesOn
        let supportDir = deps.voiceProfilesDir, model = deps.voiceModel
        Task {
            defer { Self.mergeFlowOpen = false }
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(PeopleMerge.Outcome, VoiceProfileStore.RenameOutcome?, Bool), Error> in
                Self.peoplePagesTurn.lock(); defer { Self.peoplePagesTurn.unlock() }
                return Result {
                    let outcome = try PeopleMerge.merge(other, into: keep, notesDir: notes)
                    // The merge is done whatever happens next: a page update that fails is said, not called "not merged".
                    let listed = (try? PeoplePages.update(notesDir: notes, workDir: work, ownerName: owner,
                                                          glossary: NameGlossary.load(supportDir: NameGlossary.defaultSupportDir))) != nil
                    return (outcome, voices ? Self.moveVoice(of: outcome.other, to: outcome.kept, supportDir: supportDir, model: model) : .unchanged, listed)
                }
            }.value
            switch result {
            case .success(let (outcome, voice, listed)):
                self.log("People merged: 1 page set aside, \(outcome.aliases.count) spellings added, voice \(voice.map { "\($0)" } ?? "not moved"), pages updated \(listed)")   // no names
                self.notifyUser(title: "✅ \(outcome.other) is now part of \(outcome.kept)",
                                body: (listed ? "One page lists the meetings of both" : "The pages are merged, but the meetings list could not be rewritten: use Update People Pages")
                                    + (voice == .unchanged ? "." : voice == nil
                                        ? ". The remembered voice of \(outcome.other) could not be moved: rename it in Settings > Transcription."
                                        : ", and the remembered voice went along."))
                let name = outcome.kept
                Task.detached { if let page = PeoplePages.pageURL(for: name, notesDir: notes) { NSWorkspace.shared.open(page) } }
            case .failure(let error):
                self.log("People not merged (\(type(of: error)))")   // the reason names a person: shown, not logged
                self.notifyUser(title: "Not merged", body: error.localizedDescription)
            }
        }
    }

    /// The remembered voice of `other` becomes (or joins) the voice of `keep`. Never saves over a voice file
    /// this build cannot read. `.unchanged` = there was no voice to move; nil = there may be one and it was not moved.
    nonisolated private static func moveVoice(of other: String, to keep: String, supportDir: URL, model: String) -> VoiceProfileStore.RenameOutcome? {
        VoiceProfileStore.fileLock.lock(); defer { VoiceProfileStore.fileLock.unlock() }
        guard !VoiceProfileStore.hasIncompatibleFile(supportDir: supportDir, model: model) else { return nil }
        var store = VoiceProfileStore.load(supportDir: supportDir, model: model)
        let outcome = store.rename(name: other, to: keep)
        guard outcome != .unchanged else { return .unchanged }
        return (try? store.save(supportDir: supportDir)) != nil ? outcome : nil
    }

    private func showUndoMerge(_ aside: [PeopleMerge.SetAside]) {
        let alert = NSAlert()
        alert.messageText = "Undo a merge"
        alert.informativeText = "For when the two turned out to be different people. The page that was set aside comes back as it was, and the other page lets go of the spellings the merge added and of the copied text (unless you edited it)."
            + (voiceProfilesOn ? " A remembered voice stays with the page that was kept: if it is now the wrong person's, rename it or forget it in Settings > Transcription (forgetting also removes what was remembered of the kept person, when both had a voice)." : "")
        let pick = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        // Menu items, not titles: two set-aside pages of one name must both be listed, in this order.
        for one in aside {
            pick.menu?.addItem(NSMenuItem(title: one.into.map { "\(one.name)  (now part of \($0))" } ?? one.name, action: nil, keyEquivalent: ""))
        }
        alert.accessoryView = pick
        alert.addButton(withTitle: "Separate")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, aside.indices.contains(pick.indexOfSelectedItem) else { Self.mergeFlowOpen = false; return }
        let chosen = aside[pick.indexOfSelectedItem]
        let notes = Config.resolvePath(config.notesDir), work = Config.resolvePath(config.workDir)
        let owner = config.noteOwner
        Task {
            defer { Self.mergeFlowOpen = false }
            let result = await Task.detached(priority: .userInitiated) { () -> Result<PeopleMerge.Outcome, Error> in
                Self.peoplePagesTurn.lock(); defer { Self.peoplePagesTurn.unlock() }
                return Result {
                    let outcome = try PeopleMerge.separate(chosen, notesDir: notes)
                    _ = try? PeoplePages.update(notesDir: notes, workDir: work, ownerName: owner,
                                                glossary: NameGlossary.load(supportDir: NameGlossary.defaultSupportDir))
                    return outcome
                }
            }.value
            switch result {
            case .success(let outcome):
                self.log("People separated: 1 page restored, \(outcome.aliases.count) spellings removed")   // no names
                self.notifyUser(title: "✅ \(outcome.other) has a page of their own again",
                                body: (outcome.kept.isEmpty ? "The page is back as it was." : "\(outcome.kept) no longer lists their meetings.")
                                    + (outcome.textLeft ? " The text copied from their page was changed since the merge, so it is still on the page of \(outcome.kept): remove it there if you do not want it." : ""))
                let name = outcome.other
                Task.detached { if let page = PeoplePages.pageURL(for: name, notesDir: notes) { NSWorkspace.shared.open(page) } }
            case .failure(let error):
                self.log("People not separated (\(type(of: error)))")
                self.notifyUser(title: "Not separated", body: error.localizedDescription)
            }
        }
    }
}
