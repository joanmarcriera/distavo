import XCTest
@testable import DistavoCore

/// Vikunja #2954: tracked terms yield a tag and a timestamped line.
final class TrackedTermsTests: XCTestCase {

    private let segs = TranscriptSegments(segments: [
        .init(start: 5, end: 9, text: "Welcome everyone, shall we start with the agenda?", speaker: "SPEAKER_00"),
        .init(start: 192.4, end: 200, text: "We moved the Slurm cluster to the new rack last week and the scheduler is fine.", speaker: "SPEAKER_01"),
        .init(start: 3725, end: 3730, text: "Any category of GDPR concern? The category is none, but SLURM again.", speaker: "SPEAKER_00"),
        .init(start: 3800, end: 3801, text: "The cat sat.", speaker: nil),
    ])

    func testTimedHitsWholeWordCaseInsensitive() {
        let reports = TrackedTerms.find(terms: ["slurm", "cat", "GDPR"], in: TrackedTerms.turns(from: segs))
        XCTAssertEqual(reports.map(\.term), ["slurm", "cat", "GDPR"])
        XCTAssertEqual(reports[0].hits.map(\.seconds), [192.4, 3725])
        XCTAssertEqual(reports[1].hits.count, 1, "cat must not match category")
        XCTAssertEqual(reports[1].hits[0].seconds, 3800)
        XCTAssertEqual(reports[2].hits.count, 1)
    }

    func testSectionLinesAreTimestampedWithContextAndSpeaker() {
        let text = TrackedTerms.section(TrackedTerms.find(terms: ["Slurm"], in: TrackedTerms.turns(from: segs)))
        XCTAssertTrue(text.hasPrefix("\n## Tracked terms\n\n"))
        XCTAssertTrue(text.contains("- [03:12] **Slurm** — \"We moved the Slurm cluster to the new rack last week and the…\" (SPEAKER_01)")
                      || text.contains("- [03:12] **Slurm** — \""), text)
        XCTAssertTrue(text.contains("- [1:02:05] **Slurm** — "), text)
        XCTAssertTrue(text.contains("(SPEAKER_00)"))
    }

    func testNoOccurrenceMeansNoSectionAndNoTag() {
        let reports = TrackedTerms.find(terms: ["Kubernetes"], in: TrackedTerms.turns(from: segs))
        XCTAssertEqual(reports, [])
        XCTAssertEqual(TrackedTerms.section(reports), "")
        XCTAssertEqual(TrackedTerms.tags(reports), [])
    }

    func testCapPerTermAndAndNMore() {
        let many = TranscriptSegments(segments: (0..<14).map { .init(start: Double($0 * 10), end: Double($0 * 10 + 5), text: "pricing again \($0)") })
        let reports = TrackedTerms.find(terms: ["pricing"], in: TrackedTerms.turns(from: many))
        XCTAssertEqual(reports[0].hits.count, 14)
        let lines = TrackedTerms.section(reports).components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(lines.count, TrackedTerms.maxLinesPerTerm + 1)
        XCTAssertTrue(lines.last!.contains("and 4 more mentions of **pricing**"))
    }

    func testUntimedFallbackFromCleanTranscriptHasNoTimestamp() {
        let clean = "[SPEAKER_00]\nLet us talk about GDPR now.\n\n[SPEAKER_01]\nSure, GDPR is next."
        let turns = TrackedTerms.turns(fromCleanTranscript: clean)
        XCTAssertEqual(turns.count, 2)
        let text = TrackedTerms.section(TrackedTerms.find(terms: ["gdpr"], in: turns))
        XCTAssertTrue(text.contains("- **gdpr** — \"Let us talk about GDPR now.\" (SPEAKER_00)"), text)
        XCTAssertFalse(text.contains("["), "no timestamp bracket")
    }

    func testUnicodeTermsAndTags() {
        let s = TranscriptSegments(segments: [.init(start: 1, end: 2, text: "Parlem de la col·laboració i de l'acord.")])
        let reports = TrackedTerms.find(terms: ["acord", "col·laboració", "acor"], in: TrackedTerms.turns(from: s))
        XCTAssertEqual(reports.map(\.term), ["acord", "col·laboració"])   // "acor" is inside a word
        XCTAssertEqual(TrackedTerms.tags(reports), ["acord", "col-laboració"])
    }

    func testContextIsTrimmedAtWordBoundariesAndQuotesNeutralised() {
        let long = String(repeating: "alpha ", count: 30) + "Slurm \"quoted\" " + String(repeating: "omega ", count: 30)
        let hit = TrackedTerms.find(terms: ["Slurm"], in: [.init(seconds: 0, speaker: nil, text: long)])[0].hits[0]
        XCTAssertTrue(hit.context.hasPrefix("…") && hit.context.hasSuffix("…"))
        XCTAssertFalse(hit.context.contains("\""))
        XCTAssertLessThan(hit.context.count, 160)
    }

    func testTimestampFormat() {
        XCTAssertEqual(TrackedTerms.timestamp(0), "00:00")
        XCTAssertEqual(TrackedTerms.timestamp(59.9), "00:59")
        XCTAssertEqual(TrackedTerms.timestamp(3600), "1:00:00")
    }
}
