#if !EDITION_APPSTORE
import AppKit
import DistavoCore
import DistavoEmbedded

// "Review Voices" (#2944): the Voices window, opened from Settings > Transcription and from the menu's
// "Name Voices…". What is listed and what each button does is decided by `VoiceCatalog` (DistavoCore); this
// file reads the folders, asks the voice engine for the samples an operation needs, holds the scan lock
// while notes are rewritten or the voice model is loaded, and reports counts (never a name) to the log.
extension WatcherController {

    func showVoices(tab: VoicesModel.Tab = .remembered) {
        guard voiceProfilesOn else {
            notifyUser(title: "Voices are switched off",
                       body: "Switch on Settings > Transcription > “Recognise remembered voices” first.")
            return
        }
        log("Voices: window opened")
        let rec = Config.resolvePath(config.recordingsDir)
        let naming = nameVoicesModel(onlyBase: nil)
        naming.autoStart = false
        VoicesWindowController.shared.show(tab: tab, model: VoicesModel(
            tab: tab, naming: naming,
            load: { [weak self] in await self?.loadVoiceCatalog() ?? VoicesSnapshot() },
            confirm: { [weak self] clip in await self?.confirmVoice(clip) ?? false },
            separate: { [weak self] name, bases, to, remember, renameNotes in
                await self?.separateVoice(name: name, bases: bases, to: to, remember: remember, renameNotes: renameNotes) ?? "Distavo is closing."
            },
            merge: { [weak self] name, into, renameNotes, bases in
                await self?.mergeVoice(name: name, into: into, renameNotes: renameNotes, bases: bases) ?? "Distavo is closing."
            },
            undo: { [weak self] in await self?.undoVoiceChange() ?? "Distavo is closing." },
            audio: { base in Self.recordingURL(forBase: LanguageOverride.sourceBase(from: base), in: rec) }))
    }

    private func voiceContext() -> VoiceCatalog.Context {
        VoiceCatalog.Context(notesDir: Config.resolvePath(config.notesDir), workDir: Config.resolvePath(config.workDir),
                             supportDir: deps.voiceProfilesDir, model: deps.voiceModel)
    }

    /// Reads the notes, the timed transcripts and the voice file. No model, no lock: nothing is written.
    private func loadVoiceCatalog() async -> VoicesSnapshot {
        let cfg = config
        let c = voiceContext()
        let rec = Config.resolvePath(cfg.recordingsDir)
        return await Task.detached(priority: .userInitiated) {
            let meetings = NotesLibrary.scan(notesDir: c.notesDir, workDir: c.workDir).filter { !$0.isVariant }
                .map { VoiceCatalog.Meeting(base: $0.base, title: $0.title, date: $0.date) }
            let store = VoiceProfileStore.load(supportDir: c.supportDir, model: c.model)
            let recorded = Self.recordedBases(in: rec)
            return VoicesSnapshot(
                people: VoiceCatalog.people(store: store, meetings: meetings, workDir: c.workDir, clipLimit: VoicesModel.loadedClips),
                unnamed: VoiceCatalog.unnamed(meetings: meetings, workDir: c.workDir),
                recorded: recorded, undo: VoiceCatalog.pendingUndo(supportDir: c.supportDir)?.summary)
        }.value
    }

