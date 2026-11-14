import XCTest
@testable import DistavoCore

/// Vikunja #4012, core half: when a file dropped into the watch folder should get the participants sheet and
/// what the sheet starts with. Synthetic bases, times and names only.
final class DroppedFileSheetTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var dir: URL!
    var src: URL!
    override func setUp() {
        dir = TestTemp.root.appendingPathComponent("dfs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        src = dir.appendingPathComponent("watch/interview-x.m4a")
        try? FileManager.default.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private var work: URL { dir.appendingPathComponent("work") }

    // MARK: decide

    func testDroppedFileWithoutASheetIsOffered() {
        XCTAssertEqual(DroppedFileSheet.decide(workDir: work, base: "interview-x", source: src, isLiveCapture: false), .offer)
    }

    func testAnswerInTheWorkDirSkips() throws {
        try SpeakerHints(count: 2, participants: "Alex (me)").save(workDir: work, base: "interview-x")
        XCTAssertEqual(DroppedFileSheet.decide(workDir: work, base: "interview-x", source: src, isLiveCapture: false),
                       .skip(.answered))
    }

    func testSidecarBesideTheFileSkips() throws {
        let beside = src.deletingPathExtension().appendingPathExtension("speakers.json")
        try JSONEncoder().encode(SpeakerHints(participants: "Alex (me)")).write(to: beside)
        XCTAssertEqual(DroppedFileSheet.decide(workDir: work, base: "interview-x", source: src, isLiveCapture: false),
                       .skip(.answered))
    }

    func testAnEmptyAnswerDoesNotCountAsAnswered() throws {
        try SpeakerHints().save(workDir: work, base: "interview-x")
        XCTAssertEqual(DroppedFileSheet.decide(workDir: work, base: "interview-x", source: src, isLiveCapture: false), .offer)
    }

    func testLiveCaptureHasItsOwnSheet() {
        XCTAssertEqual(DroppedFileSheet.decide(workDir: work, base: "Meeting_x", source: src, isLiveCapture: true),
                       .skip(.liveCapture))
    }

    func testOfferedOnceOnly() {
        XCTAssertTrue(DroppedFileSheet.markOffered(workDir: work, base: "interview-x"))
        XCTAssertEqual(DroppedFileSheet.decide(workDir: work, base: "interview-x", source: src, isLiveCapture: false),
                       .skip(.alreadyOffered))
        XCTAssertEqual(DroppedFileSheet.decide(workDir: work, base: "other", source: src, isLiveCapture: false), .offer)
    }

    func testMarkOfferedReportsAFailedWrite() throws {
        // A regular file where the work dir should be: the directory cannot be created.
        let blocker = dir.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        XCTAssertFalse(DroppedFileSheet.markOffered(workDir: blocker.appendingPathComponent("w"), base: "x"))
    }

    // MARK: prefill

    func testPrefillCopiesTheSheetOfAnOverlappingMacCapture() throws {
        let mac = CallRecord(base: "Meeting_x", time: t0, durationSeconds: 2400, isLiveCapture: true)
        try DuplicateCallLink.saveRecord(mac, workDir: work)
        try SpeakerHints(count: 2, participants: "Alex (me): candidate. Other participants: Sam", terms: ["Zeta"])
            .save(workDir: work, base: "Meeting_x")
        let dropped = CallRecord(base: "interview-x", time: t0.addingTimeInterval(30), durationSeconds: 2390, isLiveCapture: false)
        let p = DroppedFileSheet.prefill(workDir: work, base: dropped.base, record: dropped, linkDuplicateCalls: true)
        XCTAssertEqual(p.source, .twin(base: "Meeting_x"))
        XCTAssertEqual(p.hints.participants, "Alex (me): candidate. Other participants: Sam")
        XCTAssertEqual(p.hints.count, 2)
        XCTAssertEqual(p.hints.terms, ["Zeta"])
        XCTAssertNotNil(p.sourceLine)
    }

    func testAnOverlapThatStartsFarApartIsNotCopied() throws {
        // A memo started 5 minutes into a call: the call overlaps it, but they are not the same capture.
        try DuplicateCallLink.saveRecord(
            CallRecord(base: "Meeting_x", time: t0, durationSeconds: 2400, isLiveCapture: true), workDir: work)
        try SpeakerHints(participants: "Other participants: Sam").save(workDir: work, base: "Meeting_x")
        let dropped = CallRecord(base: "memo", time: t0.addingTimeInterval(300), durationSeconds: 1800, isLiveCapture: false)
        let p = DroppedFileSheet.prefill(workDir: work, base: dropped.base, record: dropped, linkDuplicateCalls: true)
        XCTAssertEqual(p.source, .recent, "names come as a suggestion only")
        XCTAssertNil(p.hints.count, "the speaker count of the other call is not copied")
    }

    func testASheetlessBetterOverlapDoesNotHideTheTwinWithASheet() throws {
        try DuplicateCallLink.saveRecord(
            CallRecord(base: "nosheet", time: t0, durationSeconds: 3000, isLiveCapture: true), workDir: work)
        try DuplicateCallLink.saveRecord(
            CallRecord(base: "Meeting_y", time: t0.addingTimeInterval(60), durationSeconds: 2400, isLiveCapture: true), workDir: work)
        try SpeakerHints(count: 3, participants: "Other participants: Kim").save(workDir: work, base: "Meeting_y")
        let dropped = CallRecord(base: "d", time: t0, durationSeconds: 2900, isLiveCapture: false)
        XCTAssertEqual(DroppedFileSheet.prefill(workDir: work, base: "d", record: dropped, linkDuplicateCalls: true).source, .twin(base: "Meeting_y"))
    }

    func testATwinWithAnEmptySheetIsNotUsed() throws {
        try DuplicateCallLink.saveRecord(
            CallRecord(base: "Meeting_x", time: t0, durationSeconds: 2400, isLiveCapture: true), workDir: work)
        try SpeakerHints().save(workDir: work, base: "Meeting_x")
        let dropped = CallRecord(base: "interview-x", time: t0, durationSeconds: 2400, isLiveCapture: false)
        XCTAssertEqual(DroppedFileSheet.prefill(workDir: work, base: "interview-x", record: dropped, linkDuplicateCalls: true).source, .none)
    }

    func testATwinWithoutAnAnswerIsNotUsed() throws {
        try DuplicateCallLink.saveRecord(
            CallRecord(base: "Meeting_x", time: t0, durationSeconds: 2400, isLiveCapture: true), workDir: work)
        let dropped = CallRecord(base: "interview-x", time: t0, durationSeconds: 2400, isLiveCapture: false)
        let p = DroppedFileSheet.prefill(workDir: work, base: dropped.base, record: dropped, linkDuplicateCalls: true)
        XCTAssertEqual(p.source, .none)
        XCTAssertTrue(p.hints.isEmpty)
        XCTAssertNil(p.sourceLine)
    }

    func testWithoutATwinTheRecentSheetsFillTheOwnerRoleAndPeople() throws {
        try SpeakerHints(participants: "Alex (me): candidate. Other participants: Sam, Robin").save(workDir: work, base: "older")
        let p = DroppedFileSheet.prefill(workDir: work, base: "interview-x", record: CallRecord(
            base: "interview-x", time: t0, durationSeconds: 900, isLiveCapture: false), linkDuplicateCalls: true)
        XCTAssertEqual(p.source, .recent)
        XCTAssertEqual(SpeakerSuggestions.others(in: p.hints.participants), "Sam, Robin")
        XCTAssertEqual(SpeakerSuggestions.role(in: p.hints.participants), "candidate")
        XCTAssertNil(p.hints.count, "the count is never guessed from history")
    }

    func testNoRecordAndNoHistoryGivesAnEmptyPrefill() {
        let p = DroppedFileSheet.prefill(workDir: work, base: "x", record: nil, linkDuplicateCalls: true)
        XCTAssertEqual(p.source, .none)
        XCTAssertTrue(p.hints.isEmpty)
    }

    func testPrefillNeverSuggestsFromItsOwnBase() throws {
        try SpeakerHints(participants: "Other participants: Pat").save(workDir: work, base: "interview-x")
        let p = DroppedFileSheet.prefill(workDir: work, base: "interview-x", record: CallRecord(
            base: "interview-x", time: t0, durationSeconds: 900, isLiveCapture: false), linkDuplicateCalls: true)
        // The base has its own answer; decide() would have skipped, and prefill must not echo it as "recent".
        XCTAssertEqual(p.source, .none)
    }

    // MARK: participants line (same wording the recorder sheet writes)

    func testParticipantsLineUsesTheMeFormThatRoleInReads() {
        XCTAssertEqual(DroppedFileSheet.participantsLine(owner: "Alex", role: "candidate", inPerson: false, others: "Sam"),
                       "Alex (me): candidate. Other participants: Sam")
        XCTAssertEqual(DroppedFileSheet.participantsLine(owner: "Me", role: "host", inPerson: false, others: ""),
                       "The note owner (me): host")
        XCTAssertEqual(DroppedFileSheet.participantsLine(owner: "", role: "", inPerson: true, others: ""),
                       "In-person meeting recorded with one microphone")
        XCTAssertNil(DroppedFileSheet.participantsLine(owner: "Alex", role: "", inPerson: false, others: " "))
    }
}
