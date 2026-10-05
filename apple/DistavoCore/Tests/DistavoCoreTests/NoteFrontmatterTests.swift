import XCTest
@testable import DistavoCore

/// Vikunja #2954: strict YAML quoting, split/strip round trip, idempotence, attendees.
final class NoteFrontmatterTests: XCTestCase {

    // MARK: scalar quoting

    func testPlainSafeValuesStayBare() {
        for s in ["Edward", "Marc (me)", "lang/ca", "meeting", "Q4 review", "naïve café", "snake_case", "a.b-c"] {
            XCTAssertEqual(NoteFrontmatter.scalar(s), s, s)
        }
    }

    func testHostileValuesAreDoubleQuotedAndEscaped() {
        let cases: [(String, String)] = [
            ("", "\"\""),
            ("a: b", "\"a: b\""),
            ("# not a comment", "\"# not a comment\""),
            ("-dash", "\"-dash\""),
            ("@mention", "\"@mention\""),
            ("*star", "\"*star\""),
            ("& anchor", "\"& anchor\""),
            ("!tag", "\"!tag\""),
            ("%x", "\"%x\""),
            ("12", "\"12\""),
            ("2026-10-05", "\"2026-10-05\""),
            ("true", "\"true\""), ("No", "\"No\""), ("null", "\"null\""), ("~", "\"~\""),
            ("say \"hi\"", "\"say \\\"hi\\\"\""),
            ("back\\slash", "\"back\\\\slash\""),
            ("line1\nline2", "\"line1\\nline2\""),
            ("tab\there", "\"tab\\there\""),
            ("trailing ", "\"trailing \""),
            ("[x]", "\"[x]\""), ("{x}", "\"{x}\""), ("a, b", "\"a, b\""), ("it's", "\"it's\""),
            ("ctrl\u{01}", "\"ctrl\\u0001\""),
            ("sep\u{2028}x", "\"sep\\u2028x\""),
        ]
        for (input, expected) in cases { XCTAssertEqual(NoteFrontmatter.scalar(input), expected, input) }
    }

    func testEmojiAndCJKStayLiteralInsideQuotes() {
        XCTAssertEqual(NoteFrontmatter.scalar("🚀 launch"), "\"🚀 launch\"")
        XCTAssertEqual(NoteFrontmatter.scalar("会议"), "会议")
        XCTAssertEqual(NoteFrontmatter.scalar("会议: 总结"), "\"会议: 总结\"")
    }

    func testListsAndEmptyList() {
        XCTAssertEqual(NoteFrontmatter.list([]), "[]")
        XCTAssertEqual(NoteFrontmatter.list(["a", "b: c", "- d"]), "[a, \"b: c\", \"- d\"]")
    }

    func testHostileNamesRoundTripThroughValue() {
        for title in ["Q4: scope & \"owners\"", "# heading", "- list", "@bob", "emoji 🚀", "multi\nline", "back\\slash", "ünï"] {
            let note = NoteFrontmatter.render(NoteFrontmatterFields(title: title)) + "# Meeting notes\n"
            XCTAssertEqual(NoteFrontmatter.value("title", in: note), title, title)
            XCTAssertEqual(NoteFrontmatter.strip(note), "# Meeting notes\n")
        }
    }

    // MARK: render / split / strip

    private let fields = NoteFrontmatterFields(
        date: "2026-10-05", title: "Roadmap", attendees: ["Edward", "Marc (me)"], tags: ["meeting", "lang/ca"],
        source: "Meeting 2026-10-05 10.00.00.wav", durationMinutes: 42)

    func testRenderShape() {
        XCTAssertEqual(NoteFrontmatter.render(fields), """
        ---
        date: 2026-10-05
        title: Roadmap
        attendees: [Edward, Marc (me)]
        tags: [meeting, lang/ca]
        source: Meeting 2026-10-05 10.00.00.wav
        duration_minutes: 42
        ---

        """)
    }

