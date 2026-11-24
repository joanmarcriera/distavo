import XCTest
@testable import DistavoCore

/// `AskPeople`: a question that names a confirmed person prefers that person's meetings. Synthetic names only.
final class AskPeopleTests: XCTestCase {
    private func person(_ name: String, aliases: [String] = [], bases: [String]) -> PeoplePages.Person {
        var p = PeoplePages.Person(name: name)
        p.aliases = aliases
        p.meetings = bases.map { .init(base: $0, date: Date(timeIntervalSince1970: 0), title: $0, notePath: URL(fileURLWithPath: "/n/\($0).md"), spoke: true) }
        return p
    }
    private func passage(_ base: String) -> SearchPassage { SearchPassage(path: "/n/\(base).md", base: base, title: base, kind: .note, text: "t") }

    func testWhoAQuestionNames() {
        let people = [person("Petra Novak", aliases: ["Petra N"], bases: ["a"]), person("Oskar Lind", bases: ["b"]),
                      person("Anna Berg", bases: ["c"]), person("Anna Soler", bases: ["d"]), person("Jo Marsh", bases: ["e"])]
        func names(_ q: String) -> [String] { AskPeople.named(in: q, people: people).map(\.name) }
        XCTAssertEqual(names("What did I promise Petra?"), ["Petra Novak"])
        XCTAssertEqual(names("what did PETRA NOVAK's team and oskar say"), ["Petra Novak", "Oskar Lind"])
        XCTAssertEqual(names("the Petra N. thing"), ["Petra Novak"])
        XCTAssertEqual(names("What did Anna say?"), [], "two Annas: the first name names nobody")
        XCTAssertEqual(names("What did Anna Soler say?"), ["Anna Soler"])
        XCTAssertEqual(names("the petrarch quote, oskars, annaberg"), [], "whole words only")
        XCTAssertEqual(names("what did Jo say"), [], "a two-letter first name is too common a word")
        XCTAssertEqual(names(""), [])
    }

    // MARK: The longest name wins (found on real data, 2026-11-24)

    /// A page "Anna" and a page "Anna Puig": "Anna Puig" in a question is only Anna Puig.
    func testAFullNameDoesNotAlsoNameTheOneWordPageInsideIt() {
        let people = [person("Anna", bases: ["a"]), person("Anna Puig", bases: ["b"]), person("Oskar Lind", bases: ["c"])]
        func names(_ q: String) -> [String] { AskPeople.named(in: q, people: people).map(\.name) }
        XCTAssertEqual(names("What did Anna Puig say about the plan?"), ["Anna Puig"])
        XCTAssertEqual(names("anna puig's tasks"), ["Anna Puig"])
        XCTAssertEqual(names("WHAT DID ANNA PUIG SAY"), ["Anna Puig"])
        XCTAssertEqual(names("What did Anna say?"), ["Anna"], "the one-word page is still its own name")
        XCTAssertEqual(names("What did Anna Puig tell Anna?"), ["Anna", "Anna Puig"], "a second, separate Anna is the one-word page")
        XCTAssertEqual(names("Anna Puig and Oskar"), ["Anna Puig", "Oskar Lind"])
    }

    /// "Pere Soler" and "Pere Vila Costa" share a word; a merge left "Pere" as an alias of one of them.
    func testTwoPeopleSharingAWordAreNamedOnlyByTheFullNameAsked() {
        let people = [person("Pere Soler", bases: ["a"]), person("Pere Vila Costa", aliases: ["Pere", "Vila"], bases: ["b"]),
                      person("Anna Berg", bases: ["c"])]
        func names(_ q: String) -> [String] { AskPeople.named(in: q, people: people).map(\.name) }
        XCTAssertEqual(names("What did Pere Soler say about the plan?"), ["Pere Soler"])
        XCTAssertEqual(names("What did Pere Vila Costa say about the plan?"), ["Pere Vila Costa"])
        XCTAssertEqual(names("What did Pere say?"), ["Pere Vila Costa"], "the alias alone still names its person")
        XCTAssertEqual(names("What did Anna and Pere Soler agree?"), ["Pere Soler", "Anna Berg"], "a unique first name beside a full name")
        XCTAssertEqual(names("Pere Soler, Pere Vila Costa"), ["Pere Soler", "Pere Vila Costa"])
    }

    /// A one-word participant "Pere" beside "Pere Soler": same rule when the shorter name is a person, not an alias.
    func testAOneWordParticipantInsideAFullName() {
        let people = [person("Pere", bases: ["a"]), person("Pere Soler", bases: ["b"]), person("Will Marsh", bases: ["c"])]
        func names(_ q: String) -> [String] { AskPeople.named(in: q, people: people).map(\.name) }
        XCTAssertEqual(names("What did Pere Soler say?"), ["Pere Soler"])
        XCTAssertEqual(names("What did Pere say?"), ["Pere"])
        XCTAssertEqual(names("What did Will and Pere Soler promise?"), ["Pere Soler", "Will Marsh"], "the everyday-word rule still holds")
        XCTAssertEqual(names("will Pere Soler come?"), ["Pere Soler"])
    }

    func testBasesOfAFullNameLeaveOutTheOneWordPage() throws {
        let root = TestTemp.root.appendingPathComponent("distavo-askpeople-long-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        for (base, name) in [("Meeting_2026-11-10_09.00.00", "Anna"), ("Meeting_2026-11-11_09.00.00", "Anna Puig")] {
            try "# T\n".write(to: notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
            try SpeakerNames(names: ["S0": name]).encoded().write(to: SpeakerNames.url(workDir: work, base: base))
        }
        XCTAssertEqual(AskPeople.bases(for: "What did Anna Puig say about the plan?", notesDir: notes, workDir: work), ["Meeting_2026-11-11_09.00.00"])
        XCTAssertEqual(AskPeople.bases(for: "What did Anna say?", notesDir: notes, workDir: work), ["Meeting_2026-11-10_09.00.00"])
    }

    func testTheirMeetingsGoFirst() {
        let found = ["x", "a", "y", "a", "z"].map(passage)
        XCTAssertEqual(AskPeople.preferring(found, bases: ["a"], limit: 3).map(\.base), ["a", "a", "x"])
        XCTAssertEqual(AskPeople.preferring(found, bases: [], limit: 3).map(\.base), ["x", "a", "y"])
        XCTAssertEqual(AskPeople.preferring(found, bases: ["none"], limit: 9).map(\.base), ["x", "a", "y", "a", "z"])
    }

    func testBasesComeFromConfirmedNamesOnly() throws {
        let root = TestTemp.root.appendingPathComponent("distavo-askpeople-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        for (base, names, guess) in [("Meeting_2026-11-10_09.00.00", ["S0": "Petra Novak"], [String]()),
                                     ("Meeting_2026-11-11_09.00.00", ["S0": "Oskar Lind"], ["Oskar Lind"])] {
            try "# T\n".write(to: notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
            try SpeakerNames(names: names, byVoice: guess.isEmpty ? nil : guess).encoded().write(to: SpeakerNames.url(workDir: work, base: base))
        }
        XCTAssertEqual(AskPeople.bases(for: "what did I promise Petra?", notesDir: notes, workDir: work), ["Meeting_2026-11-10_09.00.00"])
        XCTAssertEqual(AskPeople.bases(for: "what did Oskar say?", notesDir: notes, workDir: work), [], "a voice guess is not a confirmed person")
        XCTAssertEqual(AskPeople.bases(for: "what was decided?", notesDir: notes, workDir: work), [])
    }
}
