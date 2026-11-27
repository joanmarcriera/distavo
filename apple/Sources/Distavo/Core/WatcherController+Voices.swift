import AppKit
import DistavoCore
import DistavoEmbedded

// Voice profiles (#2944 phase 2): the "Remember this voice" half. Recognition runs in the pipeline
// (`VoiceRecognition.recognise` through `PipelineDeps.voiceEmbeddings`); what is stored and how it is matched
// is decided by `VoiceProfiles.swift` (DistavoCore). This file finds the recording, waits for the scan lock
// (the voice model must not load next to a transcription) and reports the outcome.
extension WatcherController {

    /// Whether the rename sheet offers "Remember this voice".
    var voiceProfilesOn: Bool {
        #if EDITION_APPSTORE
        return false
        #else
        return config.transcribe.voiceProfiles
        #endif
    }

    /// Stores a voice sample for each of `names` (as they stand after the rename) from this note's recording.
    func rememberVoices(base: String, names: [String]) async {
        guard voiceProfilesOn, !names.isEmpty else { return }
        await runExclusivePass(onlyIf: { true }) { await self.storeVoices(base: base, names: names) }
    }

    private func storeVoices(base: String, names: [String]) async {
        let cfg = config
        guard let audio = Self.recordingURL(forBase: LanguageOverride.sourceBase(from: base),
                                            in: Config.resolvePath(cfg.recordingsDir)) else {
            log("Voices not remembered: the recording of \(base) is no longer in the recordings folder")
            notifyUser(title: "Voice not remembered", body: "The recording of \(base) is no longer in the recordings folder.")
            return
        }
        do {
            let stored = try await VoiceRecognition.remember(
                names: names, base: base, audio: audio, workDir: Config.resolvePath(cfg.workDir),
                supportDir: deps.voiceProfilesDir, model: deps.voiceModel,
                embed: { audio, ranges in await VoiceEmbedder.embeddings(audio: audio, ranges: ranges) })
            let missed = names.filter { !stored.contains($0) }
            // Names only in the log: never a sample, never a score.
            log("Voices remembered from \(base): \(stored.count) of \(names.count)")
            if stored.isEmpty {
                notifyUser(title: "Voice not remembered",
                                body: "There was not enough clear speech (about 8 seconds of longer turns), or the voice model could not be loaded.")
            } else {
                notifyUser(title: "✅ Voice remembered",
                                body: stored.joined(separator: ", ") + (missed.isEmpty ? "" : ". Not enough clear speech for: " + missed.joined(separator: ", ")))
            }
        } catch {
            log("Voices not remembered: \(error.localizedDescription)")
            notifyUser(title: "Voice not remembered", body: error.localizedDescription)
        }
    }

    // MARK: Name Voices

    /// Menu "Name Voices…": listen to the unnamed voices of past recordings and name them.
    /// Right after a note is saved: when the meeting still has an unnamed speaker who talked a lot, ask who
    /// the top ones are (`VoiceReview.topCandidates`), in the Name Voices window limited to that meeting.
    /// Cheap check first (the timed transcript only); the voice model loads only when there is someone to ask
    /// about. The window comes up without taking the keyboard; if Name Voices is already open it is left alone.
    func offerToNameVoices(afterNote base: String) {
        guard voiceProfilesOn, !NameVoicesWindowController.shared.isOpen else { return }
        let cfg = config
        let work = Config.resolvePath(cfg.workDir), rec = Config.resolvePath(cfg.recordingsDir)
        guard Self.recordingURL(forBase: LanguageOverride.sourceBase(from: base), in: rec) != nil,
              let timed = TranscriptSegments.load(workDir: work, base: base),
              !VoiceReview.topCandidates(in: timed).isEmpty else { return }
        log("Name Voices: asking about the voices of the meeting just processed")   // no names
        showNameVoices(onlyBase: base)
    }

