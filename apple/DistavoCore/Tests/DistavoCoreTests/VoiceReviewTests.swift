import XCTest
@testable import DistavoCore

/// "Name Voices" (`VoiceReview`). Synthetic vectors and names only.
final class VoiceReviewTests: XCTestCase {
    func testAfterAMeetingOnlyTheUnnamedWhoSpokeMostAreAsked() {
        typealias S = TranscriptSegments.Segment
        func turns(_ who: String, from: Double, count: Int, each: Double) -> [S] {
            (0..<count).map { S(start: from + Double($0) * (each + 1), end: from + Double($0) * (each + 1) + each, text: "words here", speaker: who) }
        }
        let timed = TranscriptSegments(segments: turns("SPEAKER_00", from: 0, count: 10, each: 20)      // 200 s
            + turns("Anna", from: 300, count: 20, each: 20)                                             // named: never asked
            + turns("SPEAKER_01", from: 800, count: 5, each: 20)                                        // 100 s
            + turns("SPEAKER_02", from: 1000, count: 15, each: 20)                                      // 300 s
            + turns("SPEAKER_03", from: 1400, count: 2, each: 20))                                      // 40 s: too little
        XCTAssertEqual(VoiceReview.topCandidates(in: timed).map(\.label), ["SPEAKER_02", "SPEAKER_00"])
        XCTAssertEqual(VoiceReview.topCandidates(in: timed, limit: 5).map(\.label), ["SPEAKER_02", "SPEAKER_00", "SPEAKER_01"])
        XCTAssertTrue(VoiceReview.topCandidates(in: TranscriptSegments(segments: turns("Anna", from: 0, count: 9, each: 20))).isEmpty)
    }

