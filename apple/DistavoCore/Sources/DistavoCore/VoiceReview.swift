// VoiceReview.swift — "Name Voices": the unnamed voices of past recordings, grouped across meetings, each
// with a stretch to listen to, so the owner names a person once and every meeting they spoke in follows.
// Part of voice profiles (#2944 phase 2; rules in VoiceProfiles.swift). Pure apart from `apply`.
//
// The app computes one voice sample per still-unnamed speaker (`SPEAKER_nn`) of each note whose recording is
// still there (`candidates` says which stretches; the engine is `VoiceEmbedder`). Those samples live only in
// memory while the window is open. `group` puts the same voice of different meetings together (two speakers
// of ONE meeting are never the same voice) and proposes a name when the voice is already remembered.
// `apply` is what naming a voice does: an ordinary rename in every meeting of that voice (backup kept,
// undoable from Rename Speakers) and, when asked, the samples go into the voice profile store.
// Nothing is stored for a voice the owner does not name.

import Foundation

public enum VoiceReview {
    public static let sampleSeconds = 12.0

    /// One unnamed speaker of one meeting.
    public struct Occurrence: Equatable, Sendable, Identifiable {
        public var base: String
        public var label: String
        public var title: String
        public var date: Date
        /// The stretch to play: this speaker's longest turn, at most `sampleSeconds`.
        public var sampleStart: Double
        public var sampleEnd: Double
        /// What they say in that stretch (shown beside the play button, never stored anywhere new).
        public var quote: String
        public var embedding: [Float]
        /// What this speaker called themself early in that meeting (`SelfIntroductions`); a suggestion only.
        public var introduction: SelfIntroductions.Introduction?
        public var id: String { base + "|" + label }

        public init(base: String, label: String, title: String, date: Date, sampleStart: Double, sampleEnd: Double,
                    quote: String, embedding: [Float], introduction: SelfIntroductions.Introduction? = nil) {
            self.introduction = introduction
            self.base = base; self.label = label; self.title = title; self.date = date
            self.sampleStart = sampleStart; self.sampleEnd = sampleEnd; self.quote = quote; self.embedding = embedding
        }
    }

    /// One voice: the same person in one or more meetings (newest meeting first).
    public struct Voice: Equatable, Sendable, Identifiable {
        public var id: Int
        public var occurrences: [Occurrence]
        /// The remembered voice this already matches, if any.
        public var suggestedName: String?
        public var meetings: Int { occurrences.count }
        public init(id: Int, occurrences: [Occurrence], suggestedName: String?) {
            self.id = id; self.occurrences = occurrences; self.suggestedName = suggestedName
        }
        /// What this voice introduced itself as: the name said in most of its meetings (newest wins a tie),
        /// with the organisation said alongside it, if any.
        public var introduction: SelfIntroductions.Introduction? {
            let said = occurrences.compactMap(\.introduction)
            var count: [String: Int] = [:]
            for i in said { count[i.name.lowercased(), default: 0] += 1 }
            guard let top = count.values.max(), let pick = said.first(where: { count[$0.name.lowercased()] == top })
            else { return nil }
            let org = said.first { $0.name.lowercased() == pick.name.lowercased() && $0.organisation != nil }?.organisation
            return .init(name: pick.name, organisation: org)
        }
    }

    public struct Candidate: Equatable, Sendable {
        public var label: String
        public var ranges: [ClosedRange<Double>]
        public var sampleStart: Double
        public var sampleEnd: Double
        public var quote: String
        public var introduction: SelfIntroductions.Introduction?
    }

    /// The still-unnamed speakers of a timed transcript that have enough clear speech for a sample.
    public static func candidates(in timed: TranscriptSegments) -> [Candidate] {
        let labels = Set(timed.segments.compactMap(\.speaker).filter(VoiceRecognition.isLabel))
        let ranges = VoiceSampler.ranges(for: timed.segments, only: labels)
        let introductions = SelfIntroductions.bySpeaker(timed.segments)
        return ranges.keys.sorted().compactMap { label in
            let turns = timed.segments.filter { $0.speaker == label }
            guard let longest = turns.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else { return nil }
            let text = longest.text.split(separator: " ").joined(separator: " ")
            return Candidate(label: label, ranges: ranges[label]!, sampleStart: longest.start,
                             sampleEnd: min(longest.end, longest.start + sampleSeconds),
                             quote: text.count > 160 ? String(text.prefix(157)) + "…" : text,
                             introduction: introductions[label])
        }
    }

    /// How many recordings Name Voices listens to at first: the most recent ones. Listening is the slow part
    /// (the voice model runs over each recording), and the people met lately are the ones worth naming first.
    public static let firstBatch = 20