    func showNameVoices(onlyBase: String? = nil) {
        guard voiceProfilesOn else {
            notifyUser(title: "Voices are switched off",
                       body: "Switch on Settings > Transcription > “Recognise remembered voices” first.")
            return
        }
        // Every voice of every recording is reviewed in the Voices window; this small one is the question
        // right after a meeting.
        #if !EDITION_APPSTORE
        guard let onlyBase else { showVoices(tab: .unnamed); return }
        #else
        guard let onlyBase else { return }
        #endif
        NameVoicesWindowController.shared.show(activate: false, model: self.nameVoicesModel(onlyBase: onlyBase))
    }

    /// The model of the "not yet named" list: all recordings, or the one just processed.
    func nameVoicesModel(onlyBase: String?) -> NameVoicesModel {
        let notes = Config.resolvePath(config.notesDir), rec = Config.resolvePath(config.recordingsDir)
        let cancel = VoiceScanCancel()
        return NameVoicesModel(
            heading: onlyBase == nil ? "Name the voices in your recordings" : "Who spoke most in the meeting you just recorded?",
            people: PeoplePages.suggestions(notesDir: notes, limit: 40).map(\.name),
            cancelled: cancel,
            scan: { [weak self] progress, all in
                await self?.scanVoices(progress: progress, onlyBase: onlyBase, all: all, cancel: cancel) ?? ([], 0, 0)
            },
            apply: { [weak self] voice, name, remember, progress in
                await self?.nameVoice(voice, name: name, remember: remember, progress: progress) ?? "Distavo is closing."
            },
            audio: { base in Self.recordingURL(forBase: LanguageOverride.sourceBase(from: base), in: rec) })
    }

    /// One voice sample per unnamed speaker of every note whose recording is still there, grouped into voices.
    /// Holds the scan lock: the voice model must not load next to a transcription.
    /// Returns the voices, how many recordings were listened to and how many could be (`VoiceReview.firstBatch`
    /// newest unless `all`).
    private func scanVoices(progress: @escaping (String) -> Void, onlyBase: String? = nil, all: Bool = false,
                            cancel: VoiceScanCancel = VoiceScanCancel()) async -> ([VoiceReview.Voice], Int, Int) {
        var voices: [VoiceReview.Voice] = [], listened = 0, available = 0
        await runExclusivePass(onlyIf: { true }) {
            let cfg = self.config
            let notes = Config.resolvePath(cfg.notesDir), work = Config.resolvePath(cfg.workDir)
            let rec = Config.resolvePath(cfg.recordingsDir)
            let supportDir = self.deps.voiceProfilesDir, model = self.deps.voiceModel
            (voices, listened, available) = await Task.detached(priority: .userInitiated) { () -> ([VoiceReview.Voice], Int, Int) in
                let entries = NotesLibrary.scan(notesDir: notes, workDir: work)
                    .filter { !$0.isVariant && (onlyBase == nil || $0.base == onlyBase) }
                var found: [VoiceReview.Occurrence] = []
                // Only notes whose recording is still there and that have an unnamed speaker are listened to;
                // the count shown is of those, not of every note.
                var todo: [(entry: NoteEntry, audio: URL, candidates: [VoiceReview.Candidate])] = []
                for e in entries {
                    guard let audio = Self.recordingURL(forBase: LanguageOverride.sourceBase(from: e.base), in: rec),
                          let timed = TranscriptSegments.load(workDir: work, base: e.base) else { continue }
                    // One meeting = the question after it: only the unnamed people who spoke the most.
                    let candidates = onlyBase == nil ? VoiceReview.candidates(in: timed) : VoiceReview.topCandidates(in: timed)
                    if !candidates.isEmpty { todo.append((e, audio, candidates)) }
                }
                let available = todo.count
                todo = VoiceReview.newest(todo, date: { $0.entry.date }, base: { $0.entry.base }, limit: all || onlyBase != nil ? nil : VoiceReview.firstBatch)
                for (i, item) in todo.enumerated() {
                    let (e, audio, candidates) = item
                    if cancel.on { return ([], 0, available) }   // the window was closed: nobody is waiting for this
                    progress("Listening to recording \(i + 1) of \(todo.count)…")
                    let samples = await VoiceEmbedder.embeddings(
                        audio: audio, ranges: Dictionary(uniqueKeysWithValues: candidates.map { ($0.label, $0.ranges) }))
                    for c in candidates {
                        guard let sample = samples[c.label] else { continue }
                        found.append(.init(base: e.base, label: c.label, title: e.title, date: e.date,
                                           sampleStart: c.sampleStart, sampleEnd: c.sampleEnd, quote: c.quote, embedding: sample,
                                           introduction: c.introduction))
                    }
                }
                return (VoiceReview.group(found, store: VoiceProfileStore.load(supportDir: supportDir, model: model)), todo.count, available)
            }.value
        }
        log("Name Voices: \(voices.count) voices found in \(listened) of \(available) recordings")   // counts only
        return (voices, listened, available)
    }

