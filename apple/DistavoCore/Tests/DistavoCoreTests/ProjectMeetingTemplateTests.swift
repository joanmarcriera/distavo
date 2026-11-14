import XCTest
@testable import DistavoCore

/// Vikunja #6666: with `summary_template: none` a 13-person deployment meeting got the job-search sections
/// (Opportunity, Role expectations, Compensation, follow-up email). A bundled `project_meeting` template, an
/// `auto` rule for it, and a neutral default (opt-in, so the unset prompt stays byte-identical).
final class ProjectMeetingTemplateTests: XCTestCase {

    private let jobSearchHeadings = ["Role expectations", "Commercial and compensation discussion",
                                     "Suggested follow-up email", "Opportunity or purpose",
                                     "Highest-ROI follow-up"]

    // MARK: the bundled template

    func testProjectMeetingTemplateHasTheSixSections() throws {
        let t = try XCTUnwrap(SummaryTemplateCatalog.template(id: "project_meeting", config: Config()))
        XCTAssertEqual(t.headings, ["## Context", "## Decisions", "## Actions", "## Risks and issues",
                                    "## Open questions", "## Next meeting"])
        XCTAssertEqual(SummaryTemplateCatalog.projectMeetingID, "project_meeting")
    }

    func testProjectMeetingPromptHasNoJobSearchShape() throws {
        let t = try XCTUnwrap(SummaryTemplateCatalog.template(id: "project_meeting", config: Config()))
        for style in [Prompt.Style.classic, .factsFirst] {
            let p = Prompt.build(transcript: "x", noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                                 style: style, template: t)
            for h in jobSearchHeadings { XCTAssertFalse(p.contains("## \(h)"), "\(style): \(h)") }
            XCTAssertTrue(p.contains("## Risks and issues"))
            XCTAssertFalse(p.contains("The suggested email is written BY"), "rule for a dropped section stays out")
        }
    }

    // MARK: auto

    func testAutoPicksProjectMeetingForDeploymentTalk() {
        let who = "The note owner (me). Other participants: the deployment team, 12 people, runbooks review"
        let pick = TemplateAutoPick.pick(participants: who, transcript: "")
        XCTAssertEqual(pick?.id, "project_meeting")
        XCTAssertTrue(pick?.reason.contains("deployment") == true, pick?.reason ?? "")
    }

    func testAutoUsesTheStartOfTheTranscript() {
        let start = "Welcome all to the project kickoff. The deployment runbooks are in the team wiki."
        XCTAssertEqual(TemplateAutoPick.pick(participants: nil, transcript: start)?.id, "project_meeting")
    }

    func testAFewEverydayWordsInTheTranscriptAreNotEnough() {
        XCTAssertNil(TemplateAutoPick.pick(participants: nil, transcript: "Thanks everyone, the team did well on that project.")?.id)
    }

    func testAutoNeverPicksProjectMeetingWhenInterviewWordsAppear() {
        let who = "Other participants: a recruiter about a project deployment role"
        XCTAssertNotEqual(TemplateAutoPick.pick(participants: who, transcript: "")?.id, "project_meeting")
        XCTAssertNotEqual(TemplateAutoPick.pick(participants: "project deployment team, hiring", transcript: "")?.id, "project_meeting")
        let start = "Thanks for coming to the interview. Tell me about the last deployment project you ran, candidate."
        XCTAssertNotEqual(TemplateAutoPick.pick(participants: nil, transcript: start)?.id, "project_meeting")
    }

    func testAutoResolverReturnsTheTemplateAndFooter() {
        var c = Config(); c.summarise.template = "auto"
        let r = SummaryTemplateCatalog.resolveWithReason(
            config: c, participants: "project deployment team")
        XCTAssertEqual(r.template?.id, "project_meeting")
        XCTAssertTrue(r.note?.hasPrefix("Template: Project meeting (auto, matched") == true, r.note ?? "")
    }

    // MARK: neutral default

    func testNeutralDefaultIsOffForAnOldConfigAndOnForFreshInstalls() throws {
        XCTAssertFalse(SummariseConfig().neutralDefault)
        let old = try JSONDecoder().decode(SummariseConfig.self, from: Data("{}".utf8))
        XCTAssertFalse(old.neutralDefault)
        XCTAssertTrue(Config.recommendedForThisMac(embeddedSupported: true, memoryBytes: 32 << 30).summarise.neutralDefault)
        let enc = try JSONEncoder().encode(SummariseConfig())
        XCTAssertTrue(String(decoding: enc, as: UTF8.self).contains("\"neutral_default\""))
    }

    func testNoneWithTheFlagOffKeepsTheStockPrompt() {
        let c = Config()   // flag off
        XCTAssertNil(SummaryTemplateCatalog.resolve(config: c, sidecarID: "none"))
        XCTAssertNil(SummaryTemplateCatalog.resolve(config: c))
    }

    func testNoneWithTheFlagOnGivesNeutralSectionsWithoutJobSearch() throws {
        var c = Config(); c.summarise.neutralDefault = true
        for sidecar in ["none", nil, "no-such-id"] as [String?] {
            let t = try XCTUnwrap(SummaryTemplateCatalog.resolve(config: c, sidecarID: sidecar), "\(sidecar ?? "nil")")
            XCTAssertEqual(t.id, SummaryTemplateCatalog.neutralID)
            for style in [Prompt.Style.classic, .factsFirst] {
                let p = Prompt.build(transcript: "x", noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                                     style: style, template: t)
                for h in jobSearchHeadings { XCTAssertFalse(p.contains("## \(h)"), "\(style): \(h)") }
                XCTAssertTrue(p.contains("## Executive summary") && p.contains("## Decisions made")
                              && p.contains("## Action items"))
            }
        }
    }

    func testAutoWithNothingToGoOnFallsToNeutralWhenTheFlagIsOn() {
        var c = Config(); c.summarise.template = "auto"; c.summarise.neutralDefault = true
        XCTAssertEqual(SummaryTemplateCatalog.resolve(config: c, participants: "Anna")?.id, "neutral")
        c.summarise.neutralDefault = false
        XCTAssertNil(SummaryTemplateCatalog.resolve(config: c, participants: "Anna"))
    }

    func testNamedTemplatesAreNeverOverriddenByTheNeutralDefault() {
        var c = Config(); c.summarise.neutralDefault = true; c.summarise.template = "interview"
        XCTAssertEqual(SummaryTemplateCatalog.resolve(config: c)?.id, "interview")
    }

    func testNeutralIsNotInThePicker() {
        XCTAssertFalse(SummaryTemplateCatalog.bundledTemplates.contains { $0.id == SummaryTemplateCatalog.neutralID })
        XCTAssertNil(SummaryTemplateCatalog.template(id: "neutral", config: Config()),
                     "an explicit sidecar id 'neutral' is unknown: only the fallback uses it")
    }

    func testRegenerateNoneAlsoGetsNeutralWhenOn() throws {
        var c = Config(); c.summarise.neutralDefault = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var o = RegenerateOptions(); o.templateID = "none"
        let r = Pipeline.regenerateTemplate(options: o, config: c, workDir: dir, sourceBase: "b", sourcePath: nil)
        XCTAssertEqual(r.template?.id, "neutral")
    }
}
