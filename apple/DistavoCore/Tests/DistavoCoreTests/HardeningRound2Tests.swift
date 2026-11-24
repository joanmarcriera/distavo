import XCTest
@testable import DistavoCore

/// Regression tests for defects found by the bug hunts of 2026-11-23 (voice, meeting hints). Synthetic names only.
final class HardeningRound2Tests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_795_000_000)
    private func ang(_ d: Double) -> [Float] { [Float(cos(d * .pi / 180)), Float(sin(d * .pi / 180)), 0] }

    // MARK: Voice

    func testAHugeVectorIsNormalisedNotZeroed() {
        var s = VoiceProfileStore(model: "m")
        XCTAssertTrue(s.enrol(name: "Anna", sample: [1e20, 0, 0], now: t0))
        XCTAssertEqual(s.profiles[0].samples[0][0], 1, accuracy: 1e-4)
        XCTAssertNil(VoiceProfileStore.normalised([0, 0, 0]))
        XCTAssertNil(VoiceProfileStore.normalised([.nan, 1]))
    }

    func testATurnOfExactlyTheMinimumIsSampled() {
        let segs = (0..<5).map { TranscriptSegments.Segment(start: Double($0) * 10, end: Double($0) * 10 + 2.5, text: "w", speaker: "A") }
        XCTAssertEqual(VoiceSampler.ranges(for: segs)["A"]?.count, 5)
    }

    func testARememberedNameIsStoredComposed() {
        var s = VoiceProfileStore(model: "m")
        XCTAssertTrue(s.enrol(name: "Nu\u{0301}ria", sample: [1, 0], now: t0))
        XCTAssertEqual(s.profiles.first?.name.unicodeScalars.count, "N\u{00FA}ria".unicodeScalars.count)
    }

    func testARivalUnderTheThresholdDoesNotBlockTheTeam() {
        var s = VoiceProfileStore(model: "m")
        XCTAssertTrue(s.enrol(name: "Anna", sample: ang(50), now: t0))    // 0.64 to the speaker
        XCTAssertTrue(s.enrol(name: "Aina", sample: ang(-54), now: t0))   // 0.59: under the threshold
        XCTAssertTrue(s.enrol(name: "Pere", sample: [0, 0, 1], now: t0))
        let team = VoiceTeams(meetings: Array(repeating: ["Anna", "Pere"], count: 5) + Array(repeating: ["Aina", "Pere"], count: 3))
        XCTAssertEqual(s.match(speakers: ["S0": [0, 0, 1], "S1": ang(0)], team: team)["S1"]?.name, "Anna")
        XCTAssertNil(s.match(speakers: ["S0": [0, 0, 1], "S1": ang(0)])["S1"])   // voice alone: still too close
    }

    func testRememberNeverOverwritesAFileItCannotRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hard-\(UUID().uuidString)")
        let work = root.appendingPathComponent("work"), support = root.appendingPathComponent("support")
        for d in [work, support] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        try TranscriptSegments(segments: (0..<6).map { .init(start: Double($0) * 10, end: Double($0) * 10 + 8, text: "words", speaker: "Petra") })
            .save(workDir: work, base: "demo")
        let newer = #"{"version":2,"model":"m","profiles":[{"name":"Zed","samples":[[1,0]],"enrolments":1,"created":"2026-01-01T00:00:00Z","updated":"2026-01-01T00:00:00Z"}]}"#
        try newer.write(to: VoiceProfileStore.url(supportDir: support), atomically: true, encoding: .utf8)
        let stored = try await VoiceRecognition.remember(names: ["Petra"], base: "demo", audio: URL(fileURLWithPath: "/dev/null"),
                                                         workDir: work, supportDir: support, model: "m",
                                                         embed: { _, _ in ["Petra": [0, 1]] }, now: t0)
        XCTAssertEqual(stored, [])
        XCTAssertEqual(try String(contentsOf: VoiceProfileStore.url(supportDir: support), encoding: .utf8), newer)
    }

    func testRenamingOneSpeakerKeepsTheOtherGuessAGuess() {
        let before = SpeakerNames(names: ["SPEAKER_00": "Anna"], byVoice: ["Anna"])
        XCTAssertEqual(before.composing(["SPEAKER_01": "Petra"]).byVoice, ["Anna"])
        // The owner corrects the guess itself: it is theirs now.
        XCTAssertNil(before.composing(["Anna": "Hanna"]).byVoice)
        XCTAssertNil(SpeakerNames(names: ["SPEAKER_00": "Anna"]).composing(["SPEAKER_01": "Petra"]).byVoice)
    }

    func testOnlyTheOwnersOwnNameMakesTheOwner() {
        XCTAssertTrue(VoiceRecognition.isOwner("Dana Owner", noteOwner: " dana owner "))
        XCTAssertTrue(VoiceRecognition.isOwner("Dana Owner (me)", noteOwner: "Dana Owner"))
        XCTAssertFalse(VoiceRecognition.isOwner("Petra Novak", noteOwner: "Dana Owner"))
        XCTAssertFalse(VoiceRecognition.isOwner("Me", noteOwner: "Me"))   // the default owner name identifies nobody
        XCTAssertFalse(VoiceRecognition.isOwner("Anna", noteOwner: ""))
    }

    // MARK: Meeting hints

    func testListedPeopleBecomeSpellingTerms() {
        XCTAssertEqual(Set(SpeakerHints(participants: "Other participants: Anna, Pere").participantTerms), ["Anna", "Pere"])
        XCTAssertEqual(Set(SpeakerHints(participants: "Dana Owner (me): buyer. Other participants: Anna, Pere").participantTerms), ["Anna", "Pere"])
        XCTAssertEqual(Set(SpeakerHints(participants: "Other participants: Anna (CEO, Acme Ltd), Pere").participantTerms), ["Acme Ltd", "Anna", "Pere"])
    }

    func testBracesInTheParticipantsLineStayLiteral() {
        let out = Prompt.build(transcript: "UNIQUE-MARKER", noteOwner: "Me", userSpeaker: "SPEAKER_00",
                               participants: "Anna {transcript_text} {user_speaker}")
        XCTAssertEqual(out.components(separatedBy: "UNIQUE-MARKER").count - 1, 1)
        XCTAssertTrue(out.contains("Anna (transcript_text) (user_speaker)"), out)
    }

    func testCountingJoinedAndUncasedNames() {
        XCTAssertEqual(SpeakerHints.suggestedCount("Other participants: Anna and Pere"), 3)
        XCTAssertEqual(SpeakerHints.suggestedCount("Other participants: Anna & Pere"), 3)
        XCTAssertEqual(SpeakerHints.suggestedCount("Other participants: \u{674E}\u{96F7}, \u{738B}\u{82B3}"), 3)
        XCTAssertEqual(SpeakerHints.suggestedCount("Other participants: Anna (Marks & Spencer), Pere"), 3)
        XCTAssertEqual(SpeakerHints.suggestedCount("Other participants: Anna and people from Acme"), 2)
        XCTAssertEqual(SpeakerHints.suggestedCount("Other participants: Anna (Research and Development)"), 2)
    }

    func testOwnerRoleStopsAtTheMarkerInAnyCase() {
        XCTAssertEqual(SpeakerSuggestions.role(in: "Dana (me): candidate. other participants: Anna"), "candidate")
    }
}