    /// The bases that still have a recording: one walk of the recordings folder, not one per meeting.
    nonisolated private static func recordedBases(in rec: URL) -> Set<String> {
        var out = Set<String>()
        guard let en = FileManager.default.enumerator(at: rec, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        for case let url as URL in en where supportedExtensions.contains("." + url.pathExtension.lowercased()) {
            out.insert(DistavoState.baseFor(recordingsDir: rec, path: url))
        }
        return out
    }

    /// "That is them": the name Distavo gave by voice in that meeting is right.
    private func confirmVoice(_ clip: VoiceCatalog.Clip) async -> Bool {
        let c = voiceContext(), owner = config.noteOwner
        var changed = false
        await runExclusivePass(onlyIf: { true }) {
            changed = await Task.detached(priority: .userInitiated) {
                let ok = (try? SpeakerNames.confirmVoiceNames([clip.speaker], workDir: c.workDir, base: clip.base)) ?? false
                if ok { _ = Self.updatePeoplePagesInTurn(notes: c.notesDir, work: c.workDir, owner: owner) }
                return ok
            }.value
        }
        log("Voices: a voice guess confirmed in one meeting (\(changed ? "saved" : "nothing to change"))")
        return changed
    }

    /// The notes of the meetings an operation renamed follow everywhere they are copied to.
    private func afterVoiceRenames(_ bases: [String], context c: VoiceCatalog.Context) async {
        for base in bases {
            indexForSearch(base: base, note: c.notesDir.appendingPathComponent("\(base).md"))
            exportToVault(base: base, note: c.notesDir.appendingPathComponent("\(base).md"))
        }
        let owner = config.noteOwner
        await Task.detached(priority: .userInitiated) {
            _ = Self.updatePeoplePagesInTurn(notes: c.notesDir, work: c.workDir, owner: owner)
        }.value
    }

    private func separateVoice(name: String, bases: [String], to: String, remember: Bool, renameNotes: Bool) async -> String {
        let c = voiceContext()
        let rec = Config.resolvePath(config.recordingsDir)
        var line = ""
        await runExclusivePass(onlyIf: { true }) {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<VoiceCatalog.Outcome, Error> in
                // The voice of that speaker in each meeting, to find the samples the profile learnt from it.
                var samples: [String: [Float]] = [:]
                for base in bases {
                    guard let audio = Self.recordingURL(forBase: LanguageOverride.sourceBase(from: base), in: rec),
                          let (speaker, ranges) = VoiceCatalog.sampleRanges(name: name, base: base, workDir: c.workDir) else { continue }
                    samples[base] = await VoiceEmbedder.embeddings(audio: audio, ranges: [speaker: ranges])[speaker]
                }
                return Result { try VoiceCatalog.separate(name: name, meetings: bases, embeddings: samples, to: to,
                                                          remember: remember, renameNotes: renameNotes, context: c) }
            }.value
            switch result {
            case .success(let out):
                await self.afterVoiceRenames(out.renamed, context: c)
                self.log("Voices: not-this-person on \(bases.count) meetings: \(out.renamed.count) renamed, \(out.skipped.count) left alone, \(out.samplesRemoved) samples removed")
                var parts = [renameNotes ? "Corrected \(out.renamed.count) meeting\(out.renamed.count == 1 ? "" : "s")" : "Meetings left as they are"]
                if !out.skipped.isEmpty { parts.append("\(out.skipped.count) left alone (\(Set(out.skipped.values).sorted().joined(separator: "; ")))") }
                parts.append(out.samplesRemoved == 0 ? "no sample of \(name) came from there"
                             : "\(out.samplesRemoved) sample\(out.samplesRemoved == 1 ? "" : "s") taken out of \(name)’s voice")
                if out.voiceForgotten { parts.append("\(name) has no sample left and is no longer recognised") }
                if remember, !to.isEmpty { parts.append(out.remembered ? "\(to) remembered" : "\(to) NOT remembered (not enough clear speech, or the recording is gone)") }
                line = parts.joined(separator: ", ") + "."
            case .failure(let error):
                self.log("Voices: not-this-person changed nothing (\(type(of: error)))")
                line = error.localizedDescription
            }
        }
        return line
    }

    private func mergeVoice(name: String, into: String, renameNotes: Bool, bases: [String]) async -> String {
        let c = voiceContext()
        var line = ""
        await runExclusivePass(onlyIf: { true }) {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try VoiceCatalog.merge(name: name, into: into, renameNotes: renameNotes, meetings: bases, context: c) }
            }.value
            switch result {
            case .success(let out):
                await self.afterVoiceRenames(out.renamed, context: c)
                self.log("Voices: \(out.merged ? "merge" : "rename"): \(out.renamed.count) meetings renamed, \(out.skipped.count) left alone")
                var parts = [out.merged ? "\(name) and \(into) are now one voice" : "The voice is now called \(into)"]
                if renameNotes { parts.append("renamed in \(out.renamed.count) meeting\(out.renamed.count == 1 ? "" : "s")") }
                if !out.skipped.isEmpty { parts.append("\(out.skipped.count) left alone (\(Set(out.skipped.values).sorted().joined(separator: "; ")); use Rename Speakers there)") }
                line = parts.joined(separator: ", ") + "."
            case .failure(let error):
                self.log("Voices: merge changed nothing (\(type(of: error)))")
                line = error.localizedDescription
            }
        }
        return line
    }

    private func undoVoiceChange() async -> String {
        let c = voiceContext()
        var line = ""
        await runExclusivePass(onlyIf: { true }) {
            let result = await Task.detached(priority: .userInitiated) { Result { try VoiceCatalog.undo(context: c) } }.value
            switch result {
            case .success(let out):
                await self.afterVoiceRenames(out.renamed, context: c)
                self.log("Voices: undo: \(out.renamed.count) meetings put back, \(out.skipped.count) left alone")
                line = "Undone: the remembered voices are as before"
                    + (out.renamed.isEmpty ? "" : ", \(out.renamed.count) meeting\(out.renamed.count == 1 ? "" : "s") put back")
                    + (out.skipped.isEmpty ? "" : ", \(out.skipped.count) left alone (\(Set(out.skipped.values).sorted().joined(separator: "; ")))") + "."
            case .failure(let error):
                self.log("Voices: undo changed nothing (\(type(of: error)))")
                line = error.localizedDescription
            }
        }
        return line
    }
}
#endif
