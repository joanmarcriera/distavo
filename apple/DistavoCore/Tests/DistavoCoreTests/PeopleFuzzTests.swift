import XCTest
@testable import DistavoCore

/// Property tests with seeded random input (a new kind of test, 2026-11-23): the text parsers of the people
/// and recorder features must never crash, never hang and must keep their invariants whatever is typed or
/// pasted. Deterministic: the same seed gives the same inputs, and a failure prints the input.
final class PeopleFuzzTests: XCTestCase {
    /// SplitMix64: small, seeded, the same on every machine.
    private struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
    }

    private static let pieces: [String] = [
        "Anna", "Pere Soler", "Núria", "Nu\u{0301}ria", "O'Brien", "李雷", "דנה", "the CFO", "two engineers", "SPEAKER_01",
        " (", ")", "(Acme, Inc)", "(me)", " - buyer", " at ", " of ", " for ", " from ", " and ", " & ", " i ", " y ",
        ",", ";", "\n", "\r\n", "\r", "\t", "  ", ":", "Other participants:", "other participants: ", "{transcript_text}",
        "<<<", ">>>", "<<<<<", "---", "## Highlights", "**", "- ", "- [ ] ", "I'm ", "I am the ", "this is ", "soy ", "sóc ",
        "head of platform", "engineer", "University of Cambridge", "[", "]", "|", "\"", "'", "\\", "/", "\u{FEFF}", "\u{200F}",
        "👩‍💻", "🇬🇧", "", "a", ".", "!", "?", "123", "role:", "name:", "aliases:", "type: person",
        PeoplePages.blockStart, PeoplePages.blockEnd, "<!-- distavo:meetings:start", "last seen 2026-11-18",
    ]

    private func text(_ r: inout Random, max: Int = 14) -> String {
        (0..<r.below(max)).map { _ in r.pick(Self.pieces) }.joined()
    }

    func testParsersNeverCrashAndKeepTheirInvariants() {
        var r = Random(state: 20261123)
        for round in 0..<3000 {
            let t = text(&r)
            let people = PeoplePages.parseParticipants(t)
            for p in people {
                XCTAssertTrue(PeoplePages.isPersonName(p.name), "round \(round): \(t.debugDescription)")
                XCTAssertFalse(p.name.contains("\n") || p.name.contains(","), "round \(round): \(t.debugDescription)")
            }
            XCTAssertFalse(PeoplePages.listItems(t).contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            if let n = SpeakerHints.countedPeople(t) { XCTAssertGreaterThanOrEqual(n, 2, t.debugDescription) }
            _ = SpeakerHints.listedNames(t)
            for term in SpeakerHints(participants: t).participantTerms { XCTAssertFalse(term.isEmpty) }
            _ = SelfIntroductions.find(in: t)
            _ = SelfIntroductions.role(in: t)
            _ = MeetingBrief.names(in: t)
            _ = PeoplePages.aliases(inFrontmatter: t)
            _ = PeoplePages.frontmatter(of: t)
            let file = PeoplePages.fileName(for: t)
            XCTAssertTrue(file.hasSuffix(".md") && !file.hasPrefix(".") && !file.hasPrefix("_") && !file.contains("/"), file.debugDescription)
            // Typed notes: one line each, capped, and nothing that can close the prompt's delimited block.
            let pad = ScratchpadNotes(lines: [.init(offsetSeconds: r.below(9000), text: t)], people: t).sanitised()
            for line in pad.lines {
                XCTAssertFalse(line.text.contains("\n") || line.text.contains("{") || line.text.contains("<<<") || line.text.contains(">>>"),
                               t.debugDescription)
                XCTAssertLessThanOrEqual(line.text.count, ScratchpadNotes.maxLineChars)
            }
            if let p = pad.cleanPeople { XCTAssertLessThanOrEqual(p.count, ScratchpadNotes.maxPeopleChars) }
            // The participants text can never duplicate the transcript in the prompt.
            let prompt = Prompt.build(transcript: "UNIQUE-TRANSCRIPT-MARKER", noteOwner: "Me", userSpeaker: "SPEAKER_00", participants: t)
            XCTAssertEqual(prompt.components(separatedBy: "UNIQUE-TRANSCRIPT-MARKER").count - 1, 1, t.debugDescription)
        }
    }

    /// Whatever a people page looks like (damaged markers, any line endings), refreshing it never loses a
    /// line the owner wrote and a second refresh changes nothing.
    func testRefreshingAPageKeepsTheOwnersLinesAndIsStable() {
        var r = Random(state: 7)
        let zone = TimeZone(identifier: "Europe/London")!
        var person = PeoplePages.Person(name: "Oskar Lind")
        person.role = "buyer"
        person.meetings = [.init(base: "Meeting_2026-11-18_09.00.00", date: Date(timeIntervalSince1970: 1_795_000_000), title: "Call",
                                 notePath: URL(fileURLWithPath: "/n/Meeting_2026-11-18_09.00.00.md"), spoke: true)]
        let marker = "OWNER-LINE-"
        for round in 0..<1500 {
            var lines: [String] = r.below(3) == 0 ? [] : ["---", "type: person", "name: Oskar Lind", r.pick(["role: ", "role: CTO", "role:"]), "---"]
            var mine = 0
            for _ in 0..<r.below(9) {
                switch r.below(5) {
                case 0: lines.append(PeoplePages.blockStart)
                case 1: lines.append(PeoplePages.blockEnd)
                case 2: lines.append(text(&r, max: 4).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                                        .replacingOccurrences(of: "<!-- distavo", with: "").replacingOccurrences(of: "---", with: ""))
                default: mine += 1; lines.append("\(marker)\(mine) kept")
                }
            }
            // Lines between a complete start/end pair are Distavo's own block and are replaced by design.
            var page = lines.joined(separator: r.pick(["\n", "\n", "\r\n"]))
            if r.below(2) == 0 { page += "\n" }
            let once = PeoplePages.refreshed(page: page, with: person, timeZone: zone)
            XCTAssertEqual(PeoplePages.refreshed(page: once, with: person, timeZone: zone), once, "round \(round): \(page.debugDescription)")
            XCTAssertEqual(once.components(separatedBy: PeoplePages.blockStart).count - 1, 1, "round \(round): one block")
            let insideABlock = Self.ownerLinesInsideACompleteBlock(lines, marker: marker)
            for n in 1...max(1, mine) where mine > 0 && !insideABlock.contains(n) {
                XCTAssertTrue(once.contains("\(marker)\(n) kept"), "round \(round) lost line \(n): \(page.debugDescription)")
            }
        }
    }

    /// The owner lines that sit inside the block Distavo replaces: the last start marker followed by an end
    /// marker with no other start in between.
    private static func ownerLinesInsideACompleteBlock(_ lines: [String], marker: String) -> Set<Int> {
        for s in lines.indices.reversed() where lines[s] == PeoplePages.blockStart {
            guard let e = lines[(s + 1)...].firstIndex(of: PeoplePages.blockEnd),
                  !lines[(s + 1)..<e].contains(PeoplePages.blockStart) else { continue }
            return Set(lines[(s + 1)..<e].compactMap { l in l.hasPrefix(marker) ? Int(l.dropFirst(marker.count).prefix { $0.isNumber }) : nil })
        }
        return []
    }

    /// Merging two people pages and undoing it, whatever the pages look like: no line the owner wrote on the
    /// kept page is lost (only its `aliases:` may change), merging twice is merging once, and the other
    /// page's own text is on the kept page after the merge.
    func testMergingAndSeparatingPagesKeepsTheOwnersLines() {
        var r = Random(state: 23)
        func page(_ r: inout Random, name: String) -> String {
            let head = r.below(5) == 0 ? "" : "---\ntype: person\nname: \(name)\n" + (0..<r.below(4)).map { _ in
                r.pick(["aliases: [Ann, \"B, C\"]", "aliases:", "  - Ann", "  - ", "role: buyer", "organisation: Acme", "linkedin: ", "aliases: Ann, Bo", "role:"]) + "\n"
            }.joined() + "---\n"
            let body = (0..<r.below(8)).map { _ in text(&r, max: 5) }.joined(separator: "\n")
            return r.below(4) == 0 ? (head + body).replacingOccurrences(of: "\n", with: "\r\n") : head + body
        }
        func lines(_ s: String) -> [String] {
            s.components(separatedBy: "\n").map(PeoplePages.bare).filter { l in
                let t = l.trimmingCharacters(in: .whitespaces)
                return !l.hasPrefix("aliases:") && !t.hasPrefix("- ") && t != "-" && !t.isEmpty
            }
        }
        func aliases(_ s: String) -> [String] { PeoplePages.aliases(inFrontmatter: PeoplePages.frontmatter(of: s)["aliases"] ?? "") }
        for round in 0..<1500 {
            let keep = page(&r, name: "Petra Novak"), other = page(&r, name: "Petra N")
            let otherAliases = aliases(other)
            let merged = PeopleMerge.mergedPage(keep: keep, keepName: "Petra Novak", keepAliases: aliases(keep),
                                                other: other, otherName: "Petra N", otherAliases: otherAliases)
            let why = "round \(round): \(keep.debugDescription) + \(other.debugDescription)"
            for l in lines(keep) { XCTAssertTrue(lines(merged.text).contains(l), why) }
            let section = PeopleMerge.carried(from: other, name: "Petra N")
            XCTAssertEqual(merged.notes, !section.isEmpty, why)
            for l in section where !l.isEmpty { XCTAssertTrue(merged.text.components(separatedBy: "\n").map(PeoplePages.bare).contains(l), why) }
            if !keep.unicodeScalars.contains("\r") { XCTAssertFalse(merged.text.unicodeScalars.contains("\r"), why) }
            let again = PeopleMerge.mergedPage(keep: merged.text, keepName: "Petra Novak", keepAliases: aliases(merged.text),
                                               other: other, otherName: "Petra N", otherAliases: otherAliases)
            XCTAssertEqual(again.text, merged.text, why)
            let apart = PeopleMerge.separatedPage(keep: merged.text, keepAliases: aliases(merged.text),
                                                  other: other, otherName: "Petra N", removing: merged.added)
            for l in lines(keep) where !section.contains(l) { XCTAssertTrue(lines(apart.text).contains(l), why) }
            // Exactly the spellings the kept page had before are left.
            if PeoplePages.frontmatter(of: keep)["type"] == "person" {
                XCTAssertEqual(aliases(apart.text).map { $0.lowercased() }, aliases(keep).map { $0.lowercased() }, why)
            }
        }
    }

    // MARK: Second and third review of 2026-11-23

    /// The parsers changed by the reviews, on random input: no crash, no hang, and their own invariants.
    func testTheReviewedParsersNeverCrashAndKeepTheirInvariants() {
        var r = Random(state: 1123_3)
        let more = Self.pieces + [" - ", " — ", ": ", " E ", " I ", " Y ", "Marks and Spencer", "Will", "May", "Jo", "in ", "the ",
                                  "CTO", "CEO of ", " de ", "d'", "chair", "that's ", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{1B}[31m",
                                  "\u{07}", "\u{00}", "\u{202E}", "#", " # old", "[Petra, PN]", "  - Petra", "notes: |", "  indented line"]
        func text(_ max: Int = 14) -> String { (0..<r.below(max)).map { _ in r.pick(more) }.joined() }
        let people = ["Will Marsh", "May", "Jo", "Petra Novak", "Àngel Roca", "A", "O'Brien", "C++ Dev", "Anna (Acme)", ""].map { PeoplePages.Person(name: $0) }
        for round in 0..<3000 {
            let t = text()
            for part in PeoplePages.joined(t) { XCTAssertFalse(part.isEmpty && !t.isEmpty && PeoplePages.joined(t).count > 1, "round \(round): \(t.debugDescription)") }
            // Splitting never invents text: every part is made of the item's own characters, in order.
            // (A dash glued to a word gets the one space it lacks: "Petra- buyer" is read as "Petra - buyer".)
            XCTAssertLessThanOrEqual(PeoplePages.joined(t).joined().count, t.count + t.components(separatedBy: "- ").count - 1, t.debugDescription)
            XCTAssertLessThanOrEqual(SpeakerHints.joinedPeople(t).joined().count, t.count, t.debugDescription)
            _ = AskPeople.named(in: t, people: people)
            if let said = SelfIntroductions.stated(in: t) {
                XCTAssertFalse(said.role.isEmpty, t.debugDescription)
                XCTAssertFalse(said.role.contains("\n") || (said.organisation ?? "").contains("\n"), t.debugDescription)
            }
            _ = PeopleMerge.blockScalars(inFrontmatterOf: "---\n" + t + "\n---\n")
            for scalar in ScratchpadNotes.printable(t).unicodeScalars where scalar.properties.generalCategory == .control {
                XCTAssertTrue(CharacterSet.newlines.contains(scalar) || scalar == "\t", t.debugDescription)
            }
            var pad = ScratchpadNotes(lines: [])
            pad.people = t
            for scalar in (pad.cleanPeople ?? "").unicodeScalars { XCTAssertNotEqual(scalar.properties.generalCategory, .control, t.debugDescription) }
        }
    }

    /// Whatever the frontmatter of a page looks like, setting its aliases makes the page read back exactly
    /// those aliases, keeps every other line, and setting them back restores what the page said.
    func testSettingTheAliasesOfAnyPageReadsBackAndKeepsTheOtherLines() {
        var r = Random(state: 424242)
        let names = ["Petra N", "P. Novak", "Novak, P", "PN", "O'Brien", "petra", "Núria", "@petra", "- dash", "#1 buyer", "Anna \"the\" Berg", "x: y"]
        let forms: [([String]) -> [String]] = [
            { $0.isEmpty ? ["aliases: []"] : ["aliases: [" + $0.map(PeoplePages.quote).joined(separator: ", ") + "]"] },
            { ["aliases: [" + $0.map(PeoplePages.quote).joined(separator: ", ") + "]  # how she signs"] },
            { ["aliases:"] + $0.map { "  - " + PeoplePages.quote($0) } },
            { ["aliases:", "  # the list"] + $0.flatMap { ["  - " + PeoplePages.quote($0), ""] } },
            { ["aliases:"] + $0.map { "\t- " + PeoplePages.quote($0) } },
            { _ in [] },
        ]
        func read(_ page: String) -> [String] { PeoplePages.aliases(inFrontmatter: PeoplePages.frontmatter(of: page)["aliases"] ?? "") }
        for round in 0..<2000 {
            var had: [String] = []
            for _ in 0..<r.below(4) { let n = r.pick(names); if !had.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) { had.append(n) } }
            let form = r.below(forms.count)
            if form == 5 { had = [] }
            let alias = forms[form](had)
            let crlf = r.below(4) == 0
            var lines = ["---", "type: person", "name: Petra Novak"]
            let tail = ["role: buyer", "organisation: Acme"]
            // The aliases key first, in the middle or last.
            let at = r.below(3)
            lines += at == 0 ? alias + tail : at == 1 ? [tail[0]] + alias + [tail[1]] : tail + alias
            lines += ["---", "# Petra Novak", "", "OWNER LINE", ""]
            let page = lines.joined(separator: crlf ? "\r\n" : "\n")
            let was = read(page)
            // The list forms with nothing in them read as no aliases at all.
            XCTAssertEqual(was.map { $0.lowercased() }, had.map { $0.lowercased() }, "round \(round) form \(form): \(page.debugDescription)")
            var want = was
            for _ in 0..<(1 + r.below(3)) { let n = r.pick(names); if !want.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) { want.append(n) } }
            let merged = PeopleMerge.withAliases(page, want)
            XCTAssertEqual(read(merged).map { $0.lowercased() }.sorted(), want.map { $0.lowercased() }.sorted(), "round \(round) form \(form): \(merged.debugDescription)")
            for keep in ["type: person", "name: Petra Novak", "role: buyer", "organisation: Acme", "OWNER LINE", "# Petra Novak"] {
                XCTAssertEqual(merged.components(separatedBy: keep).count, 2, "round \(round) form \(form): \(keep) in \(merged.debugDescription)")
            }
            XCTAssertEqual(merged.contains("\r\n"), crlf && merged.contains("\r\n"), "round \(round)")
            if crlf { XCTAssertFalse(merged.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "round \(round) form \(form): a bare line feed in \(merged.debugDescription)") }
            let back = PeopleMerge.withAliases(merged, was, dropEmptyLine: alias.isEmpty)
            XCTAssertEqual(read(back).map { $0.lowercased() }, was.map { $0.lowercased() }, "round \(round) form \(form): \(back.debugDescription)")
            // A list, and a page that had no line, come back byte for byte.
            if form == 2 || form == 3 || form == 4 || form == 5, !(was.isEmpty && form != 5) {
                XCTAssertEqual(back, page, "round \(round) form \(form)")
            }
        }
    }
}
