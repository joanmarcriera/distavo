import XCTest
@testable import DistavoCore

/// Second round of tests for "Review Voices" (`VoiceCatalog`), written before 1.23: the cases the first round
/// left out (a failure half-way and a voice guess, an undo record another feature makes unusable, a
/// correction that changes no sample) and a seeded random sequence of operations that checks, after every
/// step, that a refused or failed operation changed nothing and that an undo puts everything back.
/// Synthetic vectors and invented names only.
final class VoiceCatalogHardeningTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private struct Boom: Error {}

    private func v(_ i: Int, tilt: Float = 0) -> [Float] {
        var out = [Float](repeating: 0, count: 8); out[i % 7] = 1; out[7] += tilt; return out
    }

    /// One meeting on disk: note, clean transcript, timed transcript, names sidecar.
    private struct World {
        var notes: URL, work: URL, support: URL
        var bases: [String] = []

        init() throws {
            let root = TestTemp.root.appendingPathComponent("distavo-catalog-hard-\(UUID().uuidString)")
            notes = root.appendingPathComponent("notes"); work = root.appendingPathComponent("work")
            support = root.appendingPathComponent("support")
            for dir in [notes, work, support] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        }

        /// `speakers`: as written in the transcript. `tracked`: diariser label -> name. `guessed`: named by voice.
        mutating func addMeeting(_ base: String, speakers: [String], tracked: [String: String] = [:], guessed: [String] = []) throws {
            bases.append(base)
            let list = speakers.map { "- \($0): spoke" }.joined(separator: "\n")
            try "# Call \(base)\n\n## Speakers\n\n\(list)\n\n## Notes\n\nThe pipes are late.\n"
                .write(to: notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
            try speakers.map { "[\($0)]\nThe pipes are late.\n" }.joined(separator: "\n")
                .write(to: Pipeline.cachedTranscriptURL(workDir: work, base: base), atomically: true, encoding: .utf8)
            var segments: [TranscriptSegments.Segment] = []
            for (i, s) in speakers.enumerated() {
                segments.append(.init(start: Double(i) * 100, end: Double(i) * 100 + 40, text: "the pipes are late", speaker: s))
                segments.append(.init(start: Double(i) * 100 + 40, end: Double(i) * 100 + 45, text: "yes", speaker: s))
            }
            try TranscriptSegments(segments: segments).save(workDir: work, base: base)
            if !tracked.isEmpty || !guessed.isEmpty {
                try SpeakerNames(names: tracked, byVoice: guessed.isEmpty ? nil : guessed).encoded()
                    .write(to: SpeakerNames.url(workDir: work, base: base))
            }
        }

        func context(now: Date, rename: VoiceCatalog.RenameSeam? = nil, save: VoiceCatalog.SaveSeam? = nil) -> VoiceCatalog.Context {
            .init(notesDir: notes, workDir: work, supportDir: support, model: "m", now: now, rename: rename, save: save)
        }
        func store() -> VoiceProfileStore { VoiceProfileStore.load(supportDir: support, model: "m") }
        func speakers(_ base: String) -> [String] {
            Set(TranscriptSegments.load(workDir: work, base: base)?.segments.compactMap(\.speaker) ?? []).sorted()
        }
        func guesses(_ base: String) -> [String] { SpeakerNames.voiceGuesses(workDir: work, base: base).sorted() }
        var storeBytes: Data? { try? Data(contentsOf: VoiceProfileStore.url(supportDir: support)) }
        var undoBytes: Data? { try? Data(contentsOf: VoiceCatalog.undoURL(supportDir: support)) }

        /// Everything an operation may change, in a form two states can be compared in.
        func snapshot() -> [String: String] {
            var out = ["store": storeBytes?.base64EncodedString() ?? "-", "undo": undoBytes?.base64EncodedString() ?? "-"]
            for base in bases {
                out["\(base).speakers"] = speakers(base).joined(separator: "|")
                out["\(base).segments"] = "\(TranscriptSegments.load(workDir: work, base: base)?.segments.count ?? -1)"
                out["\(base).guesses"] = guesses(base).joined(separator: "|")
                out["\(base).names"] = (SpeakerNames.load(workDir: work, base: base)?.names ?? [:]).sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: "|")
                out["\(base).note"] = (try? String(contentsOf: notes.appendingPathComponent("\(base).md"), encoding: .utf8)) ?? "-"
                out["\(base).transcript"] = (try? String(contentsOf: Pipeline.cachedTranscriptURL(workDir: work, base: base), encoding: .utf8)) ?? "-"
            }
            return out
        }
    }

    private func differences(_ a: [String: String], _ b: [String: String], ignoring: Set<String> = []) -> [String] {
        Set(a.keys).union(b.keys).filter { !ignoring.contains($0) && a[$0] != b[$0] }.sorted()
    }

    /// a: Petra (confirmed) + SPEAKER_00. b: Petra (a voice guess) + Ines. Petra and Ines are remembered.
    private func smallWorld() throws -> World {
        var w = try World()
        try w.addMeeting("a", speakers: ["SPEAKER_00", "Petra Novak"], tracked: ["SPEAKER_01": "Petra Novak"])
        try w.addMeeting("b", speakers: ["Ines Prat", "Petra Novak"], tracked: ["SPEAKER_01": "Petra Novak"], guessed: ["Petra Novak"])
        var store = VoiceProfileStore(model: "m")
        store.enrol(name: "Petra Novak", sample: v(0), now: t0)
        store.enrol(name: "Petra Novak", sample: v(1), now: t0)
        store.enrol(name: "Ines Prat", sample: v(2), now: t0)
        try store.save(supportDir: w.support)
        return w
    }

    // MARK: A failure half-way

    func testAFailedOperationLeavesAVoiceGuessAGuess() throws {
        let w = try smallWorld()
        let before = w.snapshot()
        XCTAssertEqual(w.guesses("b"), ["Petra Novak"])
        var calls = 0
        let failingSecond: VoiceCatalog.RenameSeam = { mapping, base in
            calls += 1
            if calls == 2 { throw Boom() }
            _ = try SpeakerRename.apply(mapping: mapping, base: base, notesDir: w.notes, workDir: w.work, now: self.t0)
        }
        // b (the guess) is renamed first, then a fails: b is put back and must still be a guess.
        XCTAssertThrowsError(try VoiceCatalog.separate(name: "Petra Novak", meetings: ["b", "a"], embeddings: [:], to: "Olga Marsh",
                                                       remember: false, renameNotes: true, context: w.context(now: t0, rename: failingSecond)))
        XCTAssertEqual(differences(before, w.snapshot()), [])

        XCTAssertThrowsError(try VoiceCatalog.merge(name: "Petra Novak", into: "Olga Marsh", renameNotes: true, meetings: ["a", "b"],
                                                    context: w.context(now: t0.addingTimeInterval(5), save: { _ in throw Boom() })))
        XCTAssertEqual(differences(before, w.snapshot()), [])
        XCTAssertEqual(w.guesses("b"), ["Petra Novak"], "an operation that did not happen must not confirm a name")
    }

    // MARK: The undo record

    func testAnotherFeatureChangingTheVoicesRemovesTheUndoRecordAtOnce() throws {
        let w = try smallWorld()
        _ = try VoiceCatalog.merge(name: "Ines Prat", into: "Petra Novak", renameNotes: false, meetings: [], context: w.context(now: t0))
        XCTAssertNotNil(w.undoBytes, "the operation's own save keeps its record")

        // A save that changes nothing (Settings re-saving the same voices) keeps the undo.
        try w.store().save(supportDir: w.support)
        XCTAssertNotNil(w.undoBytes)

        // Rename Speakers remembers a new voice: the record holds samples and can never be used again.
        var store = w.store()
        store.enrol(name: "Someone New", sample: v(4), now: t0)
        try store.save(supportDir: w.support)
        XCTAssertNil(w.undoBytes, "removed by the save itself, not only when the Voices window is next opened")
        XCTAssertThrowsError(try VoiceCatalog.undo(context: w.context(now: t0))) { XCTAssertEqual($0 as? VoiceCatalog.Failure, .nothingToUndo) }
    }

    func testForgettingEveryVoiceRemovesTheUndoRecord() throws {
        let w = try smallWorld()
        _ = try VoiceCatalog.merge(name: "Ines Prat", into: "Petra Novak", renameNotes: false, meetings: [], context: w.context(now: t0))
        try VoiceProfileStore(model: "m").save(supportDir: w.support)   // Settings > Delete All
        XCTAssertNil(w.storeBytes)
        XCTAssertNil(w.undoBytes)
    }

    func testACorrectionThatChangesNoSampleCanStillBeUndone() throws {
        let w = try smallWorld()
        let before = w.snapshot()
        // No recording, so no sample: only the name of the meeting is corrected. The voice file is not rewritten.
        let out = try VoiceCatalog.separate(name: "Petra Novak", meetings: ["a"], embeddings: [:], to: nil,
                                            remember: false, renameNotes: true, context: w.context(now: t0))
        XCTAssertEqual(out.renamed, ["a"])
        XCTAssertEqual(out.samplesRemoved, 0)
        XCTAssertEqual(w.speakers("a"), ["SPEAKER_00", "SPEAKER_01"])
        XCTAssertEqual(w.snapshot()["store"], before["store"])
        XCTAssertNotNil(VoiceCatalog.pendingUndo(supportDir: w.support), "the record matches the untouched voice file")
        _ = try VoiceCatalog.undo(context: w.context(now: t0.addingTimeInterval(5)))
        XCTAssertEqual(differences(before, w.snapshot()), [])
    }

    func testAnUndoRecordThatCannotBeReadIsRemovedAndNeverUsed() throws {
        let w = try smallWorld()
        let before = w.snapshot()
        try Data("{not json".utf8).write(to: VoiceCatalog.undoURL(supportDir: w.support))
        XCTAssertThrowsError(try VoiceCatalog.undo(context: w.context(now: t0))) { XCTAssertEqual($0 as? VoiceCatalog.Failure, .nothingToUndo) }
        XCTAssertNil(VoiceCatalog.pendingUndo(supportDir: w.support))
        XCTAssertNil(w.undoBytes)
        XCTAssertEqual(differences(before, w.snapshot()), [])

        // A record of a newer Distavo is not this version's to use.
        _ = try VoiceCatalog.merge(name: "Ines Prat", into: "Ines Prat Soler", renameNotes: false, meetings: [], context: w.context(now: t0))
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(w.undoBytes)) as? [String: Any])
        json["version"] = VoiceCatalog.UndoRecord.currentVersion + 1
        try JSONSerialization.data(withJSONObject: json).write(to: VoiceCatalog.undoURL(supportDir: w.support))
        XCTAssertThrowsError(try VoiceCatalog.undo(context: w.context(now: t0))) { XCTAssertEqual($0 as? VoiceCatalog.Failure, .nothingToUndo) }
        XCTAssertEqual(w.store().names.sorted(), ["Ines Prat Soler", "Petra Novak"])
    }

    func testASecondOperationReplacesTheUndoOfTheFirst() throws {
        let w = try smallWorld()
        _ = try VoiceCatalog.merge(name: "Ines Prat", into: "Ines Prat Soler", renameNotes: true, meetings: ["b"], context: w.context(now: t0))
        let between = w.snapshot()
        _ = try VoiceCatalog.merge(name: "Petra Novak", into: "Petra N.", renameNotes: true, meetings: ["a", "b"], context: w.context(now: t0.addingTimeInterval(5)))
        _ = try VoiceCatalog.undo(context: w.context(now: t0.addingTimeInterval(10)))
        XCTAssertEqual(differences(between, w.snapshot(), ignoring: ["undo"]), [], "one level: back to the state after the first")
        XCTAssertEqual(w.speakers("b"), ["Ines Prat Soler", "Petra Novak"])
    }

    // MARK: Names

    func testBackToALabelNeverTakesALabelAnotherSpeakerHas() throws {
        var w = try World()
        // The name came from SPEAKER_00, and a different speaker is called SPEAKER_00 now (a transcript edit).
        try w.addMeeting("a", speakers: ["SPEAKER_00", "Petra Novak"], tracked: ["SPEAKER_00": "Petra Novak"])
        var store = VoiceProfileStore(model: "m")
        store.enrol(name: "Petra Novak", sample: v(0), now: t0)
        try store.save(supportDir: w.support)
        let out = try VoiceCatalog.separate(name: "Petra Novak", meetings: ["a"], embeddings: [:], to: "", remember: false,
                                            renameNotes: true, context: w.context(now: t0))
        XCTAssertEqual(out.renamed, ["a"])
        let speakers = w.speakers("a")
        XCTAssertEqual(speakers.count, 2, "two people stay two people: \(speakers)")
        XCTAssertTrue(speakers.allSatisfy(VoiceRecognition.isLabel), "\(speakers)")
    }

    func testTheSameNameTypedWithOtherAccentsFormOrCapitalsIsTheSamePerson() throws {
        var w = try World()
        try w.addMeeting("a", speakers: ["Núria Vila", "SPEAKER_00"], tracked: ["SPEAKER_01": "Núria Vila"])
        var store = VoiceProfileStore(model: "m")
        store.enrol(name: "Núria Vila", sample: v(0), now: t0)
        store.enrol(name: "Pau Roig", sample: v(1), now: t0)
        try store.save(supportDir: w.support)
        let decomposed = "NU\u{0301}RIA VILA"   // u + combining accent, in capitals
        let people = VoiceCatalog.people(store: w.store(), meetings: [.init(base: "a", title: "Call a", date: t0)], workDir: w.work)
        XCTAssertEqual(people.first?.bases, ["a"])
        XCTAssertThrowsError(try VoiceCatalog.separate(name: "Núria Vila", meetings: ["a"], embeddings: [:], to: decomposed, remember: true,
                                                       renameNotes: true, context: w.context(now: t0))) {
            XCTAssertEqual($0 as? VoiceCatalog.Failure, .sameName)
        }
        let out = try VoiceCatalog.merge(name: decomposed, into: "Pau Roig", renameNotes: true, meetings: ["a"], context: w.context(now: t0))
        XCTAssertTrue(out.merged)
        XCTAssertEqual(out.renamed, ["a"])
        XCTAssertEqual(w.speakers("a"), ["Pau Roig", "SPEAKER_00"])
        XCTAssertEqual(w.store().names, ["Pau Roig"])
    }

    func testAVoiceCannotGetANameATranscriptCannotCarry() throws {
        let w = try smallWorld()
        let before = w.snapshot()
        for bad in ["Line\nBreak", "Na[me]", "[Ines]", "SPEAKER_04", String(repeating: "x", count: SpeakerRename.maxNameLength + 1)] {
            // Without the meetings following, nothing else would have refused the name.
            XCTAssertThrowsError(try VoiceCatalog.merge(name: "Ines Prat", into: bad, renameNotes: false, meetings: [], context: w.context(now: t0)), bad) {
                XCTAssertEqual($0 as? VoiceCatalog.Failure, .invalidName, bad)
            }
            XCTAssertThrowsError(try VoiceCatalog.separate(name: "Petra Novak", meetings: ["a"], embeddings: ["a": v(1)], to: bad, remember: true,
                                                           renameNotes: false, context: w.context(now: t0)), bad) {
                XCTAssertEqual($0 as? VoiceCatalog.Failure, .invalidName, bad)
            }
        }
        XCTAssertEqual(differences(before, w.snapshot()), [])
    }

    func testAMeetingWithoutATimedTranscriptIsSkippedAndSaid() throws {
        let w = try smallWorld()
        let out = try VoiceCatalog.separate(name: "Petra Novak", meetings: ["a", "gone"], embeddings: [:], to: "Olga Marsh",
                                            remember: false, renameNotes: true, context: w.context(now: t0))
        XCTAssertEqual(out.renamed, ["a"])
        XCTAssertEqual(out.skipped, ["gone": "no timed transcript"])
    }

    // MARK: Random sequences

    /// SplitMix64, as in PeopleFuzzTests: the same seed gives the same sequence on every machine.
    private struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
        mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
        mutating func subset<T>(_ a: [T]) -> [T] { var out: [T] = []; for x in a where chance(55) { out.append(x) }; return out }
    }

    private static let pool = ["Petra Novak", "Ines Prat", "Olga Marsh", "Núria Vila"]
    private static let typed: [String] = pool + ["petra novak", "INES PRAT", "Nu\u{0301}ria Vila", "  Zoe Ward ", "Stranger", "", " ",
                                                 "SPEAKER_07", "speaker_00", "O'Brien", "李雷", "A\nB", "x/y", "Zoe: Ward", "Na[me]", "[Petra Novak]",
                                                 String(repeating: "long name ", count: 12)]

    private func randomWorld(_ r: inout Random) throws -> World {
        var w = try World()
        for i in 0..<5 {
            var named = r.subset(Self.pool)
            if named.count > 2 { named = Array(named.prefix(2)) }
            var speakers = named
            if named.count < 2 || r.chance(50) { speakers.append("SPEAKER_00") }
            if r.chance(20) { speakers.append("SPEAKER_03") }
            var tracked: [String: String] = [:]
            for (k, name) in named.enumerated() where r.chance(70) { tracked["SPEAKER_0\(k + 1)"] = name }
            try w.addMeeting("m\(i)", speakers: speakers, tracked: tracked, guessed: named.filter { tracked.values.contains($0) && r.chance(40) })
        }
        var store = VoiceProfileStore(model: "m")
        for (k, name) in Self.pool.enumerated() where r.chance(70) {
            store.enrol(name: name, sample: v(k), now: t0)
            if r.chance(50) { store.enrol(name: name, sample: v(k + 4), now: t0) }
        }
        try store.save(supportDir: w.support)
        return w
    }

    func testRandomSequencesOfOperationsKeepTheirPromises() throws {
        var r = Random(state: 20261127)
        var clock = t0
        var done = 0, refused = 0, undone = 0
        for worldNo in 0..<40 {
            let w = try randomWorld(&r)
            for step in 0..<25 {
                clock = clock.addingTimeInterval(7)
                let before = w.snapshot()
                let storeBefore = w.store()
                let kind = r.below(10)
                // Mostly a voice that is remembered and a plausible name, so that operations really happen.
                let name = !storeBefore.names.isEmpty && r.chance(70) ? r.pick(storeBefore.names) : r.pick(Self.typed)
                let other = r.chance(50) ? r.pick(Self.pool + ["Zoe Ward"]) : r.pick(Self.typed)
                let bases = r.subset(w.bases + ["missing"])
                let remember = r.chance(50), renameNotes = r.chance(70)
                var embeddings: [String: [Float]] = [:]
                for b in bases where r.chance(60) { embeddings[b] = v(r.below(8), tilt: r.chance(30) ? 0.05 : 0) }
                // Now and then a rename or the save fails half-way (one fault at a time: what is promised is
                // that ONE failure leaves everything as it was).
                let failSave = r.chance(8)
                var failAt = !failSave && r.chance(15) ? 1 + r.below(3) : 0
                let renameAt = clock
                let rename: VoiceCatalog.RenameSeam = { mapping, base in
                    if failAt > 0 { failAt -= 1; if failAt == 0 { throw Boom() } }
                    _ = try SpeakerRename.apply(mapping: mapping, base: base, notesDir: w.notes, workDir: w.work, now: renameAt)
                }
                let save: VoiceCatalog.SaveSeam? = failSave ? { _ in throw Boom() } : nil
                let c = w.context(now: clock, rename: rename, save: save)
                let what = "world \(worldNo) step \(step) kind \(kind) name ‘\(name)’ other ‘\(other)’ bases \(bases) notes \(renameNotes) remember \(remember)"

                var outcome: VoiceCatalog.Outcome?
                var allowed = Set(storeBefore.names.map { $0.lowercased() })
                do {
                    switch kind {
                    case 0...3:
                        outcome = try VoiceCatalog.separate(name: name, meetings: bases, embeddings: embeddings, to: r.chance(30) ? nil : other,
                                                            remember: remember, renameNotes: renameNotes, context: c)
                        allowed.insert(VoiceCatalog.cleanName(other).lowercased())
                    case 4...6:
                        outcome = try VoiceCatalog.merge(name: name, into: other, renameNotes: renameNotes, meetings: bases, context: c)
                        allowed.insert(VoiceCatalog.cleanName(other).lowercased())
                    case 7:
                        _ = try VoiceCatalog.undo(context: c)
                        undone += 1
                        XCTAssertNil(w.undoBytes, "an undo uses its record up: \(what)")
                        continue
                    default:
                        // Another feature saves the voice file (Rename Speakers remembering a voice).
                        var s = storeBefore
                        let changed = s.enrol(name: r.pick(Self.pool), sample: v(r.below(8), tilt: 0.02), now: clock)
                        try s.save(supportDir: w.support)
                        if changed, w.storeBytes != Data(base64Encoded: before["store"] ?? "") {
                            XCTAssertNil(w.undoBytes, "a record that no longer matches the voices must go: \(what)")
                        }
                        continue
                    }
                } catch {
                    refused += 1
                    XCTAssertEqual(differences(before, w.snapshot()), [], "a refused or failed operation changed something (\(error)): \(what)")
                    continue
                }
                done += 1
                let out = try XCTUnwrap(outcome)
                let after = w.snapshot()

                // Only the meetings it says it renamed changed, and nobody was merged into somebody else there.
                for base in w.bases {
                    let keys = ["speakers", "segments", "guesses", "names", "note", "transcript"].map { "\(base).\($0)" }
                    if out.renamed.contains(base) {
                        XCTAssertEqual(before["\(base).segments"], after["\(base).segments"], what)
                        XCTAssertEqual(before["\(base).speakers"]?.split(separator: "|").count, after["\(base).speakers"]?.split(separator: "|").count,
                                       "two speakers became one in \(base): \(what)")
                    } else {
                        XCTAssertEqual(keys.filter { before[$0] != after[$0] }, [], "a meeting that was not renamed changed: \(what)")
                    }
                }
                XCTAssertTrue(Set(out.renamed).isDisjoint(with: out.skipped.keys), what)
                if !renameNotes { XCTAssertEqual(out.renamed, [], what) }

                // The voice file: no label, no empty name, nobody remembered who was not named for it.
                let store = w.store()
                for n in store.names {
                    XCTAssertTrue(VoiceCatalog.isVoiceName(n), "‘\(n)’ is remembered: \(what)")
                    XCTAssertTrue(allowed.contains(n.lowercased()), "‘\(n)’ was remembered without being asked: \(what)")
                }
                XCTAssertEqual(Set(store.names.map { $0.lowercased() }).count, store.names.count, "one person twice: \(what)")
                for p in store.profiles { XCTAssertFalse(p.samples.isEmpty, "a voice with no sample is kept: \(what)") }
                for url in [VoiceProfileStore.url(supportDir: w.support), VoiceCatalog.undoURL(supportDir: w.support)]
                where FileManager.default.fileExists(atPath: url.path) {
                    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
                    XCTAssertEqual(mode, 0o600, "\(url.lastPathComponent): \(what)")
                }
                XCTAssertNotNil(VoiceCatalog.pendingUndo(supportDir: w.support), "every change can be undone right after: \(what)")

                // Half the time: undo it, and everything is as it was.
                if r.chance(50) {
                    clock = clock.addingTimeInterval(7)
                    let back = try VoiceCatalog.undo(context: w.context(now: clock))
                    XCTAssertEqual(back.skipped, [:], what)
                    XCTAssertEqual(differences(before, w.snapshot(), ignoring: ["undo"]), [], "the undo did not put everything back: \(what)")
                    undone += 1
                }
            }
        }
        // The sequence must really exercise all three outcomes, or the invariants above prove little.
        XCTAssertGreaterThan(done, 100, "done \(done), refused \(refused), undone \(undone)")
        XCTAssertGreaterThan(refused, 100)
        XCTAssertGreaterThan(undone, 50)
    }
}