    func testEmptyListsAndOmittedKeys() {
        let block = NoteFrontmatter.render(NoteFrontmatterFields())
        XCTAssertEqual(block, "---\nattendees: []\ntags: []\n---\n")
    }

    func testSplitStripAndNoBlock() {
        let body = "# Meeting notes\n\n## A\ntext\n"
        let note = NoteFrontmatter.render(fields) + body
        let (block, rest) = NoteFrontmatter.split(note)
        XCTAssertEqual(block, NoteFrontmatter.render(fields))
        XCTAssertEqual(rest, body)
        XCTAssertEqual(NoteFrontmatter.strip(body), body)               // no block: unchanged
        XCTAssertEqual(NoteFrontmatter.value("source", in: note), "Meeting 2026-10-05 10.00.00.wav")
        XCTAssertNil(NoteFrontmatter.value("source", in: body))
    }

    func testABodyThatMerelyOpensWithARuleIsNotFrontmatter() {
        for text in ["---\nJust a line of prose\n---\nmore", "---\n\nno closing fence", "--- \n# H\n---\n", "---"] {
            XCTAssertNil(NoteFrontmatter.split(text).block, text)
            XCTAssertEqual(NoteFrontmatter.strip(text), text)
        }
    }

    func testCRLFAndBOMBlocks() {
        let note = "\u{FEFF}---\r\ntitle: X\r\n---\r\nbody"
        XCTAssertNotNil(NoteFrontmatter.split(note).block)
        XCTAssertEqual(NoteFrontmatter.strip(note), "body")
    }

    // MARK: idempotence and preserved keys

    func testApplyIsIdempotent() {
        let body = "# Meeting notes\n\ntext"
        let once = NoteFrontmatter.apply(fields, to: body)
        let twice = NoteFrontmatter.apply(fields, to: once)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(once.components(separatedBy: "\n---\n").count, 2, "exactly one closing fence")
        XCTAssertEqual(NoteFrontmatter.strip(twice), body)
    }

    func testUserKeysSurviveAndManagedKeysAreRewritten() {
        let old = "---\ndate: 2020-01-01\ntitle: Old\naliases:\n  - one\n  - two\nstatus: draft  # mine\ntags: [stale]\n---\nbody"
        var f = fields; f.title = "New"
        let result = NoteFrontmatter.apply(f, to: old)
        XCTAssertTrue(result.contains("aliases:\n  - one\n  - two\n"))
        XCTAssertTrue(result.contains("status: draft  # mine\n"))
        XCTAssertTrue(result.contains("title: New\n"))
        XCTAssertFalse(result.contains("Old")); XCTAssertFalse(result.contains("stale"))
        XCTAssertEqual(result.components(separatedBy: "title:").count, 2)
        XCTAssertTrue(result.hasSuffix("---\nbody"))
    }

    // MARK: attendees / dates

    func testAttendeesFromParticipantsText() {
        XCTAssertEqual(NoteFrontmatter.attendees(fromParticipants: "Edward (Cambridge University) — interviewer; Marc (me) — interviewee"),
                       ["Edward (Cambridge University)", "Marc (me)"])
        XCTAssertEqual(NoteFrontmatter.attendees(fromParticipants: "Anna, Ben (QA, London), Anna"), ["Anna", "Ben (QA, London)"])
        XCTAssertEqual(NoteFrontmatter.attendees(fromParticipants: "Ann\nBob - lead\n\n"), ["Ann", "Bob"])
        XCTAssertEqual(NoteFrontmatter.attendees(fromParticipants: nil), [])
        XCTAssertEqual(NoteFrontmatter.attendees(fromParticipants: "  "), [])
    }

    func testDateStringUsesTheGivenZone() {
        let d = Date(timeIntervalSince1970: 1_791_243_000)   // 2026-10-05 23:30 UTC
        XCTAssertEqual(NoteFrontmatter.dateString(d, timeZone: TimeZone(identifier: "UTC")!), "2026-10-05")
        XCTAssertEqual(NoteFrontmatter.dateString(d, timeZone: TimeZone(identifier: "Asia/Tokyo")!), "2026-10-06")
    }
}
