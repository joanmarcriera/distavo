// VoiceProfiles.swift — remember a named voice, recognise it in later recordings (Vikunja #2944 phase 2).
// Design and privacy analysis: docs/voice-profiles-feasibility.md, docs/voice-profiles-plan.md.
//
// A voice sample here is a speaker embedding: a short list of numbers computed from a person's speech by the
// engine in DistavoEmbedded (`VoiceEmbedder`). It is BIOMETRIC DATA. So:
//   - nothing is computed, stored or matched unless `transcribe.voice_profiles` is on (off for every config
//     predating the key and for fresh installs);
//   - a voice is stored only for a speaker the owner NAMED and ticked "Remember this voice" for;
//   - the store is one file, `voice-profiles.json`, in the Distavo support folder (never in the notes or
//     recordings folders, which may be synced), permissions 0600, deleted when the last profile goes;
//   - notes, sidecars, logs and issue reports carry names only, never samples.
//
// Recognition runs right after transcription and BEFORE the summary (`VoiceRecognition.relabel`), so the
// transcript and the prompt carry the person's name and the model does not guess one for the label.
//
// Matching (`match`): a diarised speaker gets a profile's name only when its best cosine similarity is at least
// `threshold` AND beats the runner-up profile by `margin`; two speakers of one recording never share a profile
// (the better score keeps it, the other stays `SPEAKER_nn`). Up to `maxSamples` samples are kept per person
// because the same voice sounds different through another microphone; the score is the best over them.
// The defaults are conservative guesses, NOT calibrated on real recordings (plan, "Gates for Marc").
//
// Pure apart from `load` / `save`.

import Foundation

public struct VoiceProfile: Codable, Equatable, Sendable {
    public var name: String
    /// L2-normalised embeddings, newest last.
    public var samples: [[Float]]
    /// How many times the owner confirmed this voice (a merged sample counts too).
    public var enrolments: Int
    public var created: Date
    public var updated: Date
}

public struct VoiceMatch: Equatable, Sendable {
    public var name: String
    public var score: Float
    /// Best score of any other profile; -1 when there is no other.
    public var runnerUp: Float
    /// True when the voice was within the margin of another remembered voice and `VoiceTeams` settled it.
    public var byTeam = false
}

