import XCTest
@testable import DistavoCore

final class SelfIntroductionsTests: XCTestCase {
    private func name(_ t: String) -> String? { SelfIntroductions.find(in: t)?.name }

    func testFindsNamesAfterTheUsualOpenings() {
        XCTAssertEqual(name("Hi everyone, I'm Anna."), "Anna")
        XCTAssertEqual(name("Hello, my name is Anna Smith and I look after networks."), "Anna Smith")
        XCTAssertEqual(name("Yeah, this is Pere."), "Pere")
        XCTAssertEqual(name("Hola, me llamo Jordi."), "Jordi")
        XCTAssertEqual(name("Bon dia, sóc la Marta"), nil)   // article before the name: not guessed
        XCTAssertEqual(name("Bon dia, em dic Marta Puig."), "Marta Puig")
        XCTAssertEqual(name("Soy Luis, de Acme."), "Luis")
    }

    func testReviewFalsePositives() {
        for t in ["This is Python at its best", "This is Monday morning", "I am Spanish", "I'm Anna's colleague",
                  "This is Bob, our CTO."] {
            XCTAssertNil(name(t), t)
        }
        XCTAssertEqual(name("This is Anna from Acme."), "Anna")
        XCTAssertEqual(name("Hi, this is Pere."), "Pere")
        for t in ["I am in charge of the engineer hiring.", "this is a good partner for us.", "This is Bob, our CTO."] {
            XCTAssertNil(SelfIntroductions.role(in: t), t)
        }
        XCTAssertEqual(SelfIntroductions.role(in: "Em dic Pere, sóc el cap de projecte a Acme"), "cap de projecte")
        typealias S = TranscriptSegments.Segment
        XCTAssertNil(SelfIntroductions.said(by: "A", in: [S(start: 1, end: 2, text: "I'm from Barcelona", speaker: "A")]))
        // Long whitespace runs stay cheap.
        let start = Date()
        _ = SelfIntroductions.role(in: "I'm Anna" + String(repeating: " ", count: 20_000) + "x")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testOrganisationAfterTheName() {
        XCTAssertEqual(SelfIntroductions.find(in: "I'm Anna from Acme Networks, nice to meet you"),
                       .init(name: "Anna", organisation: "Acme Networks"))
        XCTAssertEqual(SelfIntroductions.find(in: "Soy Luis, de Acme.")?.organisation, "Acme")
        XCTAssertNil(SelfIntroductions.find(in: "I'm Anna and I am here")?.organisation)
    }

    func testOrdinarySentencesAreNotIntroductions() {
        for t in ["I'm going to do the rush", "I'm Sorry about that", "I am Not sure", "this is Great",
                  "so I'm gonna share my screen", "I'm in London", "This is the plan", "I'm SPEAKER_01",
                  "Trimming is fine", "I am Happy to help"] {
            XCTAssertNil(name(t), t)
        }
    }

    func testOnlyOwnTurnsInTheFirstMinutes() {
        typealias S = TranscriptSegments.Segment
        let segs = [S(start: 5, end: 9, text: "Hi, I'm Anna from Acme.", speaker: "SPEAKER_00"),
                    S(start: 10, end: 12, text: "Thanks Anna. I'm Pere.", speaker: "SPEAKER_01"),
                    S(start: 20, end: 22, text: "Actually my name is Joan.", speaker: "SPEAKER_00"),
                    S(start: 400, end: 405, text: "I'm Marta.", speaker: "SPEAKER_02")]
        let got = SelfIntroductions.bySpeaker(segs)
        XCTAssertEqual(got["SPEAKER_00"], .init(name: "Anna", organisation: "Acme"))   // the first one stands
        XCTAssertEqual(got["SPEAKER_01"]?.name, "Pere")
        XCTAssertNil(got["SPEAKER_02"])   // after the window
    }

    func testVoiceTakesTheNameSaidInMostMeetings() {
        func occ(_ base: String, _ n: String?, org: String? = nil) -> VoiceReview.Occurrence {
            .init(base: base, label: "SPEAKER_00", title: base, date: Date(timeIntervalSince1970: 0), sampleStart: 0,
                  sampleEnd: 5, quote: "", embedding: [1, 0], introduction: n.map { .init(name: $0, organisation: org) })
        }
        let v = VoiceReview.Voice(id: 1, occurrences: [occ("a", "Pere"), occ("b", "Anna"), occ("c", nil), occ("d", "anna", org: "Acme")],
                                  suggestedName: nil)
        XCTAssertEqual(v.introduction, .init(name: "Anna", organisation: "Acme"))
        XCTAssertNil(VoiceReview.Voice(id: 2, occurrences: [occ("a", nil)], suggestedName: nil).introduction)
    }
}

/// What a named speaker says about their job, and how the people page shows it. Synthetic names only.
final class StatedRoleTests: XCTestCase {
    typealias S = TranscriptSegments.Segment

