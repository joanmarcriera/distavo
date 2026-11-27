// VoiceCatalog.swift — "Review Voices": check, correct, merge and separate the voices Distavo remembers.
// Part of voice profiles (#2944 phase 2; rules in VoiceProfiles.swift, plan in docs/voice-profiles-plan.md).
//
// What the owner sees (the Voices window, opened from Settings > Transcription):
//   - every remembered voice (`VoiceProfileStore`) with a clip from each of the person's most recent meetings
//     (`people`), the ones Distavo named by voice and nobody confirmed marked as such;
//   - the unnamed speakers who talked for a minute or more in a meeting (`unnamed`), each with a clip.
// A clip is a stretch of the RECORDING, found through `.segments.json` and played from the file: nothing is
// cut out, copied or stored. A meeting whose recording is gone still shows what was said.
//
// What the owner can do:
//   - "That is them": `SpeakerNames.confirmVoiceNames` (the name stops being a guess).
//   - "Not this person" on one or several meetings (`separate`): the speaker of those meetings goes back to
//     its `SPEAKER_nn` label, or gets the name the owner types; every sample of the profile that was learnt
//     from one of those voices (cosine >= `VoiceProfileStore.mergeSimilarity` to that meeting's speaker) leaves
//     the profile; with a name and "remember" those voices are remembered under the new name. This is also how
//     a voice that holds two people is separated. NO voiceprint is kept of a voice the owner did not name.
//   - "Merge / rename" (`merge`): the remembered voice becomes another name (`VoiceProfileStore.rename`).
//   - Both take `renameNotes`: whether the meetings follow. They are rewritten only by `SpeakerRename.apply`
//     (backup kept), and a meeting where the rename would merge two speakers is left alone and reported.
//   - "Undo" (`undo`): one level. The record (`voice-review-undo.json`, support folder, 0600) holds the voice
//     file as it was and the renames done. It is written BEFORE anything changes; an operation that fails
//     half-way puts the meetings, the voice file and the previous undo record back. Undo is refused, and
//     changes nothing, when the voice file changed since. Deleting a voice in Settings discards the record.
//
// Pure apart from the file reads and writes named above. Names only in logs: the app logs counts.

import Foundation
import CryptoKit

public enum VoiceCatalog {
    /// Clips shown per remembered voice: one per meeting, the most recent meetings.
    public static let clipLimit = 5
    /// An unnamed speaker with this much talk in a meeting is always listed.
    public static let longTalkSeconds = VoiceReview.afterMeetingMinSeconds
    public static let undoFileName = "voice-review-undo.json"

    // MARK: Listing

    public struct Meeting: Equatable, Sendable {
        public var base: String
        public var title: String
        public var date: Date
        public init(base: String, title: String, date: Date) { self.base = base; self.title = title; self.date = date }
    }

    /// One speaker of one meeting, with the stretch to play.
    public struct Clip: Equatable, Sendable, Identifiable {
        public var base: String
        /// The speaker as written in that meeting's timed transcript (a name, or `SPEAKER_nn`).
        public var speaker: String
        public var title: String
        public var date: Date
        public var start: Double
        public var end: Double
        public var quote: String
        /// How long this speaker talked in the meeting.
        public var talkSeconds: Double
        /// Named by voice recognition and not confirmed by the owner.
        public var guessed: Bool
        public var id: String { base + "|" + speaker }
    }

    public struct Person: Equatable, Sendable, Identifiable {
        public var name: String
        public var samples: Int
        public var updated: Date
        /// Every meeting a speaker carries this name in, newest first.
        public var bases: [String]
        /// How many of them were named by voice and not confirmed.
        public var guessed: Int
        /// The most recent meetings, one clip each.
        public var clips: [Clip]
        public var id: String { name.lowercased() }
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.precomposedStringWithCanonicalMapping.caseInsensitiveCompare(b.precomposedStringWithCanonicalMapping) == .orderedSame
    }

