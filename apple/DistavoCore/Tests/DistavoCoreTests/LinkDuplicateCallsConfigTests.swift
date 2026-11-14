import XCTest
@testable import DistavoCore

/// Review B (drive-review-2026-11-09, finding 5): `notes.link_duplicate_calls` switches the "same call captured
/// twice" linking (#4014). Off for a config that predates the key; on for fresh installs. Off means no `.call.json`
/// and no `.also-captured.json` sidecars, no footer line and no sheet copy. Synthetic names and times only.
final class LinkDuplicateCallsConfigTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!
    private var work: URL { root.appendingPathComponent("work") }
    private var notes: URL { root.appendingPathComponent("notes") }

    override func setUp() {
        root = TestTemp.root.appendingPathComponent("ldc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("recordings"), withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    // MARK: config

    func testKeyIsOffForOldConfigsAndOnForFreshInstalls() throws {
        XCTAssertFalse(NotesConfig().linkDuplicateCalls)
        XCTAssertFalse(try JSONDecoder().decode(NotesConfig.self, from: Data("{}".utf8)).linkDuplicateCalls)
        XCTAssertFalse(try JSONDecoder().decode(Config.self, from: Data("{\"notes\":{\"frontmatter\":true}}".utf8)).notes.linkDuplicateCalls)
        XCTAssertTrue(try JSONDecoder().decode(NotesConfig.self, from: Data("{\"link_duplicate_calls\":true}".utf8)).linkDuplicateCalls)
        // A wrong-typed value falls back to off rather than failing the whole config.
        XCTAssertFalse(try JSONDecoder().decode(NotesConfig.self, from: Data("{\"link_duplicate_calls\":\"yes\"}".utf8)).linkDuplicateCalls)
        for supported in [true, false] {
            XCTAssertTrue(Config.recommendedForThisMac(embeddedSupported: supported, memoryBytes: 16 << 30)
                .notes.linkDuplicateCalls, "embeddedSupported=\(supported)")
        }
        let enc = try JSONEncoder().encode(NotesConfig())
        XCTAssertTrue(String(decoding: enc, as: UTF8.self).contains("\"link_duplicate_calls\":false"))
    }

    // MARK: pipeline

    private func config(link: Bool) -> Config {
        var cfg = Config()
        cfg.recordingsDir = root.appendingPathComponent("recordings").path
        cfg.notesDir = notes.path
        cfg.workDir = work.path
        cfg.notes.linkDuplicateCalls = link
        return cfg
    }

    private func deps() -> PipelineDeps {
        let start = t0
        return PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in ["segments": [["speaker": "SPEAKER_00", "text": "hello world"]]] },
            ollamaReachable: { _ in true },
            summarise: { _, _, _, _ in PipelineTests.validNote },
            audioDurationSeconds: { _ in 1800 },
            recordingStart: { _ in start })
    }

    /// Two files of one call: the Mac recorder's (name = start) and a dropped phone file with the same start.
    private func processBoth(link: Bool) async throws -> (mac: String, phone: String, macBase: String, phoneBase: String) {
        let rec = root.appendingPathComponent("recordings")
        let mac = rec.appendingPathComponent("Meeting 2026-10-05 10.00.00.wav")
        let phone = rec.appendingPathComponent("phone memo.m4a")
        for u in [mac, phone] { try Data([0, 1, 2, 3]).write(to: u) }
        let cfg = config(link: link)
        let macBase = DistavoState.baseFor(recordingsDir: rec, path: mac)
        let phoneBase = DistavoState.baseFor(recordingsDir: rec, path: phone)
        // The sheet the Mac capture was answered with: a linked twin would inherit it.
        try SpeakerHints(participants: "Alex (me), Sam").save(workDir: work, base: macBase)
        for u in [mac, phone] {
            let r = await Pipeline.processOne(path: u, config: cfg, deps: deps(), stableChecks: 1, stableDelay: 0)
            XCTAssertEqual(r.status, .done, r.message)
        }
        func note(_ b: String) throws -> String { try String(contentsOf: notes.appendingPathComponent("\(b).md"), encoding: .utf8) }
        return (try note(macBase), try note(phoneBase), macBase, phoneBase)
    }

    func testOffWritesNoSidecarsNoFooterLineAndNoSheetCopy() async throws {
        let r = try await processBoth(link: false)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        XCTAssertFalse(names.contains { $0.hasSuffix(".call.json") || $0.hasSuffix(".also-captured.json") }, "\(names)")
        XCTAssertFalse(r.mac.contains("Also captured"), r.mac)
        XCTAssertFalse(r.phone.contains("Also captured"), r.phone)
        XCTAssertNil(SpeakerHints.load(workDir: work, base: r.phoneBase), "no sheet is copied to the second file")
    }

    func testOnLinksTheTwinAndCopiesTheSheet() async throws {
        let r = try await processBoth(link: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        XCTAssertTrue(names.contains { $0.hasSuffix(".call.json") }, "\(names)")
        XCTAssertTrue(names.contains { $0.hasSuffix(".also-captured.json") }, "\(names)")
        XCTAssertTrue(r.phone.contains("Also captured as \(r.macBase)"), r.phone)
        XCTAssertEqual(SpeakerHints.load(workDir: work, base: r.phoneBase)?.participants, "Alex (me), Sam")
    }

    // MARK: dropped-file sheet

    func testSheetPrefillCopiesATwinSheetOnlyWhenLinkingIsOn() throws {
        let mac = CallRecord(base: "Meeting_x", time: t0, durationSeconds: 2400, isLiveCapture: true)
        try DuplicateCallLink.saveRecord(mac, workDir: work)
        try SpeakerHints(count: 2, participants: "Alex (me): candidate. Other participants: Sam").save(workDir: work, base: "Meeting_x")
        let dropped = CallRecord(base: "interview-x", time: t0.addingTimeInterval(30), durationSeconds: 2390, isLiveCapture: false)
        XCTAssertEqual(DroppedFileSheet.prefill(workDir: work, base: dropped.base, record: dropped, linkDuplicateCalls: true).source,
                       .twin(base: "Meeting_x"))
        XCTAssertNotEqual(DroppedFileSheet.prefill(workDir: work, base: dropped.base, record: dropped, linkDuplicateCalls: false).source,
                          .twin(base: "Meeting_x"))
    }
}
