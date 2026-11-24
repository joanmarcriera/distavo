// VoiceTeams.swift — who meets with whom, used to settle a voice that is close to two remembered people.
// Part of voice profiles (#2944 phase 2; rules in VoiceProfiles.swift). Pure apart from `load`.
//
// The owner talks to the same few groups again and again. `VoiceTeams` counts, from the names the owner
// confirmed (`<base>.speaker-names.json` in the work dir, nothing else), in how many meetings each person was
// and in how many each pair was together. `VoiceProfileStore.match(…team:)` uses it for ONE thing: a speaker
// whose voice clears the threshold but is within the margin of another remembered voice (so on voice alone it
// would stay unnamed) is given to the person who usually meets with the speakers already recognised in this
// recording. It never names a voice below the threshold and never overrides a clear voice match.
// The rule (`pick`): the winner needs at least `minTogether` meetings with those people and at least
// `ratio` times the count of every rival; with nobody recognised yet, total meetings are compared instead.

import Foundation

public struct VoiceTeams: Equatable, Sendable {
    public static let minTogether = 2
    public static let ratio = 2

    /// lowercased name -> meetings they were named in.
    public private(set) var meetings: [String: Int] = [:]
    /// lowercased name -> lowercased name -> meetings both were named in.
    public private(set) var together: [String: [String: Int]] = [:]

    public init() {}

    /// From the people named in each meeting (one array per meeting).
    public init(meetings lists: [[String]]) {
        for list in lists {
            let people = Set(list.map { $0.lowercased() }.filter { !$0.isEmpty && !VoiceRecognition.isLabel($0.uppercased()) })
            for p in people {
                meetings[p, default: 0] += 1
                for q in people where q != p { together[p, default: [:]][q, default: 0] += 1 }
            }
        }
    }

    /// Every meeting's confirmed names in `workDir`, leaving out `base` (the recording being processed now).
    public static func load(workDir: URL, excluding base: String? = nil) -> VoiceTeams {
        let suffix = ".speaker-names.json"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: workDir.path)) ?? []
        var lists: [[String]] = []
        for f in files where f.hasSuffix(suffix) {
            let b = String(f.dropLast(suffix.count))
            guard b != base, let file = SpeakerNames.load(workDir: workDir, base: b) else { continue }
            // Only names the owner confirmed: a voice guess must not become evidence for the next guess.
            let guessed = Set((file.byVoice ?? []).map { $0.lowercased() })
            lists.append(file.names.values.filter { !guessed.contains($0.lowercased()) })
        }
        return VoiceTeams(meetings: lists)
    }

    /// How strongly `name` belongs with `context` (the people already recognised in this recording).
    public func weight(_ name: String, with context: [String]) -> Int {
        let n = name.lowercased()
        if context.isEmpty { return meetings[n] ?? 0 }
        return context.reduce(0) { $0 + (together[n]?[$1.lowercased()] ?? 0) }
    }

    /// The one of `rivals` that clearly belongs with `context`, or nil when none does.
    public func pick(among rivals: [String], with context: [String]) -> String? {
        let ranked = rivals.map { ($0, weight($0, with: context)) }.sorted { $0.1 > $1.1 }
        guard let top = ranked.first, top.1 >= Self.minTogether else { return nil }
        if ranked.count > 1, top.1 < Self.ratio * ranked[1].1 { return nil }
        return top.0
    }
}