/// Renaming and merging remembered voices (`VoiceProfileStore.rename`). Synthetic names only.
final class VoiceRenameTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_795_000_000), t1 = Date(timeIntervalSince1970: 1_795_100_000)

    func testRenameAndMerge() {
        var s = VoiceProfileStore(model: "m")
        XCTAssertTrue(s.enrol(name: "Bo", sample: [1, 0, 0], now: t0))
        XCTAssertTrue(s.enrol(name: "Bo Lind", sample: [0, 1, 0], now: t1))
        XCTAssertTrue(s.enrol(name: "Anna", sample: [0, 0, 1], now: t1))
        XCTAssertEqual(s.rename(name: "anna", to: " Hanna "), .renamed)
        XCTAssertEqual(s.rename(name: "Hanna", to: "Hanna"), .unchanged)
        XCTAssertEqual(s.rename(name: "Hanna", to: "hanna"), .renamed, "capitals of the same voice")
        XCTAssertEqual(s.rename(name: "Nobody", to: "X"), .unchanged)
        XCTAssertEqual(s.rename(name: "Bo", to: "  "), .unchanged)
        XCTAssertEqual(s.rename(name: "Bo", to: "SPEAKER_01"), .unchanged)
        XCTAssertEqual(s.rename(name: "Bo", to: "bo lind", now: t1), .merged)
        XCTAssertEqual(s.names.sorted(), ["Bo Lind", "hanna"])
        let merged = s.profiles.first { $0.name == "Bo Lind" }!
        XCTAssertEqual(merged.samples.count, 2)
        XCTAssertEqual(merged.enrolments, 2)
        XCTAssertEqual(merged.created, t0)
        // Both of the old voices are now recognised as the one person.
        XCTAssertEqual(s.match(speakers: ["A": [1, 0, 0]])["A"]?.name, "Bo Lind")
        XCTAssertEqual(s.match(speakers: ["A": [0, 1, 0]])["A"]?.name, "Bo Lind")
    }

    func testMergeKeepsTheNewestSamplesAndRefusesAnotherShape() {
        var s = VoiceProfileStore(model: "m")
        for i in 0..<VoiceProfileStore.maxSamples { XCTAssertTrue(s.enrol(name: "A", sample: (0..<12).map { $0 == i ? 1 : 0 }, now: t0)) }
        XCTAssertTrue(s.enrol(name: "B", sample: (0..<12).map { $0 == 11 ? 1 : 0 }, now: t0))
        XCTAssertEqual(s.rename(name: "B", to: "A"), .merged)
        XCTAssertEqual(s.profiles[0].samples.count, VoiceProfileStore.maxSamples)
        XCTAssertEqual(s.profiles[0].samples.last?[11], 1)
        XCTAssertTrue(s.enrol(name: "C", sample: [1, 0], now: t0))
        XCTAssertEqual(s.rename(name: "C", to: "A"), .unchanged)
        XCTAssertEqual(s.names, ["A", "C"])
    }
}