    func testRolesNeedARoleWord() {
        XCTAssertEqual(SelfIntroductions.role(in: "Hi, I'm the head of platform at Acme."), "head of platform")
        XCTAssertEqual(SelfIntroductions.role(in: "I'm Anna, a network engineer here."), "network engineer")
        XCTAssertEqual(SelfIntroductions.role(in: "My name is Anna Smith and I'm the CTO."), "CTO")
        XCTAssertEqual(SelfIntroductions.role(in: "I work as a consultant for several banks"), "consultant")
        XCTAssertEqual(SelfIntroductions.role(in: "Soy la directora de operaciones."), "directora de operaciones")
        XCTAssertEqual(SelfIntroductions.role(in: "Sóc el cap de vendes."), "cap de vendes")
        for t in ["I'm a bit late, sorry", "I'm the one who called", "I am in the car", "I'm going to lead with the numbers",
                  "I'm happy with that", "this is the plan"] {
            XCTAssertNil(SelfIntroductions.role(in: t), t)
        }
    }

    func testSaidTakesOwnEarlyTurnsOnly() {
        let segs = [S(start: 3, end: 6, text: "I'm Anna from Acme Networks.", speaker: "Anna"),
                    S(start: 8, end: 12, text: "I'm the head of platform there.", speaker: "Anna"),
                    S(start: 15, end: 18, text: "I work at Globex. I'm a solutions architect.", speaker: "Pere"),
                    S(start: 900, end: 905, text: "I'm the CEO.", speaker: "Joan"),
                    S(start: 20, end: 22, text: "Fine by me.", speaker: "Marta")]
        XCTAssertEqual(SelfIntroductions.said(by: "Anna", in: segs), .init(role: "head of platform", organisation: "Acme Networks"))
        XCTAssertEqual(SelfIntroductions.said(by: "Anna", in: segs)?.line, "head of platform, Acme Networks")
        XCTAssertEqual(SelfIntroductions.said(by: "Pere", in: segs), .init(role: "solutions architect", organisation: "Globex"))
        XCTAssertNil(SelfIntroductions.said(by: "Joan", in: segs))    // after the first minutes
        XCTAssertNil(SelfIntroductions.said(by: "Marta", in: segs))
    }
}

final class PeoplePagesStatedRoleTests: XCTestCase {
    typealias S = TranscriptSegments.Segment
    private let zone = TimeZone(identifier: "Europe/London")!

    func testPageShowsWhatTheySaidAndFillsEmptyFieldsOnly() throws {
        let root = TestTemp.root.appendingPathComponent("distavo-said-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        for (base, text) in [("Meeting_2026-11-18_09.00.00", "I'm Oskar from Acme Cooling, I'm a sales engineer."),
                             ("Meeting_2026-11-19_14.30.00", "Morning all. I'm the head of sales at Acme Cooling now.")] {
            try "# Call\n\nText.\n".write(to: notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
            try SpeakerNames(names: ["SPEAKER_01": "Oskar Lind"]).encoded().write(to: SpeakerNames.url(workDir: work, base: base))
            try TranscriptSegments(segments: [S(start: 4, end: 9, text: text, speaker: "Oskar Lind"),
                                              S(start: 10, end: 12, text: "I'm the CEO.", speaker: "SPEAKER_00")])
                .save(workDir: work, base: base)
        }
        _ = try PeoplePages.update(notesDir: notes, workDir: work, timeZone: zone)
        let file = PeoplePages.folder(notesDir: notes).appendingPathComponent("Oskar Lind.md")
        var page = try String(contentsOf: file, encoding: .utf8)
        // The most recent statement fills the empty fields; each meeting line keeps what was said that day.
        XCTAssertTrue(page.contains("role: head of sales"), page)
        XCTAssertTrue(page.contains("organisation: Acme Cooling"), page)
        XCTAssertTrue(page.contains("· spoke · said: head of sales, Acme Cooling\n"), page)
        XCTAssertTrue(page.contains("· spoke · said: sales engineer, Acme Cooling\n"), page)
        // A role the owner wrote is never replaced.
        page = page.replacingOccurrences(of: "role: head of sales", with: "role: my contact for chillers")
        try page.write(to: file, atomically: true, encoding: .utf8)
        _ = try PeoplePages.update(notesDir: notes, workDir: work, timeZone: zone)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("role: my contact for chillers"))
    }
}
