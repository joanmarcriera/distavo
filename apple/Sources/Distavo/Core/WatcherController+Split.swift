import AppKit
import DistavoCore

// "Split Recording…" in the Notes window (D077, D078, task 6668). Finding the split points and doing the split
// are `RecordingSplit` / `RecordingSplitAction` (DistavoCore, tested on synthetic audio); this file locates the
// source audio, runs both off the main actor, holds the scan lock while files change, then queues the halves.
extension WatcherController {

    struct SplitChoices: Sendable {
        var source: URL
        var duration: Double
        /// Silences where the speakers change (`RecordingSplit.candidates`).
        var candidates: [RecordingSplit.Candidate]
        /// Every silence of a minute or more, for a recording without speaker labels to compare.
        var silences: [RecordingSplit.Silence]
    }

    /// Where `entry` could be split, or why not.
    func splitChoices(for entry: NoteEntry) async -> Result<SplitChoices, RecordingSplitAction.Failure> {
        let recordingsDir = Config.resolvePath(config.recordingsDir)
        let work = Config.resolvePath(config.workDir)
        let base = entry.base
        return await Task.detached(priority: .userInitiated) {
            guard let source = ClipExporter.locateSource(base: LanguageOverride.sourceBase(from: base), source: nil,
                                                         recordingsDir: recordingsDir) else { return .failure(.missingSource) }
            guard let scanned = try? RecordingSplit.windowRMS(of: source) else { return .failure(.unreadable) }
            let duration = scanned.duration
            let silences = RecordingSplit.silences(windowRMS: scanned.rms)
            let candidates = RecordingSplit.candidates(silences: silences,
                                                       segments: TranscriptSegments.load(workDir: work, base: base),
                                                       duration: duration)
            return .success(SplitChoices(source: source, duration: duration, candidates: candidates, silences: silences))
        }.value
    }

    /// Cut at `silence`, keep the original and the old note (as its `.prev-` backup), then scan so both halves
    /// are processed. Returns a line for the sheet.
    func splitRecording(_ entry: NoteEntry, choices: SplitChoices, silence: RecordingSplit.Silence) async -> String {
        let recordingsDir = Config.resolvePath(config.recordingsDir)
        let (notes, work) = notesFolders
        var message = ""
        var didSplit = false
        await runExclusivePass(onlyIf: { true }) {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try RecordingSplitAction.perform(source: choices.source, silence: silence,
                                                          duration: choices.duration, recordingsDir: recordingsDir,
                                                          notesDir: notes, workDir: work) }
            }.value
            switch outcome {
            case .success(let o):
                didSplit = true
                message = "Split into \(o.first.lastPathComponent) and \(o.second.lastPathComponent). They are being processed now."
                log("Split \(entry.base) at \(Int(silence.start)) s into \(o.firstBase) and \(o.secondBase)"
                    + (o.noteBackup.map { "; old note kept as \($0.lastPathComponent)" } ?? ""))
            case .failure(let error):
                message = "Not split: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                log("Split \(entry.base) failed: \(message)")
            }
        }
        if didSplit { await scanOnce(.userInitiated) }   // nothing new to process after a failed split
        return message
    }
}