final class VoiceReviewQueueTests: XCTestCase {
    /// Naming a voice one meeting at a time (the app's queue) gives the same outcome as naming it in one go.
    func testOneMeetingAtATimeEqualsAllAtOnce() throws {
        func run(stepwise: Bool) throws -> (VoiceReview.Applied, VoiceProfileStore, [String]) {
            let root = TestTemp.root.appendingPathComponent("distavo-queue-\(UUID().uuidString)")
            let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
            for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            let now = Date(timeIntervalSince1970: 1_795_000_000)
            var occ: [VoiceReview.Occurrence] = []
            for (i, base) in ["m1", "m2", "m3"].enumerated() {
                // m2 already has a speaker called Petra: that meeting is skipped either way.
                let other = base == "m2" ? "Petra" : "SPEAKER_00"
                try "# T\n\nSPEAKER_01: hello. \(other): hi.\n".write(to: notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
                try "SPEAKER_01: hello.\n\(other): hi.\n".write(to: work.appendingPathComponent("\(base).transcript.clean.txt"), atomically: true, encoding: .utf8)
                try TranscriptSegments(segments: [.init(start: 0, end: 9, text: "hello", speaker: "SPEAKER_01"),
                                                  .init(start: 9, end: 12, text: "hi", speaker: other)]).save(workDir: work, base: base)
                occ.append(.init(base: base, label: "SPEAKER_01", title: "T", date: now.addingTimeInterval(Double(i)), sampleStart: 0, sampleEnd: 9,
                                 quote: "hello", embedding: [1, Float(i) * 0.01, 0]))
            }
            var store = VoiceProfileStore(model: "m")
            var total = VoiceReview.Applied()
            if stepwise {
                for o in occ {
                    total = VoiceReview.merged(total, VoiceReview.apply(voice: .init(id: 1, occurrences: [o], suggestedName: nil), name: "Petra",
                                                                        remember: true, notesDir: notes, workDir: work, store: &store, now: now))
                }
            } else {
                total = VoiceReview.apply(voice: .init(id: 1, occurrences: occ, suggestedName: nil), name: "Petra", remember: true,
                                          notesDir: notes, workDir: work, store: &store, now: now)
            }
            let texts = try ["m1", "m2", "m3"].map { try String(contentsOf: notes.appendingPathComponent("\($0).md"), encoding: .utf8) }
            return (total, store, texts)
        }
        let all = try run(stepwise: false), step = try run(stepwise: true)
        XCTAssertEqual(all.0, step.0)
        XCTAssertEqual(all.0.renamed, ["m1", "m3"])
        XCTAssertEqual(Array(all.0.skipped.keys), ["m2"])
        XCTAssertEqual(all.1, step.1)
        XCTAssertEqual(all.2, step.2)
        XCTAssertTrue(all.2[0].contains("Petra: hello"))
    }
}

/// Regression tests for the recorder bug hunt of 2026-11-23 (third round). Synthetic names only.
final class HardeningRecorderTests: XCTestCase {
    private func pad(_ text: String) -> ScratchpadNotes { ScratchpadNotes(lines: [.init(offsetSeconds: 5, text: text)]) }

