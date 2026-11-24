import XCTest
@testable import DistavoCore

/// `RelativeDates` (D083): relative phrases in the action-item / task lines get the computed date in
/// brackets. Recording date fixed at Wed 18 Nov 2026 09:00 Europe/London; synthetic text only.
final class RelativeDatesTests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/London")!
    private var recording: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 18; c.hour = 9
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        return cal.date(from: c)!
    }
    private func tasks(_ line: String) -> String { "# Note\n\n## Action items\n- \(line)\n" }
    private func resolved(_ line: String) -> String {
        RelativeDates.resolve(note: tasks(line), recordingDate: recording, timeZone: zone)
    }
    private func assertLine(_ input: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(resolved(input), tasks(expected), file: file, line: line)
    }

    func testTomorrow() { assertLine("Petra sends the quote tomorrow", "Petra sends the quote tomorrow (Thu 19 Nov 2026)") }
    func testToday() { assertLine("Call the supplier today", "Call the supplier today (Wed 18 Nov 2026)") }
    func testYesterdayInSpanish() { assertLine("Lo mandó ayer", "Lo mandó ayer (Tue 17 Nov 2026)") }
    func testBareWeekday() { assertLine("Oskar sends the numbers by Friday", "Oskar sends the numbers by Friday (Fri 20 Nov 2026)") }
    func testSameWeekdayIsAmbiguous() {
        assertLine("Review on Wednesday", "Review on Wednesday (Wed 18 or Wed 25 Nov 2026?)")
    }
    func testNextWeekdayIsAmbiguous() {
        assertLine("Meet again next Monday", "Meet again next Monday (Mon 23 or Mon 30 Nov 2026?)")
    }
    func testEndOfNextWeek() { assertLine("Ship it by end of next week", "Ship it by end of next week (Fri 27 Nov 2026)") }
    func testEndOfTheWeek() { assertLine("Done by the end of the week", "Done by the end of the week (Fri 20 Nov 2026)") }
    func testNextWeek() { assertLine("Book the van next week", "Book the van next week (week of Mon 23 Nov 2026)") }
    func testNextMonth() { assertLine("Plan the open day next month", "Plan the open day next month (December 2026)") }
    func testCatalanTomorrow() { assertLine("La Nadia ho envia demà", "La Nadia ho envia demà (Thu 19 Nov 2026)") }
    func testCatalanWeekday() { assertLine("Trucar dilluns", "Trucar dilluns (Mon 23 Nov 2026)") }
    func testSpanishWeekday() { assertLine("Enviar el lunes", "Enviar el lunes (Mon 23 Nov 2026)") }
    func testSpanishNextWeek() { assertLine("Hablar la semana que viene", "Hablar la semana que viene (week of Mon 23 Nov 2026)") }
    func testSpanishMorningIsNotTomorrow() { assertLine("Llamar esta mañana", "Llamar esta mañana") }

    func testModelBracketIsUntouched() {
        let line = "Send it Friday (interpreted from 'Friday')"
        assertLine(line, line)
    }
    func testExplicitDayMonthIsUnchanged() {
        assertLine("Send the quote by 20 Nov", "Send the quote by 20 Nov")
        assertLine("Send the quote by 20 November 2026", "Send the quote by 20 November 2026")
    }
    func testLineAlreadyHoldingADateIsUnchanged() {
        assertLine("Tomorrow Petra confirms the 18 Nov booking", "Tomorrow Petra confirms the 18 Nov booking")
    }
    func testTwoPhrasesOnOneLine() {
        assertLine("Draft tomorrow, send on Friday", "Draft tomorrow (Thu 19 Nov 2026), send on Friday (Fri 20 Nov 2026)")
    }
    func testCheckboxLineOutsideTasksSectionIsResolved() {
        let note = "# Note\n\n## Summary\n- [ ] Oskar orders gloves tomorrow\n"
        XCTAssertEqual(RelativeDates.resolve(note: note, recordingDate: recording, timeZone: zone),
                       "# Note\n\n## Summary\n- [ ] Oskar orders gloves tomorrow (Thu 19 Nov 2026)\n")
    }
    func testTextOutsideTheTasksSectionIsUnchanged() {
        let note = "# Note\n\n## Summary\nWe meet tomorrow and on Friday.\n\n## Action items\n- Petra orders gloves tomorrow\n\n## Risks\nThe tree delivery may slip to next week.\n"
        let expected = "# Note\n\n## Summary\nWe meet tomorrow and on Friday.\n\n## Action items\n- Petra orders gloves tomorrow (Thu 19 Nov 2026)\n\n## Risks\nThe tree delivery may slip to next week.\n"
        XCTAssertEqual(RelativeDates.resolve(note: note, recordingDate: recording, timeZone: zone), expected)
    }
    func testCatalanAndSpanishTaskHeadings() {
        for heading in ["## Tasques", "## Accions", "## Tareas", "## Acciones", "## Tasks", "## Next steps"] {
            let note = "# N\n\n\(heading)\n- demà\n"
            XCTAssertEqual(RelativeDates.resolve(note: note, recordingDate: recording, timeZone: zone),
                           "# N\n\n\(heading)\n- demà (Thu 19 Nov 2026)\n", heading)
        }
    }
    func testIdempotent() {
        let note = "# N\n\n## Action items\n- Draft tomorrow, review next Monday, ship end of next week\n- Plan next month\n"
        let once = RelativeDates.resolve(note: note, recordingDate: recording, timeZone: zone)
        XCTAssertNotEqual(once, note)
        XCTAssertEqual(RelativeDates.resolve(note: once, recordingDate: recording, timeZone: zone), once)
    }
    func testWordsContainingWeekdaysAreLeftAlone() {
        assertLine("Fix the todays-report script", "Fix the todays-report script")
    }
    func testNextWeekdayAcrossAMonthAndYear() {
        var c = DateComponents(); c.year = 2026; c.month = 12; c.day = 28; c.hour = 9   // Monday
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        let note = "# N\n\n## Action items\n- Meet next Wednesday\n"
        XCTAssertEqual(RelativeDates.resolve(note: note, recordingDate: cal.date(from: c)!, timeZone: zone),
                       "# N\n\n## Action items\n- Meet next Wednesday (Wed 30 Dec 2026 or Wed 6 Jan 2027?)\n")
    }

    func testConfigKeyAbsentIsOff() throws {
        let old = try JSONDecoder().decode(SummariseConfig.self, from: Data("{}".utf8))
        XCTAssertFalse(old.resolveRelativeDates)
        XCTAssertTrue(Config.recommendedForThisMac().summarise.resolveRelativeDates)
    }
    // Review round 1 (drive 2026-11-23).
    func testCatalanAndOfDatesAreExplicit() {
        assertLine("Enviar dijous 1 d'abril", "Enviar dijous 1 d'abril")
        assertLine("Enviar dijous 1 d’abril", "Enviar dijous 1 d’abril")
        assertLine("Send it Thursday the 3rd of December", "Send it Thursday the 3rd of December")
        assertLine("Enviar el viernes 20 de noviembre", "Enviar el viernes 20 de noviembre")
    }
    func testDomingoTheNameIsLeftAlone() {
        assertLine("Domingo sends the contract", "Domingo sends the contract")
        assertLine("Enviar el domingo", "Enviar el domingo (Sun 22 Nov 2026)")
    }
    func testWikiLinksAndUrlsAreLeftAlone() {
        assertLine("Read [[Notes from Friday]]", "Read [[Notes from Friday]]")
        assertLine("See https://example.org/today/plan", "See https://example.org/today/plan")
    }
    func testObsidianTagIsNotAHeading() {
        let note = "# N\n\n## Action items\n#urgent call\n- Order gloves tomorrow\n"
        XCTAssertEqual(RelativeDates.resolve(note: note, recordingDate: recording, timeZone: zone),
                       "# N\n\n## Action items\n#urgent call\n- Order gloves tomorrow (Thu 19 Nov 2026)\n")
    }
}