    /// Names one voice in all its meetings; returns the line shown under the row. The meetings are a queue:
    /// one at a time, newest first, each under the scan lock and off the main thread, with the lock released
    /// in between so a recording that finishes meanwhile is not kept waiting behind twenty rewrites. The row
    /// shows how far it is; the people pages follow once, at the end.
    private func nameVoice(_ voice: VoiceReview.Voice, name: String, remember: Bool,
                           progress: @escaping (String) -> Void) async -> String {
        let cfg = config
        let notes = Config.resolvePath(cfg.notesDir), work = Config.resolvePath(cfg.workDir)
        let supportDir = deps.voiceProfilesDir, model = deps.voiceModel
        var total = VoiceReview.Applied(), saved = true
        for (i, occurrence) in voice.occurrences.enumerated() {
            if voice.occurrences.count > 1 { progress("Working… meeting \(i + 1) of \(voice.occurrences.count)") }
            // Longer than the 500 ms the waiters of the scan lock sleep: a finished recording, a regenerate or a
            // rename waiting for the lock gets it between two meetings.
            if i > 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
            let one = VoiceReview.Voice(id: voice.id, occurrences: [occurrence], suggestedName: voice.suggestedName)
            await runExclusivePass(onlyIf: { true }) {
                let (r, ok) = await Task.detached(priority: .userInitiated) { () -> (VoiceReview.Applied, Bool) in
                    // Load, change and save the voice file in one turn (Settings can rename or delete a voice meanwhile).
                    VoiceProfileStore.fileLock.lock(); defer { VoiceProfileStore.fileLock.unlock() }
                    var store = VoiceProfileStore.load(supportDir: supportDir, model: model)
                    // Never save over a voice file this build cannot read (another model, a newer Distavo).
                    let remember = remember && !VoiceProfileStore.hasIncompatibleFile(supportDir: supportDir, model: model)
                    let r = VoiceReview.apply(voice: one, name: name, remember: remember, notesDir: notes, workDir: work, store: &store)
                    return (r, !r.remembered || (try? store.save(supportDir: supportDir)) != nil)
                }.value
                total = VoiceReview.merged(total, r)
                saved = saved && ok
                for base in r.renamed {
                    self.indexForSearch(base: base, note: notes.appendingPathComponent("\(base).md"))
                    self.exportToVault(base: base, note: notes.appendingPathComponent("\(base).md"))
                }
            }
        }
        // The people pages follow at once (they only ever grow from owner-confirmed names).
        await Task.detached(priority: .userInitiated) {
            _ = Self.updatePeoplePagesInTurn(notes: notes, work: work, owner: cfg.noteOwner)
        }.value
        log("Name Voices: named a voice in \(total.renamed.count) meetings, skipped \(total.skipped.count)")
        var parts = ["Named in \(total.renamed.count) meeting\(total.renamed.count == 1 ? "" : "s")"]
        if !total.skipped.isEmpty { parts.append("\(total.skipped.count) left alone (\(Set(total.skipped.values).sorted().joined(separator: "; ")))") }
        if remember { parts.append(total.remembered && saved ? "voice remembered" : "voice NOT remembered") }
        return parts.joined(separator: ", ") + "."
    }
}