    func testSeparatingMovesOneMeetingIntoItsOwnVoice() {
        func occ(_ base: String) -> VoiceReview.Occurrence {
            .init(base: base, label: "SPEAKER_00", title: base, date: Date(timeIntervalSince1970: 0),
                  sampleStart: 0, sampleEnd: 5, quote: "", embedding: [1, 0])
        }
        let voices = [VoiceReview.Voice(id: 1, occurrences: [occ("a"), occ("b"), occ("c")], suggestedName: "Ann"),
                      VoiceReview.Voice(id: 2, occurrences: [occ("d")], suggestedName: nil)]
        let out = VoiceReview.separating("b|SPEAKER_00", from: 1, in: voices)
        XCTAssertEqual(out.map(\.id), [1, 3, 2])
        XCTAssertEqual(out[0].occurrences.map(\.base), ["a", "c"])
        XCTAssertEqual(out[1].occurrences.map(\.base), ["b"])
        XCTAssertNil(out[1].suggestedName)
        // Nothing to separate from a one-meeting voice, or for an occurrence that is not there.
        XCTAssertEqual(VoiceReview.separating("d|SPEAKER_00", from: 2, in: voices), voices)
        XCTAssertEqual(VoiceReview.separating("zz|SPEAKER_00", from: 1, in: voices), voices)
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func v(_ i: Int, tilt: Float = 0) -> [Float] {
        var out = [Float](repeating: 0, count: 8); out[i] = 1; out[7] += tilt; return out
    }
    private func occ(_ base: String, _ label: String, _ e: [Float], day: Double = 0) -> VoiceReview.Occurrence {
        .init(base: base, label: label, title: "Call \(base)", date: t0.addingTimeInterval(day * 86_400),
              sampleStart: 1, sampleEnd: 9, quote: "words", embedding: e)
    }
    private func seg(_ speaker: String?, _ start: Double, _ end: Double, _ text: String = "some words here") -> TranscriptSegments.Segment {
        .init(start: start, end: end, text: text, speaker: speaker)
    }

    func testCandidatesAreTheUnnamedSpeakersWithEnoughSpeech() {
        let timed = TranscriptSegments(segments: [
            seg("SPEAKER_00", 0, 30, "the   long turn " + String(repeating: "word ", count: 60)), seg("Petra Novak", 30, 60),
            seg("SPEAKER_01", 60, 63), seg("SPEAKER_00", 63, 70),
        ])
        let c = VoiceReview.candidates(in: timed)
        XCTAssertEqual(c.map(\.label), ["SPEAKER_00"], "a named speaker and one with three seconds are left out")
        XCTAssertEqual(c[0].sampleStart, 0)
        XCTAssertEqual(c[0].sampleEnd, VoiceReview.sampleSeconds)
        XCTAssertTrue(c[0].quote.hasPrefix("the long turn word") && c[0].quote.hasSuffix("…") && c[0].quote.count == 158)
    }

    func testSameVoiceAcrossMeetingsIsOneVoiceMostMeetingsFirst() {
        let store = VoiceProfileStore(model: "m")
        let voices = VoiceReview.group([
            occ("a", "SPEAKER_00", v(0), day: 1), occ("a", "SPEAKER_01", v(1), day: 1),
            occ("b", "SPEAKER_01", v(0, tilt: 0.2), day: 2), occ("c", "SPEAKER_00", v(0, tilt: 0.1), day: 3),
            occ("c", "SPEAKER_01", v(2), day: 3),
        ], store: store)
        XCTAssertEqual(voices.map(\.meetings), [3, 1, 1])
        XCTAssertEqual(voices[0].occurrences.map(\.base), ["c", "b", "a"])
        XCTAssertEqual(voices.map(\.id), [1, 2, 3])
        XCTAssertNil(voices[0].suggestedName)
    }

    func testTwoSpeakersOfOneMeetingAreNeverOneVoice() {
        let voices = VoiceReview.group([occ("a", "SPEAKER_00", v(0)), occ("a", "SPEAKER_01", v(0, tilt: 0.05))],
                                       store: VoiceProfileStore(model: "m"))
        XCTAssertEqual(voices.count, 2)
    }

    func testARememberedVoiceIsProposedByName() {
        var store = VoiceProfileStore(model: "m")
        store.enrol(name: "Petra Novak", sample: v(1), now: t0)
        let voices = VoiceReview.group([occ("a", "SPEAKER_00", v(1, tilt: 0.1)), occ("a", "SPEAKER_01", v(3))], store: store)
        XCTAssertEqual(Set(voices.map(\.suggestedName)), ["Petra Novak", nil])
    }

    func testNamingAVoiceRenamesEveryMeetingAndRemembersIt() throws {
        let root = TestTemp.root.appendingPathComponent("distavo-review-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        for base in ["a", "b", "c"] {
            try "# Call\n\nSPEAKER_01 said the pipes are late.\n".write(to: notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
            try "[SPEAKER_00]\nHello.\n\n[SPEAKER_01]\nThe pipes are late.\n"
                .write(to: Pipeline.cachedTranscriptURL(workDir: work, base: base), atomically: true, encoding: .utf8)
            // In "c" the other speaker already carries the name.
            try TranscriptSegments(segments: [seg(base == "c" ? "Petra Novak" : "SPEAKER_00", 0, 20), seg("SPEAKER_01", 20, 45)])
                .save(workDir: work, base: base)
        }
        var store = VoiceProfileStore(model: "m")
        let voice = VoiceReview.Voice(id: 1, occurrences: [occ("a", "SPEAKER_01", v(1)), occ("b", "SPEAKER_01", v(1, tilt: 0.1)),
                                                           occ("c", "SPEAKER_01", v(1))], suggestedName: nil)
        let r = VoiceReview.apply(voice: voice, name: " Petra Novak ", remember: true, notesDir: notes, workDir: work, store: &store, now: t0)
        XCTAssertEqual(r.renamed, ["a", "b"])
        XCTAssertEqual(r.skipped, ["c": "already has a speaker called Petra Novak"])
        XCTAssertTrue(r.remembered)
        XCTAssertEqual(store.profiles.map(\.name), ["Petra Novak"])
        XCTAssertEqual(store.profiles[0].enrolments, 2)
        XCTAssertTrue(try String(contentsOf: notes.appendingPathComponent("b.md"), encoding: .utf8).contains("Petra Novak said the pipes are late."))
        XCTAssertEqual(SpeakerNames.load(workDir: work, base: "a")?.names["SPEAKER_01"], "Petra Novak")
        // Without "remember" nothing reaches the store; a label is not a name.
        var empty = VoiceProfileStore(model: "m")
        let again = VoiceReview.apply(voice: voice, name: "Petra Novak", remember: false, notesDir: notes, workDir: work, store: &empty, now: t0)
        XCTAssertTrue(again.renamed.isEmpty && empty.profiles.isEmpty)
        XCTAssertEqual(again.skipped["a"], "that speaker was renamed meanwhile")
        XCTAssertTrue(VoiceReview.apply(voice: voice, name: "SPEAKER_05", remember: true, notesDir: notes, workDir: work, store: &empty).renamed.isEmpty)
    }
}
