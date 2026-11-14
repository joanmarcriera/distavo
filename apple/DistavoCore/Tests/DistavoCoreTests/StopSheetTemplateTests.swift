import XCTest
@testable import DistavoCore

/// Vikunja #6667: the stop sheet offers Auto first and never preselects a stale global template.
final class StopSheetTemplateTests: XCTestCase {

    private func config(_ edit: (inout Config) -> Void = { _ in }) -> Config { var c = Config(); edit(&c); return c }

    func testAutoIsFirstAndSettingsRowSecond() {
        let rows = StopSheetTemplate.choices(config: config { $0.summarise.template = "interview" })
        XCTAssertEqual(rows[0].value, "auto")
        XCTAssertNil(rows[1].value)
        XCTAssertEqual(rows[1].title, "Default from Settings (Interview)")
        XCTAssertEqual(rows[2].value, "none")
        XCTAssertTrue(rows.contains { $0.value == "project_meeting" })
        XCTAssertNil(rows.first { $0.value == "custom" }, "no Custom row without usable custom text")
        let withCustom = StopSheetTemplate.choices(config: config { $0.summarise.customTemplate = "## A" })
        XCTAssertEqual(withCustom.last?.value, "custom")
    }

    func testAStaleSettingsTemplateIsNotPreselected() {
        let c = config { $0.summarise.template = "interview" }
        XCTAssertEqual(StopSheetTemplate.preselectedIndex(config: c, folder: "", lastPicks: [:]), 0)
        XCTAssertEqual(StopSheetTemplate.preselectedIndex(config: config(), folder: "", lastPicks: [:]), 0)
    }

    func testFolderRuleThenLastPick() {
        let c = config { $0.summarise.folderTemplates = ["Clients": "consultancy"] }
        let rows = StopSheetTemplate.choices(config: c, folder: "Clients")
        let i = StopSheetTemplate.preselectedIndex(config: c, folder: "Clients", lastPicks: [:])
        XCTAssertEqual(rows[i].value, "consultancy")
        // the owner's last pick for that folder beats the rule
        let j = StopSheetTemplate.preselectedIndex(config: c, folder: "clients", lastPicks: ["clients": "standup"])
        XCTAssertEqual(StopSheetTemplate.choices(config: c, folder: "clients")[j].value, "standup")
        // another folder is unaffected
        XCTAssertEqual(StopSheetTemplate.preselectedIndex(config: c, folder: "Home", lastPicks: ["clients": "standup"]), 0)
    }

    func testAVanishedPickFallsBackToAuto() {
        // "custom" is remembered but the custom text was since emptied
        XCTAssertEqual(StopSheetTemplate.preselectedIndex(config: config(), folder: "x", lastPicks: ["x": "custom"]), 0)
        XCTAssertEqual(StopSheetTemplate.preselectedIndex(config: config(), folder: "x", lastPicks: ["x": "bogus"]), 0)
    }

    func testTheRecordingsRootNeverRemembersAPick() {
        XCTAssertTrue(StopSheetTemplate.remembering("interview", folder: "", in: [:]).isEmpty)
        XCTAssertEqual(StopSheetTemplate.preselectedIndex(config: config(), folder: "", lastPicks: ["": "interview"]), 0)
    }

    func testRememberingAndForgetting() {
        var picks = StopSheetTemplate.remembering("Standup", folder: "Team/Daily", in: [:])
        XCTAssertEqual(picks, ["team/daily": "standup"])
        picks = StopSheetTemplate.remembering(nil, folder: "TEAM/daily/", in: picks)
        XCTAssertTrue(picks.isEmpty)
    }

    func testValueToSave() {
        let rows = StopSheetTemplate.choices(config: config())
        XCTAssertEqual(StopSheetTemplate.valueToSave(choices: rows, selectedIndex: 0), "auto")
        XCTAssertNil(StopSheetTemplate.valueToSave(choices: rows, selectedIndex: 1))
        XCTAssertNil(StopSheetTemplate.valueToSave(choices: rows, selectedIndex: 99))
    }

    // MARK: hint

    private func used(_ n: Int, id: String, who: String) -> [StopSheetTemplate.UsedRecording] {
        Array(repeating: .init(templateID: id, participants: who), count: n)
    }

    func testHintAfterFiveRecordingsWithoutInterviewWords() throws {
        let c = config { $0.summarise.template = "interview" }
        let h = try XCTUnwrap(StopSheetTemplate.hint(config: c, recent: used(5, id: "interview", who: "Anna, Bernat from the platform team")))
        XCTAssertTrue(h.contains("Interview") && h.contains("5"), h)
        XCTAssertNil(StopSheetTemplate.hint(config: c, recent: used(4, id: "interview", who: "Anna")))
    }

    func testNoHintWhenOneRecordingLooksLikeAnInterview() {
        let c = config { $0.summarise.template = "interview" }
        let recent = used(4, id: "interview", who: "Anna") + used(1, id: "interview", who: "a recruiter, Sam")
        XCTAssertNil(StopSheetTemplate.hint(config: c, recent: recent))
    }

    func testNoHintForAutoNoneOrUnsetOrOtherTemplatesUsed() {
        for t in ["", "auto", "none", "bogus"] {
            XCTAssertNil(StopSheetTemplate.hint(config: config { $0.summarise.template = t },
                                                recent: used(9, id: t, who: "Anna")), t)
        }
        XCTAssertNil(StopSheetTemplate.hint(config: config { $0.summarise.template = "interview" },
                                            recent: used(9, id: "standup", who: "Anna")))
    }

    // MARK: log line

    func testLogLineNamesTheTemplate() throws {
        let t = try XCTUnwrap(SummaryTemplateCatalog.template(id: "project_meeting", config: Config()))
        XCTAssertEqual(StopSheetTemplate.logLine(base: "Meeting_1", template: t, autoNote: nil),
                       "Summary template for Meeting_1: Project meeting")
        XCTAssertEqual(StopSheetTemplate.logLine(base: "Meeting_1", template: t,
                                                 autoNote: "Template: Project meeting (auto, matched project, team)"),
                       "Summary template for Meeting_1: Project meeting (auto, matched project, team)")
        XCTAssertEqual(StopSheetTemplate.logLine(base: "M", template: nil, autoNote: nil),
                       "Summary template for M: standard notes")
    }
}