    func testAHeadingThatOnlyMentionsHighlightsIsNotTheSection() {
        for body in ["**Highlight of the quarter: revenue**", "## Risks highlighted by Anna\n- one", "**highlights** were few, he said"] {
            let out = pad("ask about notice").ensureHighlights(in: "# Meeting notes\n\n## Summary\n\n\(body)\n")
            XCTAssertTrue(out.contains("ask about notice"), body)
        }
        for heading in ["## Highlights", "## Key highlights:", "**Highlights**", "**Highlights:**", "## ⭐ Highlights"] {
            let note = "# Meeting notes\n\n\(heading)\n- something else\n"
            XCTAssertEqual(pad("ask about notice").ensureHighlights(in: note), note, heading)
        }
    }

    func testATypedWordInProseIsNotAListedHighlight() {
        let out = pad("price").ensureHighlights(in: "# Meeting notes\n\n## Summary\nThe price was agreed.\n")
        XCTAssertTrue(out.contains("**00:05** price"), out)
        let translated = "# Notes\n\n## Destacats\n- **00:05** price\n\n## Resum\nText.\n"
        XCTAssertEqual(pad("price").ensureHighlights(in: translated), translated)
    }

    func testDelimitersCannotBeRebuilt() {
        let text = pad("a <<<<< b >>>>> c <<<<<<< d").sanitised().lines[0].text
        XCTAssertFalse(text.contains("<<<") || text.contains(">>>"), text)
        XCTAssertEqual(pad("a << b >> c").sanitised().lines[0].text, "a << b >> c")
    }

    func testCompoundSurnamesAreOnePerson() {
        XCTAssertEqual(SpeakerHints.countedPeople("Other participants: Josep Puig i Cadafalch"), 2)
        XCTAssertEqual(SpeakerHints.countedPeople("Other participants: Santiago Ramón y Cajal, Pere"), 3)
        XCTAssertEqual(SpeakerHints.countedPeople("Other participants: Anna i Pere"), 3)
        XCTAssertEqual(SpeakerHints.countedPeople("Other participants: Anna Puig i Pere Soler"), 3)
        XCTAssertEqual(SpeakerHints.countedPeople("Other participants: Anna Puig and Pere"), 3)
    }

