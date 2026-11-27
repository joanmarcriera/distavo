import XCTest
@testable import DistavoCore

/// "Review Voices" (`VoiceCatalog`). Synthetic vectors and invented names only.
final class VoiceCatalogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func v(_ i: Int, tilt: Float = 0) -> [Float] {
        var out = [Float](repeating: 0, count: 8); out[i] = 1; out[7] += tilt; return out
    }
    private func seg(_ speaker: String?, _ start: Double, _ end: Double, _ text: String = "some words here") -> TranscriptSegments.Segment {
        .init(start: start, end: end, text: text, speaker: speaker)
    }

    private struct Fixture {
        var notes: URL, work: URL, support: URL
        func context(now: Date, rename: VoiceCatalog.RenameSeam? = nil, save: VoiceCatalog.SaveSeam? = nil) -> VoiceCatalog.Context {
            .init(notesDir: notes, workDir: work, supportDir: support, model: "m", now: now, rename: rename, save: save)
        }
        func store() -> VoiceProfileStore { VoiceProfileStore.load(supportDir: support, model: "m") }
        func speakers(_ base: String) -> Set<String> {
            Set(TranscriptSegments.load(workDir: work, base: base)?.segments.compactMap(\.speaker) ?? [])
        }
        func note(_ base: String) -> String { (try? String(contentsOf: notes.appendingPathComponent("\(base).md"), encoding: .utf8)) ?? "" }
        var storeBytes: Data? { try? Data(contentsOf: VoiceProfileStore.url(supportDir: support)) }
        var undoBytes: Data? { try? Data(contentsOf: VoiceCatalog.undoURL(supportDir: support)) }
    }

    /// Meetings a, b, c (a oldest). "Petra Novak" speaks in all three; in c the name is a voice guess.
    /// "Ines Prat" speaks in c too. SPEAKER_00 talks 100 s in a and 20 s in b.
    private func fixture() throws -> Fixture {
        let root = TestTemp.root.appendingPathComponent("distavo-catalog-\(UUID().uuidString)")
        let f = Fixture(notes: root.appendingPathComponent("notes"), work: root.appendingPathComponent("work"),
                        support: root.appendingPathComponent("support"))
        for dir in [f.notes, f.work, f.support] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        for base in ["a", "b", "c"] {
            let other = base == "c" ? "Ines Prat" : "SPEAKER_00"
            try "# Call \(base)\n\n## Speakers\n\n- Petra Novak: plumbing\n\n## Notes\n\nThe pipes are late.\n".write(to: f.notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
            try "[\(other)]\nHello.\n\n[Petra Novak]\nThe pipes are late.\n"
                .write(to: Pipeline.cachedTranscriptURL(workDir: f.work, base: base), atomically: true, encoding: .utf8)
            try TranscriptSegments(segments: [seg(other, 0, base == "a" ? 100 : 20), seg("Petra Novak", 100, 130, "the pipes are late"),
                                              seg("Petra Novak", 130, 135)])
                .save(workDir: f.work, base: base)
            try SpeakerNames(names: ["SPEAKER_01": "Petra Novak"], byVoice: base == "c" ? ["Petra Novak"] : nil).encoded()
                .write(to: SpeakerNames.url(workDir: f.work, base: base))
        }
        var store = VoiceProfileStore(model: "m")
        store.enrol(name: "Petra Novak", sample: v(0), now: t0)
        store.enrol(name: "Petra Novak", sample: v(1), now: t0)   // a second, different-sounding sample
        store.enrol(name: "Ines Prat", sample: v(2), now: t0)
        try store.save(supportDir: f.support)
        return f
    }

    private var meetings: [VoiceCatalog.Meeting] {
        ["a", "b", "c"].enumerated().map { .init(base: $1, title: "Call \($1)", date: t0.addingTimeInterval(Double($0) * 86_400)) }
    }

    // MARK: Listing

    func testEveryRememberedVoiceIsListedWithClipsOfItsNewestMeetings() throws {
        let f = try fixture()
        let people = VoiceCatalog.people(store: f.store(), meetings: meetings, workDir: f.work, clipLimit: 2)
        XCTAssertEqual(people.map(\.name), ["Petra Novak", "Ines Prat"], "most meetings first")
        XCTAssertEqual(people[0].bases, ["c", "b", "a"])
        XCTAssertEqual(people[0].clips.map(\.base), ["c", "b"], "the limit keeps the newest")
        XCTAssertEqual(people[0].guessed, 1)
        XCTAssertEqual(people[0].clips.map(\.guessed), [true, false])
        XCTAssertEqual(people[0].clips[0].start, 100)
        XCTAssertEqual(people[0].clips[0].end, 100 + VoiceReview.sampleSeconds, "the longest turn, cut to the sample length")
        XCTAssertEqual(people[0].clips[0].quote, "the pipes are late")
        XCTAssertEqual(people[0].clips[0].talkSeconds, 35)
        XCTAssertEqual(people[0].samples, 2)
        XCTAssertEqual(people[1].bases, ["c"])
        XCTAssertTrue(VoiceCatalog.people(store: VoiceProfileStore(model: "m"), meetings: meetings, workDir: f.work).isEmpty)
    }

    func testARememberedVoiceWithNoMeetingIsStillListed() throws {
        let f = try fixture()
        var store = f.store()
        store.enrol(name: "Nobody Yet", sample: v(3), now: t0)
        let people = VoiceCatalog.people(store: store, meetings: meetings, workDir: f.work)
        XCTAssertEqual(people.last?.name, "Nobody Yet")
        XCTAssertEqual(people.last?.clips, [])
    }

    func testAnUnnamedSpeakerWhoTalkedLongIsAlwaysListed() throws {
        let f = try fixture()
        let clips = VoiceCatalog.unnamed(meetings: meetings, workDir: f.work)
        XCTAssertEqual(clips.map(\.id), ["a|SPEAKER_00"], "20 s in b is too little; names are never listed")
        XCTAssertEqual(clips[0].end - clips[0].start, VoiceReview.sampleSeconds)
        XCTAssertEqual(VoiceCatalog.unnamed(meetings: meetings, workDir: f.work, minSeconds: 10).map(\.base), ["b", "a"])
    }

    func testSampleRangesFindTheSpeakerWhateverTheCapitals() throws {
        let f = try fixture()
        let r = try XCTUnwrap(VoiceCatalog.sampleRanges(name: "petra novak", base: "a", workDir: f.work))
        XCTAssertEqual(r.speaker, "Petra Novak")
        XCTAssertFalse(r.ranges.isEmpty)
        XCTAssertNil(VoiceCatalog.sampleRanges(name: "Ines Prat", base: "a", workDir: f.work))
    }

    // MARK: Not this person / separate

    func testNotThisPersonSendsTheMeetingBackToItsLabelAndDropsTheSampleLearntFromIt() throws {
        let f = try fixture()
        let out = try VoiceCatalog.separate(name: "Petra Novak", meetings: ["c"], embeddings: ["c": v(1, tilt: 0.1)],
                                            to: nil, remember: false, renameNotes: true, context: f.context(now: t0.addingTimeInterval(60)))
        XCTAssertEqual(out.renamed, ["c"])
        XCTAssertEqual(out.samplesRemoved, 1)
        XCTAssertFalse(out.voiceForgotten)
        XCTAssertEqual(f.speakers("c"), ["Ines Prat", "SPEAKER_01"], "back to the diariser's own label")
        XCTAssertTrue(f.note("c").contains("- SPEAKER_01: plumbing"), f.note("c"))
        XCTAssertEqual(f.speakers("a"), ["SPEAKER_00", "Petra Novak"], "other meetings are not touched")
        XCTAssertEqual(f.store().profiles.first { $0.name == "Petra Novak" }?.samples, [v(0)])
        XCTAssertEqual(f.store().names.sorted(), ["Ines Prat", "Petra Novak"], "no voiceprint is kept of the unnamed voice")
        XCTAssertNotNil(VoiceCatalog.pendingUndo(supportDir: f.support))
    }

    func testSeparatingIntoANamedPersonMovesTheirMeetingsAndRemembersThem() throws {
        let f = try fixture()
        let out = try VoiceCatalog.separate(name: "Petra Novak", meetings: ["a", "b"], embeddings: ["a": v(1), "b": v(1, tilt: 0.05)],
                                            to: " Olga Marsh ", remember: true, renameNotes: true, context: f.context(now: t0))
        XCTAssertEqual(out.renamed, ["a", "b"])
        XCTAssertTrue(out.remembered)
        XCTAssertEqual(f.speakers("a"), ["SPEAKER_00", "Olga Marsh"])
        XCTAssertEqual(f.speakers("c"), ["Ines Prat", "Petra Novak"])
        let store = f.store()
        XCTAssertEqual(store.names.sorted(), ["Ines Prat", "Olga Marsh", "Petra Novak"])
        XCTAssertEqual(store.profiles.first { $0.name == "Petra Novak" }?.samples, [v(0)])
        XCTAssertEqual(store.profiles.first { $0.name == "Olga Marsh" }?.enrolments, 2)
        // The new person is now told apart from the old one.
        XCTAssertEqual(store.match(speakers: ["x": v(1)])["x"]?.name, "Olga Marsh")
    }

    func testAVoiceLeftWithNoSampleIsForgotten() throws {
        let f = try fixture()
        let out = try VoiceCatalog.separate(name: "Ines Prat", meetings: ["c"], embeddings: ["c": v(2)], to: nil,
                                            remember: false, renameNotes: false, context: f.context(now: t0))
        XCTAssertTrue(out.voiceForgotten)
        XCTAssertTrue(out.renamed.isEmpty, "the meetings were not asked to follow")
        XCTAssertEqual(f.speakers("c"), ["Ines Prat", "Petra Novak"])
        XCTAssertEqual(f.store().names, ["Petra Novak"])
    }

    func testSeparateRefusesWhatItCannotDoAndChangesNothing() throws {
        let f = try fixture()
        let before = f.storeBytes
        let c = f.context(now: t0)
        func attempt(_ name: String, to: String?, bases: [String] = ["c"], embeddings: [String: [Float]] = [:], notes: Bool = true) -> VoiceCatalog.Failure? {
            do { _ = try VoiceCatalog.separate(name: name, meetings: bases, embeddings: embeddings, to: to, remember: true, renameNotes: notes, context: c); return nil }
            catch { return error as? VoiceCatalog.Failure }
        }
        XCTAssertEqual(attempt("Stranger", to: nil), .noSuchVoice)
        XCTAssertEqual(attempt("Petra Novak", to: "SPEAKER_07"), .invalidName)
        XCTAssertEqual(attempt("Petra Novak", to: "petra novak"), .sameName)
        XCTAssertEqual(attempt("Petra Novak", to: "Ines Prat"), .nothingToDo, "she already speaks in c, and there is no sample to move")
        XCTAssertEqual(attempt("Petra Novak", to: nil, notes: false), .nothingToDo)
        XCTAssertEqual(f.storeBytes, before)
        XCTAssertNil(f.undoBytes)
        XCTAssertEqual(f.speakers("c"), ["Ines Prat", "Petra Novak"])
    }

    func testAFailedRenameOrSaveLeavesEverythingAsItWas() throws {
        let f = try fixture()
        // An earlier operation, so there is an undo record that must survive the failures.
        _ = try VoiceCatalog.merge(name: "Ines Prat", into: "Ines Prat Soler", renameNotes: false, meetings: [], context: f.context(now: t0))
        let store = f.storeBytes, undo = f.undoBytes
        XCTAssertNotNil(undo)
        struct Boom: Error {}
        var calls = 0
        let failingRename: VoiceCatalog.RenameSeam = { mapping, base in
            calls += 1
            if calls == 2 { throw Boom() }
            _ = try SpeakerRename.apply(mapping: mapping, base: base, notesDir: f.notes, workDir: f.work, now: self.t0)
        }
        XCTAssertThrowsError(try VoiceCatalog.separate(name: "Petra Novak", meetings: ["a", "b"], embeddings: ["a": v(1)], to: "Olga Marsh",
                                                       remember: true, renameNotes: true, context: f.context(now: t0, rename: failingRename))) {
            guard case VoiceCatalog.Failure.renameFailed = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(f.speakers("a"), ["SPEAKER_00", "Petra Novak"], "the first meeting was put back")
        XCTAssertEqual(f.storeBytes, store)
        XCTAssertEqual(f.undoBytes, undo)

        XCTAssertThrowsError(try VoiceCatalog.merge(name: "Petra Novak", into: "Olga Marsh", renameNotes: true, meetings: ["a", "b", "c"],
                                                    context: f.context(now: t0, save: { _ in throw Boom() })))
        for base in ["a", "b", "c"] { XCTAssertTrue(f.speakers(base).contains("Petra Novak"), base) }
        XCTAssertTrue(f.note("a").contains("- Petra Novak: plumbing"))
        XCTAssertEqual(f.storeBytes, store)
        XCTAssertEqual(f.undoBytes, undo)
    }

    // MARK: Merge

    func testMergingTwoVoicesCanTakeTheMeetingsAlongOrLeaveThem() throws {
        let f = try fixture()
        // Voice file only.
        var out = try VoiceCatalog.merge(name: "Ines Prat", into: "Petra Novak", renameNotes: false, meetings: ["a", "b", "c"], context: f.context(now: t0))
        XCTAssertTrue(out.merged && out.renamed.isEmpty)
        XCTAssertEqual(f.store().names, ["Petra Novak"])
        XCTAssertEqual(f.store().profiles[0].samples.count, 3)
        XCTAssertEqual(f.speakers("c"), ["Ines Prat", "Petra Novak"])
        _ = try VoiceCatalog.undo(context: f.context(now: t0))
        XCTAssertEqual(f.store().names, ["Petra Novak", "Ines Prat"])

        // With the meetings: c has both names, so it is left alone and said.
        out = try VoiceCatalog.merge(name: "Petra Novak", into: "Ines Prat", renameNotes: true, meetings: ["a", "b", "c"], context: f.context(now: t0))
        XCTAssertEqual(out.renamed, ["a", "b"])
        XCTAssertEqual(out.skipped, ["c": "both names speak in that meeting"])
        XCTAssertEqual(f.speakers("a"), ["SPEAKER_00", "Ines Prat"])
        XCTAssertTrue(f.note("b").contains("- Ines Prat: plumbing"), f.note("b"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.notes.path).filter { $0.contains(".prev-") }.isEmpty, "the rename path kept a backup")
    }

    func testRenamingAVoiceToANewNameIsNotAMerge() throws {
        let f = try fixture()
        let out = try VoiceCatalog.merge(name: "Ines Prat", into: "Ines Prat Soler", renameNotes: true, meetings: ["a", "b", "c"], context: f.context(now: t0))
        XCTAssertFalse(out.merged)
        XCTAssertEqual(out.renamed, ["c"])
        XCTAssertEqual(f.store().names.sorted(), ["Ines Prat Soler", "Petra Novak"])
        XCTAssertThrowsError(try VoiceCatalog.merge(name: "Petra Novak", into: "Petra Novak", renameNotes: false, meetings: [], context: f.context(now: t0))) {
            XCTAssertEqual($0 as? VoiceCatalog.Failure, .sameName)
        }
        XCTAssertThrowsError(try VoiceCatalog.merge(name: "Petra Novak", into: " ", renameNotes: false, meetings: [], context: f.context(now: t0))) {
            XCTAssertEqual($0 as? VoiceCatalog.Failure, .invalidName)
        }
    }

    // MARK: Undo

    func testUndoPutsBackTheVoiceFileTheMeetingsAndTheGuess() throws {
        let f = try fixture()
        let store = f.storeBytes
        let notes = ["a", "b", "c"].map(f.note)
        _ = try VoiceCatalog.separate(name: "Petra Novak", meetings: ["b", "c"], embeddings: ["b": v(1), "c": v(1)], to: "Olga Marsh",
                                      remember: true, renameNotes: true, context: f.context(now: t0.addingTimeInterval(60)))
        XCTAssertNil(SpeakerNames.load(workDir: f.work, base: "c")?.byVoice, "a name the owner typed is not a guess")
        XCTAssertEqual(VoiceCatalog.pendingUndo(supportDir: f.support)?.summary, "Separated a voice in two")
        let mode = try FileManager.default.attributesOfItem(atPath: VoiceCatalog.undoURL(supportDir: f.support).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        let out = try VoiceCatalog.undo(context: f.context(now: t0.addingTimeInterval(120)))
        XCTAssertEqual(out.renamed, ["b", "c"])
        XCTAssertEqual(f.storeBytes, store, "byte for byte")
        XCTAssertEqual(["a", "b", "c"].map(f.note), notes)
        XCTAssertEqual(f.speakers("c"), ["Ines Prat", "Petra Novak"])
        XCTAssertEqual(SpeakerNames.load(workDir: f.work, base: "c")?.byVoice, ["Petra Novak"], "still a guess, as before")
        XCTAssertNil(SpeakerNames.load(workDir: f.work, base: "b")?.byVoice)
        XCTAssertNil(f.undoBytes, "one level: the record is gone")
        XCTAssertThrowsError(try VoiceCatalog.undo(context: f.context(now: t0))) { XCTAssertEqual($0 as? VoiceCatalog.Failure, .nothingToUndo) }
    }

    func testUndoIsRefusedOnceTheVoicesChangedAndTheRecordDoesNotOutliveItsUse() throws {
        let f = try fixture()
        _ = try VoiceCatalog.merge(name: "Ines Prat", into: "Petra Novak", renameNotes: false, meetings: [], context: f.context(now: t0))
        var store = f.store()
        store.enrol(name: "Someone New", sample: v(4), now: t0)
        try store.save(supportDir: f.support)
        let changed = f.storeBytes
        XCTAssertThrowsError(try VoiceCatalog.undo(context: f.context(now: t0))) { XCTAssertEqual($0 as? VoiceCatalog.Failure, .changedSince) }
        XCTAssertEqual(f.storeBytes, changed)
        XCTAssertNil(VoiceCatalog.pendingUndo(supportDir: f.support))
        XCTAssertNil(f.undoBytes, "a record that can no longer be used holds samples: removed")
    }

    func testUndoLeavesAMeetingTheOwnerRenamedSince() throws {
        let f = try fixture()
        _ = try VoiceCatalog.merge(name: "Petra Novak", into: "Olga Marsh", renameNotes: true, meetings: ["a", "b"], context: f.context(now: t0))
        _ = try SpeakerRename.apply(mapping: ["Olga Marsh": "Somebody Else"], base: "b", notesDir: f.notes, workDir: f.work, now: t0)
        let out = try VoiceCatalog.undo(context: f.context(now: t0))
        XCTAssertEqual(out.renamed, ["a"])
        XCTAssertEqual(out.skipped, ["b": "the speakers of that meeting were renamed since"])
        XCTAssertEqual(f.speakers("b"), ["SPEAKER_00", "Somebody Else"])
        XCTAssertEqual(f.store().names.sorted(), ["Ines Prat", "Petra Novak"])
    }

    func testDiscardingTheUndoRecordRemovesIt() throws {
        let f = try fixture()
        _ = try VoiceCatalog.merge(name: "Ines Prat", into: "Petra Novak", renameNotes: false, meetings: [], context: f.context(now: t0))
        XCTAssertNotNil(f.undoBytes)
        VoiceCatalog.discardUndo(supportDir: f.support)
        XCTAssertNil(f.undoBytes)
        XCTAssertNil(VoiceCatalog.pendingUndo(supportDir: f.support))
    }
}
