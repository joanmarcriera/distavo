import XCTest
@testable import DistavoCore

/// Objectives and people typed in Quick Notes while recording. Synthetic names only.
final class ScratchpadPeopleTests: XCTestCase {
    func testAnObjectiveIsAMustIncludeLine() {
        XCTAssertEqual(ScratchpadNotes.objective("  agree the delivery date ", offsetSeconds: 12),
                       .init(offsetSeconds: 12, text: "Objective: agree the delivery date", flagged: true))
        XCTAssertNil(ScratchpadNotes.objective("   ", offsetSeconds: 0))
        let pad = ScratchpadNotes(lines: [ScratchpadNotes.objective("agree the date", offsetSeconds: 5)!])
        XCTAssertTrue(pad.promptBlock().contains("[MUST INCLUDE] 00:05 - Objective: agree the date"))
        XCTAssertTrue(pad.highlightsSection().contains("- ⭐ **00:05** Objective: agree the date"))
    }

    func testPeopleNeverReachThePromptAndLeaveItByteIdentical() {
        let lines = [ScratchpadNotes.Line(offsetSeconds: 3, text: "ask about notice period")]
        XCTAssertEqual(ScratchpadNotes(lines: lines, people: "Anna (Acme) - buyer").promptBlock(),
                       ScratchpadNotes(lines: lines).promptBlock())
        let only = ScratchpadNotes(people: "Anna (Acme) - buyer")
        XCTAssertEqual(only.promptBlock(), "")
        XCTAssertTrue(only.isEmpty)          // no highlights asked of the model
        XCTAssertTrue(only.hasContent)       // but worth keeping on disk
        XCTAssertEqual(only.ensureHighlights(in: "# Meeting notes\n\nBody\n"), "# Meeting notes\n\nBody\n")
    }

    func testPeopleAreCleanedAndSurviveTheSidecar() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pad-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ScratchpadNotes(people: " Anna {Acme}\nPere  Puig ").save(workDir: dir, base: "m")
        XCTAssertEqual(ScratchpadNotes.load(workDir: dir, base: "m")?.people, "Anna (Acme), Pere Puig")
        XCTAssertNil(ScratchpadNotes(people: "  \n ").cleanPeople)
        XCTAssertFalse(ScratchpadNotes(people: " ").hasContent)
        XCTAssertEqual(ScratchpadNotes(people: String(repeating: "a", count: 500)).cleanPeople?.count, ScratchpadNotes.maxPeopleChars)
    }

    func testASidecarWithoutPeopleIsUnchangedOnDisk() throws {
        let lines = [ScratchpadNotes.Line(offsetSeconds: 3, text: "one")]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(decoding: try encoder.encode(ScratchpadNotes(lines: lines)), as: UTF8.self)
        XCTAssertFalse(json.contains("people"))
        let old = #"{"version":1,"lines":[{"offsetSeconds":3,"text":"one","flagged":false}]}"#
        XCTAssertNil(try JSONDecoder().decode(ScratchpadNotes.self, from: Data(old.utf8)).people)
    }
}

final class PrefilledCountTests: XCTestCase {
    func testAnUntouchedSuggestionNeverSetsTheCount() {
        let listed = "Other participants: Anna (Acme), Pere"
        XCTAssertEqual(SpeakerHints.prefilledCount(participants: listed, ownerGaveTheList: true), 3)
        XCTAssertNil(SpeakerHints.prefilledCount(participants: listed, ownerGaveTheList: false))
        XCTAssertNil(SpeakerHints.prefilledCount(participants: "Other participants: ", ownerGaveTheList: true))
        XCTAssertEqual(SpeakerHints.suggestedCount(listed), 3)   // unchanged for its other callers
    }
}