    /// The clip of `speaker` in a timed transcript: their longest turn, at most `VoiceReview.sampleSeconds`.
    static func clip(of speaker: String, in timed: TranscriptSegments, meeting: Meeting, guessed: Bool) -> Clip? {
        let turns = timed.segments.filter { $0.speaker == speaker && $0.end > $0.start }
        guard let longest = turns.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else { return nil }
        let text = longest.text.split(separator: " ").joined(separator: " ")
        return Clip(base: meeting.base, speaker: speaker, title: meeting.title, date: meeting.date,
                    start: longest.start, end: min(longest.end, longest.start + VoiceReview.sampleSeconds),
                    quote: text.count > 160 ? String(text.prefix(157)) + "…" : text,
                    talkSeconds: turns.reduce(0) { $0 + ($1.end - $1.start) }, guessed: guessed)
    }

    private static func newestFirst(_ meetings: [Meeting]) -> [Meeting] {
        meetings.sorted { $0.date != $1.date ? $0.date > $1.date : $0.base < $1.base }
    }

    /// Every remembered voice with its meetings: most meetings first, then by name.
    public static func people(store: VoiceProfileStore, meetings: [Meeting], workDir: URL,
                              clipLimit: Int = clipLimit) -> [Person] {
        var out = store.profiles.map {
            Person(name: $0.name, samples: $0.samples.count, updated: $0.updated, bases: [], guessed: 0, clips: [])
        }
        guard !out.isEmpty else { return [] }
        for m in newestFirst(meetings) {
            guard let timed = TranscriptSegments.load(workDir: workDir, base: m.base) else { continue }
            let speakers = Set(timed.segments.compactMap(\.speaker))
            let guesses = SpeakerNames.voiceGuesses(workDir: workDir, base: m.base)
            for i in out.indices {
                guard let speaker = speakers.sorted().first(where: { same($0, out[i].name) }) else { continue }
                let guessed = guesses.contains(speaker)
                out[i].bases.append(m.base)
                if guessed { out[i].guessed += 1 }
                if out[i].clips.count < clipLimit, let c = clip(of: speaker, in: timed, meeting: m, guessed: guessed) {
                    out[i].clips.append(c)
                }
            }
        }
        return out.sorted { $0.bases.count != $1.bases.count ? $0.bases.count > $1.bases.count : $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The unnamed speakers who talked for `minSeconds` or more in a meeting, newest meeting first, the one
    /// who talked most first within a meeting. No voice model is needed for this list.
    public static func unnamed(meetings: [Meeting], workDir: URL, minSeconds: Double = longTalkSeconds) -> [Clip] {
        var out: [Clip] = []
        for m in newestFirst(meetings) {
            guard let timed = TranscriptSegments.load(workDir: workDir, base: m.base) else { continue }
            let labels = Set(timed.segments.compactMap(\.speaker).filter(VoiceRecognition.isLabel))
            out += labels.compactMap { clip(of: $0, in: timed, meeting: m, guessed: false) }
                .filter { $0.talkSeconds >= minSeconds }
                .sorted { $0.talkSeconds != $1.talkSeconds ? $0.talkSeconds > $1.talkSeconds : $0.speaker < $1.speaker }
        }
        return out
    }

    /// Where to take the voice sample of `name` from in one meeting (the engine is asked with this); nil when
    /// nobody of that name speaks there or there is too little clear speech.
    public static func sampleRanges(name: String, base: String, workDir: URL) -> (speaker: String, ranges: [ClosedRange<Double>])? {
        guard let timed = TranscriptSegments.load(workDir: workDir, base: base),
              let speaker = Set(timed.segments.compactMap(\.speaker)).sorted().first(where: { same($0, name) }),
              let ranges = VoiceSampler.ranges(for: timed.segments, only: [speaker])[speaker] else { return nil }
        return (speaker, ranges)
    }

    // MARK: Operations

    public struct Rename: Codable, Equatable, Sendable {
        public var base: String
        public var from: String
        public var to: String
        /// `from` was a voice guess the owner had not confirmed (an undo makes it a guess again).
        public var wasGuess: Bool
    }

    public struct UndoRecord: Codable, Equatable, Sendable {
        public static let currentVersion = 1
        public var version: Int
        public var date: Date
        /// What was done, in the owner's words ("Merged 2 voices"); never a sample.
        public var summary: String
        public var storeBefore: VoiceProfileStore
        /// SHA-256 of the voice file right after the operation ("" = no file).
        public var storeAfterSHA256: String
        public var renames: [Rename]
    }

    public struct Outcome: Equatable, Sendable {
        /// Meetings whose speaker was renamed.
        public var renamed: [String] = []
        /// Meetings left alone, with the reason.
        public var skipped: [String: String] = [:]
        public var samplesRemoved = 0
        /// The voice had no sample left and is no longer remembered.
        public var voiceForgotten = false
        public var remembered = false
        public var merged = false
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case noSuchVoice, incompatibleFile, invalidName, sameName, nothingToDo, nothingToUndo, changedSince
        case renameFailed(String)
        public var errorDescription: String? {
            switch self {
            case .noSuchVoice: return "That voice is no longer remembered."
            case .incompatibleFile: return "The voice file was made by another version of Distavo and was left untouched."
            case .invalidName: return "That is not a name a voice can have."
            case .sameName: return "That is the name the voice already has."
            case .nothingToDo: return "Nothing to change."
            case .nothingToUndo: return "There is nothing to undo."
            case .changedSince: return "The remembered voices changed since, so this can no longer be undone. Nothing was changed."
            case .renameFailed(let why): return "A meeting could not be rewritten, so nothing was changed (\(why))."
            }
        }
    }

    public typealias RenameSeam = (_ mapping: [String: String], _ base: String) throws -> Void
    public typealias SaveSeam = (_ store: VoiceProfileStore) throws -> Void

    public struct Context {
        public var notesDir: URL
        public var workDir: URL
        public var supportDir: URL
        public var model: String
        public var now: Date
        /// Test seams: fail a rename or the save half-way.
        public var rename: RenameSeam
        public var save: SaveSeam
        public init(notesDir: URL, workDir: URL, supportDir: URL, model: String, now: Date = Date(),
                    rename: RenameSeam? = nil, save: SaveSeam? = nil) {
            self.notesDir = notesDir; self.workDir = workDir; self.supportDir = supportDir; self.model = model; self.now = now
            self.rename = rename ?? { mapping, base in
                _ = try SpeakerRename.apply(mapping: mapping, base: base, notesDir: notesDir, workDir: workDir, now: now)
            }
            self.save = save ?? { try $0.save(supportDir: supportDir) }
        }
    }

    static func cleanName(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    /// "Not this person": in `bases` the speaker called `name` is somebody else. See the header.
    /// `embeddings`: the voice sample of that speaker per meeting (from the engine; a meeting without one only
    /// has its name corrected). `to` empty = nobody the owner can name: back to a `SPEAKER_nn` label.
    public static func separate(name: String, meetings bases: [String], embeddings: [String: [Float]],
                                to rawNew: String?, remember: Bool, renameNotes: Bool, context c: Context) throws -> Outcome {
        let new = cleanName(rawNew)
        guard new.isEmpty || !VoiceRecognition.isLabel(new) else { throw Failure.invalidName }
        guard new.isEmpty || !same(new, name) else { throw Failure.sameName }
        guard !VoiceProfileStore.hasIncompatibleFile(supportDir: c.supportDir, model: c.model) else { throw Failure.incompatibleFile }
        return try VoiceProfileStore.fileLock.withLock {
            let before = VoiceProfileStore.load(supportDir: c.supportDir, model: c.model)
            guard let i = before.profiles.firstIndex(where: { same($0.name, name) }) else { throw Failure.noSuchVoice }
            var out = Outcome(), renames: [Rename] = []
            if renameNotes {
                for base in bases {
                    guard let timed = TranscriptSegments.load(workDir: c.workDir, base: base) else {
                        out.skipped[base] = "no timed transcript"; continue
                    }
                    let speakers = Set(timed.segments.compactMap(\.speaker))
                    guard let speaker = speakers.sorted().first(where: { same($0, name) }) else {
                        out.skipped[base] = "nobody of that name speaks there any more"; continue
                    }
                    let tracked = SpeakerNames.load(workDir: c.workDir, base: base)?.names ?? [:]
                    var target = new
                    if target.isEmpty {
                        // Back to the diariser's own label when the name came from exactly one; else a fresh one.
                        let originals = tracked.filter { $0.value == speaker && VoiceRecognition.isLabel($0.key) }.map(\.key)
                        target = originals.count == 1 && !speakers.contains(originals[0]) ? originals[0]
                            : TranscriptEditing.newSpeakerLabel(in: timed, alsoUsed: Set(tracked.keys))
                    } else if speakers.contains(where: { same($0, target) }) {
                        out.skipped[base] = "already has a speaker called \(target)"; continue
                    }
                    renames.append(Rename(base: base, from: speaker, to: target,
                                          wasGuess: SpeakerNames.voiceGuesses(workDir: c.workDir, base: base).contains(speaker)))
                }
            }
            var after = before
            let wrong = bases.sorted().compactMap { embeddings[$0] }.compactMap(VoiceProfileStore.normalised)
            let kept = after.profiles[i].samples.filter { s in
                !wrong.contains { $0.count == s.count && VoiceProfileStore.cosine($0, s) >= VoiceProfileStore.mergeSimilarity }
            }
            out.samplesRemoved = after.profiles[i].samples.count - kept.count
            if kept.isEmpty { after.profiles.remove(at: i); out.voiceForgotten = true }
            else if out.samplesRemoved > 0 { after.profiles[i].samples = kept; after.profiles[i].updated = c.now }
            if !new.isEmpty, remember {
                for sample in wrong where after.enrol(name: new, sample: sample, now: c.now) { out.remembered = true }
            }
            guard !renames.isEmpty || after != before else { throw Failure.nothingToDo }
            try commit(before: before, after: after, renames: renames,
                       summary: new.isEmpty ? "Took \(bases.count) meeting\(bases.count == 1 ? "" : "s") away from a voice"
                                            : "Separated a voice in two", context: c)
            out.renamed = renames.map(\.base)
            return out
        }
    }

    /// The remembered voice `name` becomes `into`: one person when `into` is remembered too, else a new name.
    /// With `renameNotes` the speaker follows in every meeting of `bases` it speaks in, except a meeting where
    /// `into` speaks too (the rename would merge two speakers there; Rename Speakers does that on purpose).
    public static func merge(name: String, into rawNew: String, renameNotes: Bool, meetings bases: [String],
                             context c: Context) throws -> Outcome {
        let new = cleanName(rawNew)
        guard !new.isEmpty, !VoiceRecognition.isLabel(new) else { throw Failure.invalidName }
        guard !VoiceProfileStore.hasIncompatibleFile(supportDir: c.supportDir, model: c.model) else { throw Failure.incompatibleFile }
        return try VoiceProfileStore.fileLock.withLock {
            let before = VoiceProfileStore.load(supportDir: c.supportDir, model: c.model)
            guard before.profiles.contains(where: { same($0.name, name) }) else { throw Failure.noSuchVoice }
            var after = before, out = Outcome()
            let result = after.rename(name: name, to: new, now: c.now)
            out.merged = result == .merged
            var renames: [Rename] = []
            if renameNotes {
                for base in bases {
                    guard let timed = TranscriptSegments.load(workDir: c.workDir, base: base) else { continue }
                    let speakers = Set(timed.segments.compactMap(\.speaker))
                    guard let speaker = speakers.sorted().first(where: { same($0, name) }), speaker != new else { continue }
                    if speakers.contains(where: { $0 != speaker && same($0, new) }) {
                        out.skipped[base] = "both names speak in that meeting"; continue
                    }
                    renames.append(Rename(base: base, from: speaker, to: new,
                                          wasGuess: SpeakerNames.voiceGuesses(workDir: c.workDir, base: base).contains(speaker)))
                }
            }
            guard result != .unchanged || !renames.isEmpty else { throw same(name, new) ? Failure.sameName : Failure.nothingToDo }
            try commit(before: before, after: after, renames: renames,
                       summary: out.merged ? "Merged two voices" : "Renamed a voice", context: c)
            out.renamed = renames.map(\.base)
            return out
        }
    }

    // MARK: Undo

    public static func undoURL(supportDir: URL) -> URL { supportDir.appendingPathComponent(undoFileName) }

    static func sha256(ofFile url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func loadUndo(supportDir: URL) -> UndoRecord? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: undoURL(supportDir: supportDir)),
              let r = try? decoder.decode(UndoRecord.self, from: data), r.version <= UndoRecord.currentVersion else { return nil }
        return r
    }

    /// What "Undo" would undo, if it still can. A record that can no longer be used (the voice file changed
    /// since) is removed here: it holds voice samples and must not outlive its use.
    public static func pendingUndo(supportDir: URL) -> (summary: String, date: Date)? {
        VoiceProfileStore.fileLock.withLock {
            guard let r = loadUndo(supportDir: supportDir) else {
                try? FileManager.default.removeItem(at: undoURL(supportDir: supportDir))
                return nil
            }
            guard r.storeAfterSHA256 == sha256(ofFile: VoiceProfileStore.url(supportDir: supportDir)) else {
                try? FileManager.default.removeItem(at: undoURL(supportDir: supportDir))
                return nil
            }
            return (r.summary, r.date)
        }
    }

    /// Removes the undo record (a voice was deleted in Settings: its samples must not stay in the record).
    public static func discardUndo(supportDir: URL) {
        try? FileManager.default.removeItem(at: undoURL(supportDir: supportDir))
    }

    /// Puts back what the last `separate` or `merge` changed: the voice file, and the speaker names of the
    /// meetings it renamed (a meeting the owner renamed again meanwhile is left alone and reported).
    public static func undo(context c: Context) throws -> Outcome {
        try VoiceProfileStore.fileLock.withLock {
            guard let record = loadUndo(supportDir: c.supportDir) else { throw Failure.nothingToUndo }
            guard record.storeAfterSHA256 == sha256(ofFile: VoiceProfileStore.url(supportDir: c.supportDir)),
                  record.storeBefore.model == c.model else { throw Failure.changedSince }
            var out = Outcome(), back: [Rename] = []
            for r in record.renames {
                let speakers = Set(TranscriptSegments.load(workDir: c.workDir, base: r.base)?.segments.compactMap(\.speaker) ?? [])
                guard speakers.contains(r.to), !speakers.contains(r.from) else {
                    out.skipped[r.base] = "the speakers of that meeting were renamed since"; continue
                }
                back.append(Rename(base: r.base, from: r.to, to: r.from, wasGuess: false))
            }
            try run(back, context: c)
            do { try c.save(record.storeBefore) } catch {
                revert(back, context: c)
                throw error
            }
            // A name that was a voice guess before is a guess again, not an owner-confirmed name.
            for r in record.renames where r.wasGuess && back.contains(where: { $0.base == r.base }) {
                guard var names = SpeakerNames.load(workDir: c.workDir, base: r.base), names.names.values.contains(r.from) else { continue }
                names.byVoice = Array(Set((names.byVoice ?? []) + [r.from])).sorted()
                try? names.encoded().write(to: SpeakerNames.url(workDir: c.workDir, base: r.base), options: .atomic)
            }
            discardUndo(supportDir: c.supportDir)
            out.renamed = back.map(\.base)
            return out
        }
    }

    // MARK: Commit

    /// Renames in order; on a failure the ones already done are put back and `renameFailed` is thrown.
    private static func run(_ renames: [Rename], context c: Context) throws {
        var done: [Rename] = []
        for r in renames {
            do { try c.rename([r.from: r.to], r.base); done.append(r) } catch {
                revert(done, context: c)
                throw Failure.renameFailed((error as? LocalizedError)?.errorDescription ?? "\(type(of: error))")
            }
        }
    }

    private static func revert(_ done: [Rename], context c: Context) {
        for r in done.reversed() { try? c.rename([r.to: r.from], r.base) }
    }

    /// Undo record first, then the meetings, then the voice file. Any failure leaves all three as they were.
    private static func commit(before: VoiceProfileStore, after: VoiceProfileStore, renames: [Rename],
                               summary: String, context c: Context) throws {
        let undoFile = undoURL(supportDir: c.supportDir)
        let previousUndo = try? Data(contentsOf: undoFile)
        func restoreUndo() {
            if let previousUndo { try? VoiceProfileStore.writePrivate(previousUndo, to: undoFile) }
            else { try? FileManager.default.removeItem(at: undoFile) }
        }
        let afterSHA = after.profiles.isEmpty ? ""
            : SHA256.hash(data: try after.fileData()).map { String(format: "%02x", $0) }.joined()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try VoiceProfileStore.writePrivate(try encoder.encode(UndoRecord(
            version: UndoRecord.currentVersion, date: c.now, summary: summary, storeBefore: before,
            storeAfterSHA256: afterSHA, renames: renames)), to: undoFile)
        do { try run(renames, context: c) } catch { restoreUndo(); throw error }
        guard after != before else { return }
        do { try c.save(after) } catch {
            revert(renames, context: c)
            restoreUndo()
            throw error
        }
    }
}