public struct VoiceProfileStore: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileName = "voice-profiles.json"
    public static let maxSamples = 5
    /// A new sample this close to a stored one is the same microphone path: averaged in, not appended.
    public static let mergeSimilarity: Float = 0.85
    public static let defaultThreshold: Float = 0.60
    public static let defaultMargin: Float = 0.10
    /// The engine shipped in DistavoEmbedded: WeSpeaker ResNet34 (256-d) through FluidAudio.
    public static let builtInModel = "fluidaudio-wespeaker-v2"

    public var version: Int
    /// The embedding model the samples came from. Samples of another model are never compared.
    public var model: String
    public var profiles: [VoiceProfile]

    public init(model: String, profiles: [VoiceProfile] = []) {
        self.version = Self.currentVersion; self.model = model; self.profiles = profiles
    }

    public static func url(supportDir: URL) -> URL { supportDir.appendingPathComponent(fileName) }
    /// Held around a load-change-save of the voice file by anything that edits it in this process.
    public static let fileLock = NSLock()

    /// The stored profiles for `model`. A missing or unreadable file, a file of a newer Distavo, or one made
    /// with another embedding model is an empty store (its samples would not be comparable).
    public static func load(supportDir: URL, model: String) -> VoiceProfileStore {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(supportDir: supportDir)),
              let store = try? decoder.decode(VoiceProfileStore.self, from: data),
              store.version <= currentVersion, store.model == model else { return VoiceProfileStore(model: model) }
        return store
    }

    /// Whether a file made with ANOTHER model (or a newer Distavo) is on disk: saving would replace it.
    public static func hasIncompatibleFile(supportDir: URL, model: String) -> Bool {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(supportDir: supportDir)) else { return false }
        guard let store = try? decoder.decode(VoiceProfileStore.self, from: data) else { return true }
        return store.version > currentVersion || store.model != model
    }

    /// Writes the file atomically; it is 0600 from its first byte (created private, then renamed into place),
    /// never readable by another account even for a moment. Removes it when no profile is left.
    public func save(supportDir: URL) throws {
        let fm = FileManager.default
        let target = Self.url(supportDir: supportDir)
        guard !profiles.isEmpty else {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            return
        }
        try Self.writePrivate(try fileData(), to: target)
    }

    /// The bytes `save` writes (stable: sorted keys), so a caller can tell whether the file changed since.
    public func fileData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Writes `data` atomically as a file that is 0600 from its first byte.
    static func writePrivate(_ data: Data, to target: URL) throws {
        let fm = FileManager.default
        let dir = target.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard Darwin.rename(temp.path, target.path) == 0 else {
            try? fm.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public var names: [String] { profiles.map(\.name) }

    // MARK: Enrol / delete

    /// Adds a confirmed sample of `name`'s voice. Returns false (and changes nothing) for an unusable sample.
    @discardableResult
    public mutating func enrol(name rawName: String, sample: [Float], now: Date = Date()) -> Bool {
        // Composed form (é as one character), as SpeakerRename writes names into the notes.
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, let unit = Self.normalised(sample) else { return false }
        guard let i = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            profiles.append(VoiceProfile(name: name, samples: [unit], enrolments: 1, created: now, updated: now))
            return true
        }
        guard profiles[i].samples.first?.count == unit.count else { return false }
        var best = -1, bestScore: Float = -1
        for (j, s) in profiles[i].samples.enumerated() {
            let score = Self.cosine(s, unit)
            if score > bestScore { best = j; bestScore = score }
        }
        if best >= 0, bestScore >= Self.mergeSimilarity {
            // Same microphone path: running mean, weighted towards what is already known.
            let old = profiles[i].samples[best]
            let mixed = zip(old, unit).map { $0 * 0.7 + $1 * 0.3 }
            profiles[i].samples[best] = Self.normalised(mixed) ?? old
        } else {
            profiles[i].samples.append(unit)
            if profiles[i].samples.count > Self.maxSamples { profiles[i].samples.removeFirst() }
        }
        profiles[i].enrolments += 1
        profiles[i].updated = now
        return true
    }

    @discardableResult
    public mutating func delete(name: String) -> Bool {
        let before = profiles.count
        profiles.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return profiles.count != before
    }

    public mutating func deleteAll() { profiles.removeAll() }

    public enum RenameOutcome: Equatable, Sendable { case renamed, merged, unchanged }

    /// Gives the remembered voice `name` another name. When a voice of that name is already remembered the two
    /// become one person (how two voices are merged): the samples of both are kept, the newest when there are
    /// more than `maxSamples`. `.unchanged`: no such voice, an empty or label-like new name, or the same voice.
    /// Notes are not touched: they keep the names they have.
    @discardableResult
    public mutating func rename(name: String, to rawNew: String, now: Date = Date()) -> RenameOutcome {
        let new = rawNew.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !new.isEmpty, !VoiceRecognition.isLabel(new),
              let i = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return .unchanged }
        guard let j = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(new) == .orderedSame }), j != i else {
            guard profiles[i].name != new else { return .unchanged }
            profiles[i].name = new   // also a change of capitals or spelling of the same voice
            profiles[i].updated = now
            return .renamed
        }
        guard profiles[i].samples.first?.count == profiles[j].samples.first?.count else { return .unchanged }
        // The more recently updated voice's samples go last, so they are the ones kept over the limit.
        let targetIsNewer = profiles[j].updated > profiles[i].updated
        let ordered = targetIsNewer ? profiles[i].samples + profiles[j].samples : profiles[j].samples + profiles[i].samples
        profiles[j].samples = Array(ordered.suffix(Self.maxSamples))
        profiles[j].enrolments += profiles[i].enrolments
        profiles[j].created = min(profiles[j].created, profiles[i].created)
        profiles[j].updated = now
        profiles.remove(at: i)
        return .merged
    }

    // MARK: Match

    /// Speaker label -> the profile it is, for the speakers that clear the threshold and the margin.
    /// With `team`, a speaker that clears the threshold but not the margin is settled by who usually meets
    /// with the speakers matched on voice alone (see VoiceTeams.swift); without it nothing changes.
    public func match(speakers: [String: [Float]], threshold: Float = VoiceProfileStore.defaultThreshold,
                      margin: Float = VoiceProfileStore.defaultMargin, team: VoiceTeams? = nil) -> [String: VoiceMatch] {
        var candidates: [(label: String, profile: Int, match: VoiceMatch)] = []
        var close: [(label: String, scores: [Float])] = []   // over the threshold, inside the margin
        for label in speakers.keys.sorted() {
            guard let unit = Self.normalised(speakers[label]!) else { continue }
            var best = -1, bestScore: Float = -1, second: Float = -1
            for (i, p) in profiles.enumerated() {
                let score = p.samples.filter { $0.count == unit.count }.map { Self.cosine($0, unit) }.max() ?? -1
                if score > bestScore { second = bestScore; bestScore = score; best = i }
                else if score > second { second = score }
            }
            guard best >= 0, bestScore >= threshold else { continue }
            guard bestScore - second >= margin else {
                close.append((label, profiles.map { p in
                    p.samples.filter { $0.count == unit.count }.map { Self.cosine($0, unit) }.max() ?? -1 }))
                continue
            }
            candidates.append((label, best, VoiceMatch(name: profiles[best].name, score: bestScore, runnerUp: second)))
        }
        var out: [String: VoiceMatch] = [:], taken = Set<Int>()
        for c in candidates.sorted(by: { $0.match.score != $1.match.score ? $0.match.score > $1.match.score : $0.label < $1.label })
        where !taken.contains(c.profile) {
            taken.insert(c.profile)
            out[c.label] = c.match
        }
        guard let team, !close.isEmpty else { return out }
        let context = out.values.map(\.name)
        for c in close {
            guard let top = c.scores.max() else { continue }
            // Rivals: the remembered voices this one is too close to choose between. One under the threshold
            // could never be given the name, so it does not compete.
            let rivals = c.scores.indices.filter { top - c.scores[$0] < margin && c.scores[$0] >= threshold }
            // A rival already given to another speaker means this voice is unclear: leave it unnamed.
            guard !rivals.contains(where: taken.contains),
                  let name = team.pick(among: rivals.map { profiles[$0].name }, with: context),
                  let i = rivals.first(where: { profiles[$0].name == name }), c.scores[i] >= threshold else { continue }
            taken.insert(i)
            out[c.label] = VoiceMatch(name: name, score: c.scores[i],
                                      runnerUp: rivals.filter { $0 != i }.map { c.scores[$0] }.max() ?? -1, byTeam: true)
        }
        return out
    }

    // MARK: Vectors

    static func normalised(_ v: [Float]) -> [Float]? {
        guard !v.isEmpty, v.allSatisfy({ $0.isFinite }) else { return nil }
        // Scale by the largest component first: squaring a huge value overflows to infinity and the vector
        // would come out all zero.
        let peak = v.map(abs).max() ?? 0
        guard peak > 1e-12 else { return nil }
        let scaled = v.map { $0 / peak }
        let norm = scaled.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-6, norm.isFinite else { return nil }
        return scaled.map { $0 / norm }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        return zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    }
}

