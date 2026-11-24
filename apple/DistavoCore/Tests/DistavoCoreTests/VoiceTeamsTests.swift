import XCTest
@testable import DistavoCore

final class VoiceTeamsTests: XCTestCase {
    private func unit(_ a: Float, _ b: Float, _ c: Float = 0) -> [Float] { VoiceProfileStore.normalised([a, b, c])! }

    /// Anna and Aina sound alike; Pere is distinct. Anna meets with Pere, Aina never does.
    private func store() -> VoiceProfileStore {
        var s = VoiceProfileStore(model: VoiceProfileStore.builtInModel)
        XCTAssertTrue(s.enrol(name: "Anna", sample: unit(1, 0.10), now: Date()))
        XCTAssertTrue(s.enrol(name: "Aina", sample: unit(1, -0.10), now: Date()))
        XCTAssertTrue(s.enrol(name: "Pere", sample: unit(0, 0, 1), now: Date()))
        return s
    }
    private let speakers: [String: [Float]] = ["SPEAKER_00": [0, 0, 1], "SPEAKER_01": [1, 0.02, 0]]

    func testCountsMeetingsAndPairs() {
        let t = VoiceTeams(meetings: [["Anna", "Pere"], ["anna", "Pere", "SPEAKER_02"], ["Aina"]])
        XCTAssertEqual(t.meetings["anna"], 2)
        XCTAssertEqual(t.together["anna"]?["pere"], 2)
        XCTAssertNil(t.meetings["speaker_02"])
        XCTAssertEqual(t.weight("Aina", with: ["Pere"]), 0)
        XCTAssertEqual(t.weight("Aina", with: []), 1)
    }

    func testWithoutATeamACloseVoiceStaysUnnamed() {
        let m = store().match(speakers: speakers)
        XCTAssertEqual(m["SPEAKER_00"]?.name, "Pere")
        XCTAssertNil(m["SPEAKER_01"])
    }

    func testTheTeamSettlesACloseVoice() {
        let team = VoiceTeams(meetings: [["Anna", "Pere"], ["Anna", "Pere"], ["Aina", "Joan"]])
        let m = store().match(speakers: speakers, team: team)
        XCTAssertEqual(m["SPEAKER_01"]?.name, "Anna")
        XCTAssertEqual(m["SPEAKER_01"]?.byTeam, true)
        XCTAssertEqual(m["SPEAKER_00"]?.byTeam, false)
    }

    func testAnUnclearTeamLeavesItUnnamed() {
        // Once together is not enough; and 3 against 2 is not a clear lead.
        XCTAssertNil(store().match(speakers: speakers, team: VoiceTeams(meetings: [["Anna", "Pere"]]))["SPEAKER_01"])
        let even = VoiceTeams(meetings: [["Anna", "Pere"], ["Anna", "Pere"], ["Anna", "Pere"], ["Aina", "Pere"], ["Aina", "Pere"]])
        XCTAssertNil(store().match(speakers: speakers, team: even)["SPEAKER_01"])
    }

    func testTheTeamNeverNamesAVoiceUnderTheThreshold() {
        let team = VoiceTeams(meetings: [["Anna", "Pere"], ["Anna", "Pere"]])
        let far: [String: [Float]] = ["SPEAKER_00": [0, 0, 1], "SPEAKER_01": [1, 2, 0]]   // 0.5 to Anna, 0.36 to Aina
        XCTAssertNil(store().match(speakers: far, team: team)["SPEAKER_01"])
    }

    func testWithNobodyRecognisedTotalMeetingsDecide() {
        let team = VoiceTeams(meetings: [["Anna"], ["Anna"], ["Anna"], ["Aina"]])
        XCTAssertEqual(store().match(speakers: ["SPEAKER_01": [1, 0.02, 0]], team: team)["SPEAKER_01"]?.name, "Anna")
    }

    func testLoadReadsConfirmedNamesAndSkipsTheCurrentRecording() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("teams-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (base, names) in [("a", ["SPEAKER_00": "Anna", "SPEAKER_01": "Pere"]), ("b", ["SPEAKER_00": "Anna", "SPEAKER_01": "Pere"])] {
            try SpeakerNames(names: names).encoded().write(to: SpeakerNames.url(workDir: dir, base: base))
        }
        XCTAssertEqual(VoiceTeams.load(workDir: dir).together["anna"]?["pere"], 2)
        XCTAssertEqual(VoiceTeams.load(workDir: dir, excluding: "b").together["anna"]?["pere"], 1)
    }

    func testVoiceGuessesAreNotEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guess-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        for base in ["Meeting_2026-11-18_09.00.00", "Meeting_2026-11-19_09.00.00"] {
            try "# Call\n\nText.\n".write(to: notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
        }
        // 18th: the owner named Anna. 19th: recognition named Anna and Pere; nobody confirmed.
        try SpeakerNames(names: ["SPEAKER_00": "Anna"]).encoded().write(to: SpeakerNames.url(workDir: work, base: "Meeting_2026-11-18_09.00.00"))
        try SpeakerNames(names: ["SPEAKER_00": "Anna", "SPEAKER_01": "Pere"], byVoice: ["Anna", "Pere"]).encoded()
            .write(to: SpeakerNames.url(workDir: work, base: "Meeting_2026-11-19_09.00.00"))
        let team = VoiceTeams.load(workDir: work)
        XCTAssertEqual(team.meetings["anna"], 1)
        XCTAssertNil(team.meetings["pere"])
        XCTAssertNil(team.together["anna"]?["pere"])
        // People pages: Anna gains the meeting, marked as recognised; Pere, never confirmed, gets no page.
        let people = PeoplePages.collect(notesDir: notes, workDir: work)
        XCTAssertEqual(people.map(\.name), ["Anna"])
        XCTAssertEqual(people[0].meetings.map(\.byVoice), [true, false])
        XCTAssertTrue(PeoplePages.meetingsBlock(people[0], linkedin: "x", organisation: nil, timeZone: .current).contains("· recognised by voice\n"))
        // An old sidecar (no by_voice key) reads as confirmed.
        let old = #"{"version":1,"names":{"SPEAKER_00":"Anna"}}"#
        XCTAssertNil(try JSONDecoder().decode(SpeakerNames.self, from: Data(old.utf8)).byVoice)
    }

    func testFooterSaysWhichNameTheTeamSettled() {
        XCTAssertEqual(VoiceRecognition.footerNote(names: ["Pere", "Anna"], byTeam: ["Anna"]),
                       "Speakers named from remembered voices: Anna (close to another voice; chosen by who they usually meet with), Pere (Rename Speakers can change or reset them).")
        XCTAssertEqual(VoiceRecognition.footerNote(names: ["Pere"]),
                       "Speakers named from remembered voices: Pere (Rename Speakers can change or reset them).")
    }
}