    /// The recordings to listen to: newest first, at most `limit` (nil = all of them).
    public static func newest<T>(_ items: [T], date: (T) -> Date, base: (T) -> String, limit: Int?) -> [T] {
        let sorted = items.sorted { date($0) != date($1) ? date($0) > date($1) : base($0) < base($1) }
        guard let limit else { return sorted }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// How many voices the question after a meeting asks about: the people who spoke the most.
    public static let afterMeetingLimit = 2
    /// Someone who said less than this in a meeting is not worth a question after it.
    public static let afterMeetingMinSeconds = 60.0

    /// After a meeting: its still-unnamed speakers who talked the most (at least `minSeconds`), most talk
    /// first, at most `limit`. Empty = nothing to ask (everyone named, or only short voices left).
    public static func topCandidates(in timed: TranscriptSegments, limit: Int = afterMeetingLimit,
                                     minSeconds: Double = afterMeetingMinSeconds) -> [Candidate] {
        var talk: [String: Double] = [:]
        for s in timed.segments { if let l = s.speaker { talk[l, default: 0] += max(0, s.end - s.start) } }
        return candidates(in: timed).filter { (talk[$0.label] ?? 0) >= minSeconds }
            .sorted { (talk[$0.label] ?? 0) != (talk[$1.label] ?? 0) ? (talk[$0.label] ?? 0) > (talk[$1.label] ?? 0) : $0.label < $1.label }
            .prefix(max(0, limit)).map { $0 }
    }

    /// Groups occurrences into voices: most meetings first, then the most recent. An occurrence joins the
    /// closest existing voice when the similarity to that voice's mean is at least `threshold` and that voice
    /// has no speaker of the same meeting yet; otherwise it starts a new voice.
    public static func group(_ occurrences: [Occurrence], store: VoiceProfileStore,
                             threshold: Float = VoiceProfileStore.defaultThreshold) -> [Voice] {
        var groups: [(members: [Occurrence], sum: [Float])] = []
        let ordered = occurrences.sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
        for o in ordered {
            guard let unit = VoiceProfileStore.normalised(o.embedding) else { continue }
            var best = -1, bestScore: Float = -1
            for (i, g) in groups.enumerated() where !g.members.contains(where: { $0.base == o.base }) {
                guard let centre = VoiceProfileStore.normalised(g.sum), centre.count == unit.count else { continue }
                let score = VoiceProfileStore.cosine(centre, unit)
                if score > bestScore { best = i; bestScore = score }
            }
            if best >= 0, bestScore >= threshold {
                groups[best].members.append(o)
                groups[best].sum = zip(groups[best].sum, unit).map(+)
            } else {
                groups.append(([o], unit))
            }
        }
        let sorted = groups.sorted {
            $0.members.count != $1.members.count ? $0.members.count > $1.members.count
                : ($0.members[0].date != $1.members[0].date ? $0.members[0].date > $1.members[0].date : $0.members[0].id < $1.members[0].id)
        }
        return sorted.enumerated().map { i, g in
            Voice(id: i + 1, occurrences: g.members,
                  suggestedName: store.match(speakers: ["voice": g.sum], threshold: threshold)["voice"]?.name)
        }
    }

    /// The owner says one meeting of a voice is somebody else: that occurrence leaves the voice and becomes a
    /// voice of its own (new id, listed right after the one it left). Grouping is a guess; this is the correction.
    /// A voice with a single meeting, or an occurrence that is not in the voice, changes nothing.
    public static func separating(_ occurrenceID: String, from voiceID: Int, in voices: [Voice]) -> [Voice] {
        guard let i = voices.firstIndex(where: { $0.id == voiceID }), voices[i].occurrences.count > 1,
              let j = voices[i].occurrences.firstIndex(where: { $0.id == occurrenceID }) else { return voices }
        var out = voices
        let moved = out[i].occurrences.remove(at: j)
        let newID = (voices.map(\.id).max() ?? 0) + 1
        out.insert(Voice(id: newID, occurrences: [moved], suggestedName: nil), at: i + 1)
        return out
    }

    public struct Applied: Equatable, Sendable {
        /// Meetings whose speaker now carries the name.
        public var renamed: [String] = []
        /// Meetings left alone, with the reason (already has a speaker of that name, or the rename failed).
        public var skipped: [String: String] = [:]
        public var remembered = false
        public init(renamed: [String] = [], skipped: [String: String] = [:], remembered: Bool = false) {
            self.renamed = renamed; self.skipped = skipped; self.remembered = remembered
        }
    }

    /// Two partial outcomes of naming one voice (the app names it one meeting at a time) as one.
    public static func merged(_ a: Applied, _ b: Applied) -> Applied {
        Applied(renamed: a.renamed + b.renamed, skipped: a.skipped.merging(b.skipped) { _, new in new },
                remembered: a.remembered || b.remembered)
    }

    /// Gives `voice` the name: renames the speaker in each of its meetings and, with `remember`, adds its
    /// samples to `store` (the caller saves it). A meeting that already has a speaker called `name` is skipped,
    /// because the rename would merge two speakers there.
    public static func apply(voice: Voice, name rawName: String, remember: Bool, notesDir: URL, workDir: URL,
                             store: inout VoiceProfileStore, now: Date = Date()) -> Applied {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = Applied()
        guard !name.isEmpty, !VoiceRecognition.isLabel(name) else { return out }
        for o in voice.occurrences {
            let speakers = Set(TranscriptSegments.load(workDir: workDir, base: o.base)?.segments.compactMap(\.speaker) ?? [])
            guard speakers.contains(o.label) else { out.skipped[o.base] = "that speaker was renamed meanwhile"; continue }
            if speakers.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                out.skipped[o.base] = "already has a speaker called \(name)"
                continue
            }
            do {
                _ = try SpeakerRename.apply(mapping: [o.label: name], base: o.base, notesDir: notesDir, workDir: workDir, now: now)
                out.renamed.append(o.base)
                if remember, store.enrol(name: name, sample: o.embedding, now: now) { out.remembered = true }
            } catch {
                out.skipped[o.base] = error.localizedDescription
            }
        }
        return out
    }
}
