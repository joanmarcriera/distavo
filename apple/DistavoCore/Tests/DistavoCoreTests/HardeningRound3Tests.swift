import XCTest
@testable import DistavoCore

/// The smaller findings left over from the bug hunts of 2026-11-23. Synthetic names only.
final class HardeningRound3Tests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/London")!

    func testWhatPeopleTypeForNobodyIsNotAPerson() {
        for typed in ["None", "TBD", "Nobody", "No one", "N/A", "Tbc", "None.", "Just me", "Same as above", "Unknown", "-"] {
            XCTAssertFalse(PeoplePages.isPersonName(typed), typed)
            XCTAssertEqual(PeoplePages.parseParticipants("Other participants: \(typed)").count, 0, typed)
        }
        XCTAssertTrue(PeoplePages.isPersonName("Nona Berg"))
        XCTAssertTrue(PeoplePages.isPersonName("Noel"))
    }

    func testALongNameIsStillOnePerson() {
        XCTAssertTrue(PeoplePages.isPersonName("Maria del Mar Bonet Verdaguer"))
        XCTAssertTrue(PeoplePages.isPersonName("Josep Maria de Sagarra i Castellarnau"))
        XCTAssertFalse(PeoplePages.isPersonName("Anna who joined us late from the other office"))
        XCTAssertEqual(PeoplePages.parseParticipants("Maria del Mar Bonet Verdaguer (Acme)").map(\.name), ["Maria del Mar Bonet Verdaguer"])
    }

    func testTwoPeopleJoinedByAndAreTwoPages() {
        func names(_ t: String) -> [String] { PeoplePages.parseParticipants(t).map(\.name) }
        XCTAssertEqual(names("Anna and Pere"), ["Anna", "Pere"])
        XCTAssertEqual(names("Anna Berg & Pere Soler, Bo Lind"), ["Anna Berg", "Pere Soler", "Bo Lind"])
        XCTAssertEqual(names("Anna i Pere"), ["Anna", "Pere"])
        // A compound surname is one person; a role or a company with "and" in it does not make a second one.
        XCTAssertEqual(names("Josep Puig i Cadafalch"), ["Josep Puig i Cadafalch"])
        XCTAssertEqual(names("Anna Berg - Sales and Marketing"), ["Anna Berg"])
        XCTAssertEqual(names("Anna Berg (Marks & Spencer)"), ["Anna Berg"])
        XCTAssertEqual(names("Anna Berg: research and Development"), ["Anna Berg"])
        let two = PeoplePages.parseParticipants("Anna (Acme) and Pere from Globex")
        XCTAssertEqual(two.map(\.name), ["Anna", "Pere"])
        XCTAssertEqual(two.map(\.organisation), ["Acme", "Globex"])
        // What cannot be split is never one page for two people.
        XCTAssertFalse(PeoplePages.isPersonName("Anna and the team"))
        XCTAssertEqual(names("Anna and the team"), [])
    }

    func testTheCountOfPeopleIsUnchangedByTheSharedSplitting() {
        XCTAssertEqual(SpeakerHints.suggestedCount("Other participants: Anna and Pere"), 3)
        XCTAssertEqual(SpeakerHints.suggestedCount("Other participants: Anna (Research and Development)"), 2)
        XCTAssertEqual(SpeakerHints.suggestedCount("Other participants: Josep Puig i Cadafalch"), 2)
        XCTAssertEqual(SpeakerHints.suggestedCount("Other participants: research and development"), nil)
        XCTAssertEqual(SpeakerHints.joinedPeople("Anna Puig i Pere Soler"), ["Anna Puig", "Pere Soler"])
        XCTAssertEqual(SpeakerHints.joinedPeople("Research and development"), ["Research and development"])
    }

    func testTheOwnerWithAFullStopIsStillTheOwner() throws {
        let root = TestTemp.root.appendingPathComponent("distavo-hard3-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let base = "Meeting_2026-11-18_09.00.00"
        try "# Call\n".write(to: notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
        try SpeakerNames(names: ["SPEAKER_00": "Dana Owner", "SPEAKER_01": "Oskar Lind"]).encoded().write(to: SpeakerNames.url(workDir: work, base: base))
        let people = PeoplePages.collect(notesDir: notes, workDir: work, ownerName: " Dana Owner. ", timeZone: zone)
        XCTAssertEqual(people.map(\.name), ["Oskar Lind"])
        XCTAssertTrue(VoiceRecognition.isOwner("Dana Owner", noteOwner: "Dana Owner."))
        XCTAssertTrue(VoiceRecognition.isOwner("Dana Owner (me)", noteOwner: "dana owner"))
        XCTAssertFalse(VoiceRecognition.isOwner("Dana", noteOwner: "Dana Owner."))
        XCTAssertFalse(VoiceRecognition.isOwner("Anyone", noteOwner: "."))
    }

    func testATypedNoteLosesItsControlCharacters() {
        let notes = ScratchpadNotes(lines: [.init(offsetSeconds: 5, text: "ask\u{07} about\u{1B}[31m the\u{00} price\ttoday", flagged: false),
                                            .init(offsetSeconds: 9, text: "\u{07}\u{00}", flagged: true)]).sanitised()
        XCTAssertEqual(notes.lines.map(\.text), ["ask about[31m the price today"])
        // Letters that need a joiner are untouched (a family emoji, Persian).
        let joined = ScratchpadNotes(lines: [.init(offsetSeconds: 1, text: "👨‍👩‍👧 می‌خواهم", flagged: false)]).sanitised()
        XCTAssertEqual(joined.lines.first?.text, "👨‍👩‍👧 می‌خواهم")
    }

    func testAClockThatIsNotANumberIsNoSample() {
        var m = SilenceMonitor(policy: SilencePolicy(suggestAfter: 10, autoStopAfter: 20), now: 0)
        XCTAssertEqual(m.ingest(mic: 0.5, system: 0, at: 1), .none)   // sound heard
        XCTAssertEqual(m.ingest(mic: 0, system: 0, at: .nan), .none)
        XCTAssertEqual(m.ingest(mic: 0, system: 0, at: .infinity), .none)
        // The next real samples count from the last real one, as if the bad readings never came.
        XCTAssertEqual(m.ingest(mic: 0, system: 0, at: 6), .none)
        XCTAssertEqual(m.ingest(mic: 0, system: 0, at: 11), .suggestStop(silentFor: 10))
    }

    func testATitleThatIsCompleteNamesTheEmployerAfterOf() {
        func said(_ t: String) -> [String?] { let s = SelfIntroductions.stated(in: t); return [s?.role, s?.organisation] }
        XCTAssertEqual(said("I'm the CTO of Acme."), ["CTO", "Acme"])
        XCTAssertEqual(said("I am the founder of Blue Harbour Labs."), ["founder", "Blue Harbour Labs"])
        XCTAssertEqual(said("I'm the head of platform at Acme."), ["head of platform", "Acme"])
        XCTAssertEqual(said("I'm the director of engineering."), ["director of engineering", nil])
        XCTAssertEqual(said("I'm the owner of the budget."), [nil, nil], "a task, not a job")
    }

    func testAskTreatsAnEverydayWordAsANameOnlyWithItsCapitalMidSentence() {
        let people = [PeoplePages.Person(name: "Will Marsh"), PeoplePages.Person(name: "May"), PeoplePages.Person(name: "Jo"),
                      PeoplePages.Person(name: "Petra Novak", aliases: ["Rose"])]
        func named(_ q: String) -> [String] { AskPeople.named(in: q, people: people).map(\.name) }
        XCTAssertEqual(named("Will this work in May?"), [], "a month after \"in\" is the month")
        XCTAssertEqual(named("what did we agree in the May board meeting?"), [])
        XCTAssertEqual(named("what did you tell May yesterday?"), ["May"])
        XCTAssertEqual(named("Will's plan, what was it?"), ["Will Marsh"])
        XCTAssertEqual(named("who said \"Will\" would do it, and (Jo) too?"), ["Will Marsh", "Jo"])
        XCTAssertEqual(named("what did  Will promise - and Jo?"), ["Will Marsh", "Jo"])
        XCTAssertEqual(named("WHAT DID WILL SAY"), ["Will Marsh"])
        XCTAssertEqual(named("will we ship, and may I ask why?"), [])
        XCTAssertEqual(named("what did Will promise?"), ["Will Marsh"])
        XCTAssertEqual(named("jo crec que sí"), [])
        XCTAssertEqual(named("què va dir Jo, exactament?"), ["Jo"])
        XCTAssertEqual(named("Will Marsh said what?"), ["Will Marsh"], "the full name is never in doubt")
        XCTAssertEqual(named("the price rose again"), [])
        XCTAssertEqual(named("what did Rose and petra say"), ["Petra Novak"])
        XCTAssertEqual(named("what did petra promise"), ["Petra Novak"], "other names match whatever the capitals")
    }

    func testAPageWithoutNotesSortsByItsOwnLastSeenDay() {
        let d = { (day: Int) in Date(timeIntervalSince1970: 1_795_000_000 + Double(day) * 86_400) }
        func person(_ name: String, _ day: Int?) -> PeoplePages.Person {
            var p = PeoplePages.Person(name: name)
            if let day { p.meetings = [.init(base: "b\(day)", date: d(day), title: "T", notePath: URL(fileURLWithPath: "/n/b\(day).md"), spoke: true)] }
            return p
        }
        let gone = NoteFrontmatter.dateString(d(5), timeZone: zone)
        let index = PeoplePages.index([(person("Old Anna", 1), "Old Anna.md", [:]), (person("Gone Bo", nil), "Gone Bo.md", ["_last_seen": gone]),
                                       (person("New Cy", 9), "New Cy.md", [:]), (person("Never Di", nil), "Never Di.md", [:])], timeZone: zone)
        let order = ["New Cy", "Gone Bo", "Old Anna", "Never Di"].map { index.range(of: "[\($0)]")!.lowerBound }
        XCTAssertEqual(order, order.sorted(), index)
    }

    // MARK: Review of 2026-11-23

    func testACompanyWithAndInItIsNotASecondPerson() {
        func people(_ s: String) -> [String] { PeoplePages.parseParticipants(s).map { "\($0.name)|\($0.organisation ?? "-")" } }
        XCTAssertEqual(people("Anna from Marks and Spencer"), ["Anna|Marks and Spencer"])
        XCTAssertEqual(people("Pere at Procter & Gamble, Tom for Johnson & Johnson"), ["Pere|Procter & Gamble", "Tom|Johnson & Johnson"])
        XCTAssertEqual(people("Anna and Pere from Smith & Sons Ltd"), ["Anna|-", "Pere|Smith & Sons Ltd"])
        XCTAssertEqual(people("Anna (buyer at Acme) and Pere"), ["Anna|Acme", "Pere|-"])
    }

    func testNilIsAName() {
        XCTAssertTrue(PeoplePages.isPersonName("Nil"))
        XCTAssertTrue(PeoplePages.isPersonName("Na Yeon"))
        XCTAssertEqual(PeoplePages.parseParticipants("Nil (Acme), Cap Ferrer").map(\.name), ["Nil", "Cap Ferrer"])
    }

    func testAnOwnerNameThatEndsInAFullStopMatchesItself() throws {
        let root = TestTemp.root.appendingPathComponent("distavo-hard3b-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let base = "Meeting_2026-11-18_09.00.00"
        try "# Call\n".write(to: notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
        try SpeakerNames(names: ["SPEAKER_00": "Dana O.", "SPEAKER_01": "Oskar Lind"]).encoded().write(to: SpeakerNames.url(workDir: work, base: base))
        XCTAssertEqual(PeoplePages.collect(notesDir: notes, workDir: work, ownerName: "Dana O.", timeZone: zone).map(\.name), ["Oskar Lind"])
        XCTAssertEqual(PeoplePages.collect(notesDir: notes, workDir: work, ownerName: "", timeZone: zone).map(\.name), ["Dana O.", "Oskar Lind"])
    }

    // MARK: Second review of 2026-11-23

    func testAMiddleInitialIsNotAJoiner() {
        func names(_ t: String) -> [String] { PeoplePages.parseParticipants("Other participants: " + t).map(\.name) }
        XCTAssertEqual(names("Anna E Smith"), ["Anna E Smith"])
        XCTAssertEqual(names("Joan I Puig, Maria Y Soler"), ["Joan I Puig", "Maria Y Soler"])
        XCTAssertEqual(SpeakerHints.suggestedCount("Other participants: Anna E Smith"), 2)
        XCTAssertEqual(names("Anna i Pere"), ["Anna", "Pere"])
        XCTAssertEqual(names("Anna AND Pere"), ["Anna", "Pere"])
    }

    func testTwoPeopleBeforeARoleOrWithACompanyEach() {
        func people(_ s: String) -> [String] {
            PeoplePages.parseParticipants("Other participants: " + s).map { "\($0.name)|\($0.organisation ?? "-")|\($0.role ?? "-")" }
        }
        XCTAssertEqual(people("Anna and Pere - sales"), ["Anna|-|-", "Pere|-|sales"])
        XCTAssertEqual(people("Anna and Pere from Acme - sales"), ["Anna|-|-", "Pere|Acme|sales"])
        XCTAssertEqual(people("Anna from Acme and Pere from Beta"), ["Anna|Acme|-", "Pere|Beta|-"])
        XCTAssertEqual(people("Anna at Acme & Pere at Beta, Bo for Globex i Cy for Initech"),
                       ["Anna|Acme|-", "Pere|Beta|-", "Bo|Globex|-", "Cy|Initech|-"])
        // Still one person each.
        XCTAssertEqual(people("Anna from Marks and Spencer"), ["Anna|Marks and Spencer|-"])
        XCTAssertEqual(people("Anna from Acme and Sons"), ["Anna|Acme and Sons|-"])
        XCTAssertEqual(people("Anna Berg - Sales and Marketing"), ["Anna Berg|-|Sales and Marketing"])
        XCTAssertEqual(people("Anna Berg: liaison for Acme and Beta"), ["Anna Berg|-|liaison for Acme and Beta"])
        XCTAssertEqual(people("Anna (works for Acme and Beta)"), ["Anna|Acme and Beta|works"])
    }

    func testACompoundSurnameBeforeACompanyOrARoleIsOnePersonInTheCount() {
        XCTAssertEqual(SpeakerHints.suggestedCount("Other participants: Santiago Ramón y Cajal from Acme"), 2)
        XCTAssertEqual(SpeakerHints.suggestedCount("Other participants: Josep Puig i Cadafalch - architect"), 2)
        XCTAssertEqual(SpeakerHints.suggestedCount("Other participants: Josep Puig i Cadafalch: architect"), 2)
        XCTAssertEqual(SpeakerHints.suggestedCount("Other participants: Josep Puig i Cadafalch (Acme)"), 2)
        XCTAssertEqual(SpeakerHints.suggestedCount("Other participants: Anna Puig i Pere Soler from Acme"), 3)
    }

    /// Two names the disk folds into one file name (ß and ss) are two people with a page each.
    func testTwoNamesThatAreOneFileToTheDiskGetAPageEach() throws {
        let root = TestTemp.root.appendingPathComponent("distavo-hard3c-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        for (base, name) in [("Meeting_2026-11-18_09.00.00", "Anna Strauß"), ("Meeting_2026-11-19_09.00.00", "Anna Strauss")] {
            try "# Call\n".write(to: notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
            try SpeakerNames(names: ["SPEAKER_00": name]).encoded().write(to: SpeakerNames.url(workDir: work, base: base))
        }
        let first = try PeoplePages.update(notesDir: notes, workDir: work, timeZone: zone)
        XCTAssertEqual(Set(first.created), ["Anna Strauß", "Anna Strauss"])
        let pages = PeoplePages.known(notesDir: notes)
        XCTAssertEqual(Set(pages.map(\.name)), ["Anna Strauß", "Anna Strauss"])
        let again = try PeoplePages.update(notesDir: notes, workDir: work, timeZone: zone)
        XCTAssertEqual(again.created + again.updated, [], "stable at the second run")
        for file in try FileManager.default.contentsOfDirectory(atPath: PeoplePages.folder(notesDir: notes).path) where !file.hasPrefix("_") {
            let text = try String(contentsOf: PeoplePages.folder(notesDir: notes).appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("1 meeting"), text)
        }
    }

    func testMoreEverydayWordsAreNotPeople() {
        let people = [PeoplePages.Person(name: "Guy Ritter"), PeoplePages.Person(name: "Ben Taylor"), PeoplePages.Person(name: "Àngel Roca")]
        func named(_ q: String) -> [String] { AskPeople.named(in: q, people: people).map(\.name) }
        XCTAssertEqual(named("what did the guy from Acme say?"), [])
        XCTAssertEqual(named("què va quedar ben clar?"), [])
        XCTAssertEqual(named("l'àngel de la guarda"), [])
        XCTAssertEqual(named("what did Guy and Ben agree with Àngel?"), ["Guy Ritter", "Ben Taylor", "Àngel Roca"])
    }

    func testEveryLineBreakInATypedNoteIsASpace() {
        let notes = ScratchpadNotes(lines: [.init(offsetSeconds: 1, text: "Budget\u{0B}Timeline\u{0C}Risks\u{85}Owner\u{2028}End", flagged: false)]).sanitised()
        XCTAssertEqual(notes.lines.first?.text, "Budget Timeline Risks Owner End")
    }

    func testThePeopleFieldLosesItsControlCharactersToo() {
        var notes = ScratchpadNotes(lines: [])
        notes.people = "Anna\u{1B}[31m, Pere\u{07}\u{0B}Bo\u{00}"
        XCTAssertEqual(notes.cleanPeople, "Anna[31m, Pere, Bo")
        XCTAssertEqual(PeoplePages.parseParticipants(notes.cleanPeople ?? "").map(\.name), ["Pere", "Bo"])
    }

    func testMoreTitlesAndLanguagesInAStatedRole() {
        func said(_ t: String) -> [String?] { let s = SelfIntroductions.stated(in: t); return [s?.role, s?.organisation] }
        XCTAssertEqual(said("I'm the CMO of Acme."), ["CMO", "Acme"])
        XCTAssertEqual(said("I'm the chair of governance."), ["chair of governance", nil])
        XCTAssertEqual(said("I'm CTO of Acme."), ["CTO", "Acme"])
        XCTAssertEqual(said("I'm Head of Platform at Acme."), ["Head of Platform", "Acme"])
        XCTAssertEqual(said("Soy el CEO de Acme."), ["CEO", "Acme"])
        XCTAssertEqual(said("Sóc la directora d'operacions."), ["directora d'operacions", nil])
        XCTAssertEqual(said("Soy la directora de operaciones."), ["directora de operaciones", nil])
        // Unchanged.
        XCTAssertEqual(said("I'm Anna, the head of sales of Acme."), ["head of sales of Acme", nil])
        XCTAssertEqual(said("I'm an engineer that's new here."), [nil, nil])
        XCTAssertEqual(said("I'm Anna."), [nil, nil])
    }

    // MARK: Third review of 2026-11-23

    func testASecondImIsNotPartOfTheRole() {
        func said(_ t: String) -> [String?] { let s = SelfIntroductions.stated(in: t); return [s?.role, s?.organisation] }
        XCTAssertEqual(said("I'm Anna, I'm the CTO at Acme."), ["CTO", "Acme"])
        XCTAssertEqual(said("Hi everyone, I'm Anna, I'm the head of platform at Acme."), ["head of platform", "Acme"])
        XCTAssertEqual(said("Soy Pere, soy el CTO de Acme."), ["CTO", "Acme"])
        XCTAssertEqual(said("I'm Anna and I'm the CTO at Acme."), ["CTO", "Acme"])
    }

    func testWhatFollowsOfIsAJobOnlyWhenItIsOne() {
        func said(_ t: String) -> [String?] { let s = SelfIntroductions.stated(in: t); return [s?.role, s?.organisation] }
        XCTAssertEqual(said("I'm CEO of a small company called Acme."), ["CEO", nil])
        XCTAssertEqual(said("I'm the CEO of a startup called Acme."), ["CEO", nil])
        XCTAssertEqual(said("I'm the head of a small team."), [nil, nil])
        XCTAssertEqual(said("I'm an owner of a dog."), [nil, nil])
        XCTAssertEqual(said("I'm Anna and I'm the owner of this meeting."), [nil, nil])
        XCTAssertEqual(said("I'm the owner of the action items."), [nil, nil])
        XCTAssertEqual(said("I'm CTO of acme."), ["CTO", nil])
        XCTAssertEqual(said("I'm the owner of Acme."), ["owner", "Acme"])
        XCTAssertEqual(said("Sóc el CEO d'Acme."), ["CEO", "Acme"])
        XCTAssertEqual(said("Sóc fundadora d'Acme."), ["fundadora", "Acme"])
        XCTAssertEqual(said("I'm Senior Principal Software Engineer at Acme."), ["Senior Principal Software Engineer", "Acme"])
        XCTAssertEqual(said("I'm Chief Technology Officer at Acme."), ["Chief Technology Officer", "Acme"])
    }

    func testAskReadsCatalanArticlesMonthsAndSentenceBreaks() {
        let people = ["Alba", "Àngel Roca", "Julio", "May", "Will Marsh", "Mia Lopez", "Jan Novak"].map { PeoplePages.Person(name: $0) }
        func named(_ q: String) -> [String] { AskPeople.named(in: q, people: people).map(\.name) }
        XCTAssertEqual(named("Què va dir l'Alba?"), ["Alba"])
        XCTAssertEqual(named("Les tasques de l’Àngel i d'Alba"), ["Alba", "Àngel Roca"])
        XCTAssertEqual(named("a l'alba sortim"), [])
        // Spanish and Catalan months are lower case: a capital is the person.
        XCTAssertEqual(named("Què va dir en Julio?"), ["Julio"])
        XCTAssertEqual(named("Las tareas de Julio"), ["Julio"])
        XCTAssertEqual(named("lo vemos en julio"), [])
        // English: each mention on its own.
        XCTAssertEqual(named("What did May say in May?"), ["May"])
        XCTAssertEqual(named("What did I hear from May?"), ["May"])
        XCTAssertEqual(named("What happens in May?"), [])
        // After anything that may end a sentence the capital says nothing.
        for q in ["He said \"no.\" Will this ship?", "Hmm… Will this ship?", "(context) Will this ship?", "Summary of budget\nWill it pass?",
                  "🙂 Will this work?", "- Will it ship?", "Q: Will it ship?"] {
            XCTAssertEqual(named(q), [], q)
        }
        XCTAssertEqual(named("És mia la tasca?"), [])
        XCTAssertEqual(named("what did we decide in jan"), [])
        XCTAssertEqual(named("what did Mia and Jan decide"), ["Mia Lopez", "Jan Novak"])
    }

    func testInvisibleMarksDoNotMakeASecondPersonOrAReversedFileName() {
        var notes = ScratchpadNotes(lines: [])
        notes.people = "Pere\u{200B}, \u{FEFF}Joan, Anna\u{202E}dm, So\u{00AD}nia"
        XCTAssertEqual(notes.cleanPeople, "Pere, Joan, Annadm, Sonia")
        XCTAssertEqual(ScratchpadNotes.printable("👨‍👩‍👧 می‌خواهم 🏴󠁧󠁢󠁥󠁮󠁧󠁿"), "👨‍👩‍👧 می‌خواهم 🏴󠁧󠁢󠁥󠁮󠁧󠁿", "joiners and flag tags stay")
    }
    // MARK: real-data round: remarks typed in the participants answer are not people

    func testARemarkOrASentenceIsNotAPersonName() {
        for remark in ["He is", "Who he is", "Is new Here", "Anna. Not sure in general.", "Head of procurement in some company",
                       "De moment ningú més", "Some guy from the supplier-side ?", "Pere es comercial nou", "Jo ACME for the audit team",
                       "Petra who runs sales", "PN => Petra Novak", "Petra <petra@example.com>", "Acme LTD. Petra something", "Not sure!", "She", "Anna from",
                       "Anna's boss", "Probably Anna", "Ask Anna", "Anna too", "Anna again", "Sales Director", "Anna - Acme", "Possibly Pere"] {
            XCTAssertFalse(PeoplePages.isPersonName(remark), remark)
        }
        XCTAssertFalse(PeoplePages.isPersonName("Petra Novak- buyer of pumps"))
        XCTAssertEqual(PeoplePages.parseParticipants("Petra Novak- procurement manager, Oskar Lind").map(\.name), ["Petra Novak", "Oskar Lind"])
        XCTAssertEqual(PeoplePages.parseParticipants("Petra Novak- procurement manager").first?.role, "procurement manager")
        XCTAssertEqual(PeoplePages.parseParticipants("Jean-Luc Picard - captain").first?.name, "Jean-Luc Picard")
        for name in ["Maria del Mar Bonet", "Jan van der Berg", "J. Smith", "Anna puig", "Dr. Anna Puig", "Xi", "Sean O'Brien", "Jean-Luc Picard",
                     "Josep Puig i Cadafalch", "Leonardo da Vinci", "Smith Jr.", "WWT", "Anna", "Petra Novak", "Mohammed bin Salman", "Inés de la Fuente",
                     "J.R.R. Tolkien", "A.J. Brown", "Prof. Anna Puig", "Srta. Puig", "Anna Puig.", "Per Andersson", "He Jiankui", "Son Heung-min",
                     "To Lam", "Con O'Brien", "Sophie in 't Veld", "Rik op den Brouw", "Karl zu Guttenberg", "Hans vom Rath", "Andrea della Valle",
                     "Gianni degli Esposti", "Jean des Rosiers", "Maria de l'Estany Puig", "Josep d'Alòs Moner", "Omar al-Khatib Hassan",
                     "Anna de la cruz", "Anna maria puig"] {
            XCTAssertTrue(PeoplePages.isPersonName(name), name)
        }
    }
}