/// Which stretches of a recording to take a speaker's voice sample from: their longest turns, away from the
/// turn edges (where the next speaker may overlap). Pure.
public enum VoiceSampler {
    public static let maxSeconds = 30.0
    public static let minTurnSeconds = 2.5
    public static let minTotalSeconds = 8.0
    static let edge = 0.3

    /// Speaker -> time ranges (seconds, in recording order). A speaker with less than `minTotalSeconds` of
    /// usable speech is left out: a short sample would be a bad voiceprint.
    public static func ranges(for segments: [TranscriptSegments.Segment], only speakers: Set<String>? = nil,
                              maxSeconds: Double = maxSeconds) -> [String: [ClosedRange<Double>]] {
        var turns: [String: [ClosedRange<Double>]] = [:]
        for s in segments {
            guard let speaker = s.speaker, !speaker.isEmpty, speakers?.contains(speaker) ?? true else { continue }
            let start = s.start + edge, end = s.end - edge
            guard end - start >= minTurnSeconds - 2 * edge - 1e-9, start >= 0 else { continue }   // 1e-9: a turn of exactly the minimum
            turns[speaker, default: []].append(start...end)
        }
        var out: [String: [ClosedRange<Double>]] = [:]
        for (speaker, list) in turns {
            var total = 0.0, picked: [ClosedRange<Double>] = []
            for r in list.sorted(by: { ($0.upperBound - $0.lowerBound) > ($1.upperBound - $1.lowerBound) }) {
                guard total < maxSeconds else { break }
                let take = min(r.upperBound - r.lowerBound, maxSeconds - total)
                picked.append(r.lowerBound...(r.lowerBound + take))
                total += take
            }
            guard total >= minTotalSeconds else { continue }
            out[speaker] = picked.sorted { $0.lowerBound < $1.lowerBound }
        }
        return out
    }
}

/// The pipeline and rename steps of voice profiles, on top of the store. `embed` is the engine seam.
public enum VoiceRecognition {
    public typealias Embed = (_ audio: URL, _ ranges: [String: [ClosedRange<Double>]]) async -> [String: [Float]]