    func testAListPastedWithWindowsLineEnds() {
        let h = SpeakerHints(participants: "Other participants: Anna Puig\r\nPere Soler\rJo Marsh")
        XCTAssertEqual(Set(h.participantTerms), ["Anna Puig", "Pere Soler", "Jo Marsh"])
        XCTAssertEqual(SpeakerHints.countedPeople(h.participants), 4)
        XCTAssertEqual(SpeakerHints.listedNames(h.participants), ["anna", "pere", "jo"])
    }

    func testAnUnreadableTickDoesNotBringBackTheOfferForTheCallJustRecorded() {
        var d = MeetingDetector(policy: .init(apps: ["us.zoom.xos"]))
        var offers = 0
        func tick(_ apps: Set<String>?, recording: Bool, _ now: TimeInterval) {
            if d.observe(.init(capturingBundleIDs: apps, isRecording: recording, now: now)) != .none { offers += 1 }
        }
        tick(["us.zoom.xos"], recording: true, 0)
        tick(nil, recording: true, 1)
        for t in 2...1000 { tick(["us.zoom.xos"], recording: false, TimeInterval(t)) }
        XCTAssertEqual(offers, 0)
    }
}

/// Confirming a voice-recognised name (`SpeakerNames.confirming`). Synthetic names only.
final class VoiceGuessConfirmTests: XCTestCase {
    func testConfirmingRemovesOnlyThatGuess() throws {
        let work = TestTemp.root.appendingPathComponent("distavo-confirm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let names = SpeakerNames(names: ["SPEAKER_00": "Anna", "SPEAKER_01": "Pere", "SPEAKER_02": "Jo"], byVoice: ["Anna", "Pere", "Gone"])
        try names.encoded().write(to: SpeakerNames.url(workDir: work, base: "m"))
        XCTAssertEqual(SpeakerNames.voiceGuesses(workDir: work, base: "m"), ["Anna", "Pere"], "a guess no speaker carries any more is not offered")
        XCTAssertFalse(try SpeakerNames.confirmVoiceNames(["Jo", "Nobody"], workDir: work, base: "m"), "not guesses: nothing written")
        XCTAssertTrue(try SpeakerNames.confirmVoiceNames(["anna"], workDir: work, base: "m"))
        let after = try XCTUnwrap(SpeakerNames.load(workDir: work, base: "m"))
        XCTAssertEqual(after.names, names.names)
        XCTAssertEqual(SpeakerNames.voiceGuesses(workDir: work, base: "m"), ["Pere"])
        XCTAssertTrue(try SpeakerNames.confirmVoiceNames(["Pere", "Gone"], workDir: work, base: "m"))
        XCTAssertNil(SpeakerNames.load(workDir: work, base: "m")?.byVoice)
        XCTAssertFalse(try SpeakerNames.confirmVoiceNames(["Anna"], workDir: work, base: "none"))
    }

    func testAConfirmedGuessCreatesThePersonPage() throws {
        let root = TestTemp.root.appendingPathComponent("distavo-confirm-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let base = "Meeting_2026-11-18_09.00.00"
        try "# Call\n".write(to: notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
        try SpeakerNames(names: ["SPEAKER_01": "Oskar Lind"], byVoice: ["Oskar Lind"]).encoded().write(to: SpeakerNames.url(workDir: work, base: base))
        let zone = TimeZone(identifier: "Europe/London")!
        XCTAssertEqual(try PeoplePages.update(notesDir: notes, workDir: work, timeZone: zone).created, [])
        try SpeakerNames.confirmVoiceNames(["Oskar Lind"], workDir: work, base: base)
        XCTAssertEqual(try PeoplePages.update(notesDir: notes, workDir: work, timeZone: zone).created, ["Oskar Lind"])
    }
}

final class VoiceReviewBatchTests: XCTestCase {
    func testNewestFirstAndLimited() {
        let t = Date(timeIntervalSince1970: 1_795_000_000)
        let items = [("b", t), ("a", t), ("old", t.addingTimeInterval(-9)), ("new", t.addingTimeInterval(9))]
        func run(_ limit: Int?) -> [String] { VoiceReview.newest(items, date: { $0.1 }, base: { $0.0 }, limit: limit).map(\.0) }
        XCTAssertEqual(run(nil), ["new", "a", "b", "old"])
        XCTAssertEqual(run(2), ["new", "a"])
        XCTAssertEqual(run(0), [])
        XCTAssertEqual(run(-3), [])
        XCTAssertEqual(run(99), ["new", "a", "b", "old"])
        XCTAssertEqual(VoiceReview.firstBatch, 20)
    }
}

/// Regression tests for the final bug hunt of 2026-11-23. Synthetic names only.
final class HardeningFinalTests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/London")!
    private func dirs() throws -> (notes: URL, work: URL) {
        let root = TestTemp.root.appendingPathComponent("distavo-final-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        return (notes, work)
    }

    func testConfirmingANameKeepsResetWorking() throws {
        let (n, w) = try dirs()
        let base = "m"
        let original = "# T\n\nSPEAKER_00: hello.\n"
        try original.write(to: n.appendingPathComponent("m.md"), atomically: true, encoding: .utf8)
        try "SPEAKER_00: hello.\n".write(to: w.appendingPathComponent("m.transcript.clean.txt"), atomically: true, encoding: .utf8)
        _ = try SpeakerRename.apply(mapping: ["SPEAKER_00": "Anna Berg"], base: base, notesDir: n, workDir: w)
        let before = try Data(contentsOf: SpeakerNames.url(workDir: w, base: base))
        XCTAssertFalse(try SpeakerNames.confirmVoiceNames(["Anna Berg"], workDir: w, base: base), "not a guess: nothing to write")
        XCTAssertEqual(try Data(contentsOf: SpeakerNames.url(workDir: w, base: base)), before)
        // A real guess confirmed keeps the hashes too.
        var names = try XCTUnwrap(SpeakerNames.load(workDir: w, base: base))
        names.byVoice = ["Anna Berg"]
        try names.encoded().write(to: SpeakerNames.url(workDir: w, base: base))
        XCTAssertTrue(try SpeakerNames.confirmVoiceNames(["Anna Berg"], workDir: w, base: base))
        let after = try XCTUnwrap(SpeakerNames.load(workDir: w, base: base))
        XCTAssertNotNil(after.lastNoteSHA256)
        XCTAssertEqual(after.originalNoteSHA256, names.originalNoteSHA256)
        XCTAssertTrue(try SpeakerRename.reset(base: base, notesDir: n, workDir: w).noteRestored)
        XCTAssertEqual(try String(contentsOf: n.appendingPathComponent("m.md"), encoding: .utf8), original)
    }

    func testTheNameEndsAtTheCompanyEvenWithABracketAfterIt() {
        func p(_ t: String) -> [String?] { let x = PeoplePages.parseParticipants(t).first; return [x?.name, x?.organisation, x?.role] }
        XCTAssertEqual(p("Pere at Acme (CTO)"), ["Pere", "Acme", "CTO"])
        XCTAssertEqual(p("Pere Puig from Acme (remote)"), ["Pere Puig", "Acme", "remote"])
        XCTAssertEqual(p("Pere (Acme) for Globex"), ["Pere", "Globex", "Acme"])
        XCTAssertEqual(p("Pere (buyer at Acme) from Globex"), ["Pere", "Acme", "buyer"])
        XCTAssertEqual(p("Annika for WWT"), ["Annika", "WWT", nil])
    }

    func testBriefNamesAreOnlyPeople() {
        XCTAssertEqual(MeetingBrief.names(in: "Anna (Marks and Spencer), Pere"), ["Anna", "Pere"])
        XCTAssertEqual(MeetingBrief.names(in: "Anna - sales and marketing; Procter & Gamble; Dana (me), the CFO"), ["Anna", "Procter", "Gamble"])
        XCTAssertEqual(MeetingBrief.names(in: "Pere and Jo & anna i Marta"), ["Pere", "Jo", "anna", "Marta"])
        XCTAssertEqual(MeetingBrief.names(in: "pere soler, two engineers"), ["pere"])
    }

    func testTwoPeopleSharingAFirstNameAreNeverGuessed() throws {
        let (n, w) = try dirs()
        for (base, name) in [("Meeting_2026-11-10_09.00.00", "Anna Berg"), ("Meeting_2026-11-11_09.00.00", "Anna Puig")] {
            try "# T\n\n- [ ] Send it - owner: Anna\n".write(to: n.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
            try SpeakerNames(names: ["S0": name]).encoded().write(to: SpeakerNames.url(workDir: w, base: base))
        }
        let people = PeoplePages.folder(notesDir: n)
        try FileManager.default.createDirectory(at: people, withIntermediateDirectories: true)
        try "---\ntype: person\nname: Anna Berg\nrole: buyer\n---\n".write(to: people.appendingPathComponent("Anna Berg.md"), atomically: true, encoding: .utf8)
        let e = MeetingBrief.entries(for: ["Anna", "Anna Berg", "Anna Puig"], notesDir: n, workDir: w, timeZone: zone)
        XCTAssertNil(e[0].person, "a page for one Anna does not decide which Anna was meant")
        XCTAssertEqual(e[0].role, "")
        XCTAssertEqual(e[1].person?.name, "Anna Berg")
        XCTAssertEqual(e[1].theirs.count, 0, "'owner: Anna' is nobody's while there are two Annas")
        XCTAssertEqual(e[1].others.count, 1)
        XCTAssertEqual(e[2].theirs.count, 0)
    }

    func testMergingKeepsTheNewerVoicesSamples() {
        func v(_ i: Int) -> [Float] { (0..<12).map { $0 == i ? 1 : 0 } }
        let t0 = Date(timeIntervalSince1970: 1_795_000_000)
        var s = VoiceProfileStore(model: "m")
        for i in 0..<VoiceProfileStore.maxSamples { XCTAssertTrue(s.enrol(name: "Old", sample: v(i), now: t0)) }
        XCTAssertTrue(s.enrol(name: "New", sample: v(7), now: t0.addingTimeInterval(86_400)))
        XCTAssertEqual(s.rename(name: "Old", to: "New", now: t0.addingTimeInterval(90_000)), .merged)
        XCTAssertEqual(s.profiles[0].samples.count, VoiceProfileStore.maxSamples)
        XCTAssertTrue(s.profiles[0].samples.contains(v(7)))
    }

    func testLastSeenStopsAtTheEndOfTheBlockAndABriefIsNeverAPerson() throws {
        let (n, _) = try dirs()
        let people = PeoplePages.folder(notesDir: n)
        try FileManager.default.createDirectory(at: people, withIntermediateDirectories: true)
        try "---\ntype: person\nname: Oskar Lind\n---\n\(PeoplePages.blockStart)\n## Meetings\n\(PeoplePages.blockEnd)\nI last seen 2031-01-01 him.\n"
            .write(to: people.appendingPathComponent("Oskar Lind.md"), atomically: true, encoding: .utf8)
        try "---\ntype: person\nname: Not A Person\n---\n".write(to: people.appendingPathComponent("_Brief.md"), atomically: true, encoding: .utf8)
        let k = PeoplePages.known(notesDir: n)
        XCTAssertEqual(k.map(\.name), ["Oskar Lind"])
        XCTAssertEqual(k[0].lastSeen, "")
    }
}