    static let labelPattern = #"^SPEAKER_\d{1,3}$"#
    static func isLabel(_ s: String) -> Bool { s.range(of: labelPattern, options: .regularExpression) != nil }

    /// Right after transcription: give each diarised speaker whose voice is known that person's name, in the
    /// engine result itself (every "speaker" value, segments and words). Returns the result unchanged and no
    /// names when nothing is stored (the engine is then not even asked), nothing matched, or a match would
    /// give two speakers of this recording the same name.
    public static func relabel(result: [String: Any], audio: URL, supportDir: URL, model: String,
                               team: VoiceTeams? = nil,
                               embed: Embed) async -> (result: [String: Any], names: [String: VoiceMatch]) {
        let store = VoiceProfileStore.load(supportDir: supportDir, model: model)
        guard !store.profiles.isEmpty, let timed = TranscriptSegments(whisperXResult: result) else { return (result, [:]) }
        let present = Set(timed.segments.compactMap(\.speaker))
        let ranges = VoiceSampler.ranges(for: timed.segments, only: present.filter(isLabel))
        guard !ranges.isEmpty else { return (result, [:]) }
        var matches = store.match(speakers: await embed(audio, ranges), team: team)
        matches = matches.filter { m in !present.contains { $0.caseInsensitiveCompare(m.value.name) == .orderedSame } }
        guard !matches.isEmpty else { return (result, [:]) }
        let names = matches.mapValues(\.name)
        func renamed(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                var out = dict
                for (k, v) in dict {
                    if k == "speaker", let label = v as? String, let name = names[label] { out[k] = name }
                    else if v is [String: Any] || v is [Any] { out[k] = renamed(v) }
                }
                return out
            }
            if let list = value as? [Any] { return list.map(renamed) }
            return value
        }
        return ((renamed(result) as? [String: Any]) ?? result, matches)
    }

    /// Whether a remembered name is the note owner: the same name, with or without a trailing "(me)".
    public static func isOwner(_ name: String, noteOwner: String) -> Bool {
        func plain(_ s: String) -> String {
            let edges = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".,;"))
            var t = s.trimmingCharacters(in: edges)
            if t.lowercased().hasSuffix("(me)") { t = String(t.dropLast(4)).trimmingCharacters(in: edges) }
            return t.lowercased()
        }
        let owner = plain(noteOwner)
        return !owner.isEmpty && owner != "me" && plain(name) == owner
    }

    /// The footer line of a note whose speakers were named by voice; nil when none were.
    /// `byTeam`: the ones whose voice was close to another and who were settled by who they usually meet with.
    public static func footerNote(names: [String], byTeam: [String] = []) -> String? {
        guard !names.isEmpty else { return nil }
        let team = Set(byTeam)
        return "Speakers named from remembered voices: "
            + names.sorted().map { team.contains($0) ? $0 + " (close to another voice; chosen by who they usually meet with)" : $0 }
                .joined(separator: ", ")
            + " (Rename Speakers can change or reset them)."
    }

    /// After the owner renamed speakers and ticked "Remember this voice": store a sample for each of `names`
    /// (the names as they now stand in the timed transcript). Returns the names actually stored.
    public static func remember(names: [String], base: String, audio: URL, workDir: URL, supportDir: URL,
                                model: String, embed: Embed, now: Date = Date()) async throws -> [String] {
        let wanted = Set(names.filter { !isLabel($0) })
        guard !wanted.isEmpty, let timed = TranscriptSegments.load(workDir: workDir, base: base) else { return [] }
        let ranges = VoiceSampler.ranges(for: timed.segments, only: wanted)
        guard !ranges.isEmpty else { return [] }
        // A file from another voice model or a newer Distavo reads as empty: saving would wipe it. Leave it.
        guard !VoiceProfileStore.hasIncompatibleFile(supportDir: supportDir, model: model) else { return [] }
        let samples = await embed(audio, ranges)
        // Load, change and save in one turn: Settings may rename or delete a voice at the same moment.
        let stored: [String] = try VoiceProfileStore.fileLock.withLock {
            var store = VoiceProfileStore.load(supportDir: supportDir, model: model)
            var stored: [String] = []
            for name in samples.keys.sorted() where store.enrol(name: name, sample: samples[name]!, now: now) {
                stored.append(name)
            }
            if !stored.isEmpty { try store.save(supportDir: supportDir) }
            return stored
        }
        // Remembering a voice under a name is the owner saying the name is right: it is no longer a guess.
        _ = try? SpeakerNames.confirmVoiceNames(stored, workDir: workDir, base: base)
        return stored
    }
}
