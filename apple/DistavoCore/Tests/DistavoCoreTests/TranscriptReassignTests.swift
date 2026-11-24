import XCTest
@testable import DistavoCore

/// "This part was someone else": two people came out of the diariser as one speaker, and the owner moves a
/// stretch of the transcript to another (or a new) speaker. Synthetic names only.
final class TranscriptReassignTests: XCTestCase {

    /// SPEAKER_00 holds two voices: the third and fourth segments are really someone else.
    private func sample() -> TranscriptSegments {
        TranscriptSegments(segments: [
            .init(start: 0, end: 2, text: "good morning all", speaker: "SPEAKER_00",
                  words: [.init(word: "good", start: 0, end: 1, speaker: "SPEAKER_00"), .init(word: "morning", start: 1, end: 2)]),
            .init(start: 2, end: 4, text: "thanks for joining", speaker: "SPEAKER_00"),
            .init(start: 4, end: 6, text: "happy to be here", speaker: "SPEAKER_00",
                  words: [.init(word: "happy", start: 4, end: 5, speaker: "SPEAKER_00")]),
            .init(start: 6, end: 8, text: "I run procurement", speaker: "SPEAKER_00"),
            .init(start: 8, end: 10, text: "over to the numbers", speaker: "SPEAKER_01"),
        ])
    }

    private func range(of text: String, in layout: TranscriptLayout) -> NSRange { (layout.text as NSString).range(of: text) }

    func testASelectionCoversEverySegmentItTouches() {
        let l = TranscriptLayout(sample())
        // A caret inside one paragraph.
        XCTAssertEqual(l.segmentIndices(in: NSRange(location: range(of: "happy", in: l).location + 2, length: 0)), [2])
        // A caret at the very end of a paragraph still means that paragraph.
        let third = range(of: "happy to be here", in: l)
        XCTAssertEqual(l.segmentIndices(in: NSRange(location: third.location + third.length, length: 0)), [2])
        // From the middle of one paragraph to the middle of the next.
        let from = range(of: "to be here", in: l).location, to = range(of: "procurement", in: l).location
        XCTAssertEqual(l.segmentIndices(in: NSRange(location: from, length: to - from)), [2, 3])
        // A selection that ends exactly where the next paragraph starts does not take it.
        let start = range(of: "thanks for joining", in: l)
        XCTAssertEqual(l.segmentIndices(in: NSRange(location: start.location, length: start.length + 1)), [1])
        // Everything.
        XCTAssertEqual(l.segmentIndices(in: NSRange(location: 0, length: (l.text as NSString).length)), [0, 1, 2, 3, 4])
        XCTAssertEqual(l.segmentIndices(in: NSRange(location: NSNotFound, length: 0)), [])
        XCTAssertEqual(l.segmentIndices(in: NSRange(location: 99_999, length: 0)), [])
    }

    func testASpeakerHeaderMeansItsWholeTurn() {
        let l = TranscriptLayout(sample())
        let header = range(of: "SPEAKER_01", in: l)
        XCTAssertEqual(l.segmentIndices(in: NSRange(location: header.location + 3, length: 0)), [4])
        XCTAssertEqual(l.segmentIndices(in: NSRange(location: 2, length: 0)), [0, 1, 2, 3], "the first header: the whole first turn")
    }

    func testReassigningMovesOnlyThoseSegmentsAndKeepsTextAndTimings() {
        let t = sample()
        let out = TranscriptEditing.reassigning([2, 3, 3, 99, -1], to: " SPEAKER_02 ", in: t)
        XCTAssertEqual(out.segments.map(\.speaker), ["SPEAKER_00", "SPEAKER_00", "SPEAKER_02", "SPEAKER_02", "SPEAKER_01"])
        XCTAssertEqual(out.segments.map(\.text), t.segments.map(\.text))
        XCTAssertEqual(out.segments.map(\.start), t.segments.map(\.start))
        XCTAssertEqual(out.segments[2].words?.map(\.speaker), ["SPEAKER_02"])
        XCTAssertEqual(out.segments[2].words?.map(\.start), [4])
        XCTAssertEqual(out.segments[0], t.segments[0])
        XCTAssertEqual(TranscriptEditing.reassigning([2], to: "  ", in: t), t)
        XCTAssertEqual(TranscriptEditing.reassigning([4], to: "SPEAKER_01", in: t), t)
        // The viewer then shows a turn of its own for the moved part.
        let headers = TranscriptLayout(out).lines.compactMap { line -> String? in
            if case .header(let who, _) = line.kind { return who } else { return nil }
        }
        XCTAssertEqual(headers, ["SPEAKER_00", "SPEAKER_02", "SPEAKER_01"])
    }

    func testANewSpeakerGetsALabelNobodyHasOrHad() {
        XCTAssertEqual(TranscriptEditing.speakers(in: sample()), ["SPEAKER_00", "SPEAKER_01"])
        XCTAssertEqual(TranscriptEditing.newSpeakerLabel(in: sample()), "SPEAKER_02")
        // SPEAKER_04 was renamed to a name and no longer appears: its label is still taken.
        XCTAssertEqual(TranscriptEditing.newSpeakerLabel(in: sample(), alsoUsed: ["SPEAKER_04", "Anna Berg"]), "SPEAKER_05")
        let named = TranscriptSegments(segments: [.init(start: 0, end: 1, text: "a", speaker: "Anna Berg"), .init(start: 1, end: 2, text: "b")])
        XCTAssertEqual(TranscriptEditing.newSpeakerLabel(in: named), "SPEAKER_00")
        XCTAssertEqual(TranscriptEditing.newSpeakerLabel(in: named, alsoUsed: ["SPEAKER_00", "SPEAKER_x", "SPEAKER_"]), "SPEAKER_01")
        let many = TranscriptSegments(segments: [.init(start: 0, end: 1, text: "a", speaker: "SPEAKER_123")])
        XCTAssertEqual(TranscriptEditing.newSpeakerLabel(in: many), "SPEAKER_124")
    }

    /// The whole correction: split a speaker, save, then give the new speaker a name the ordinary way; the
    /// person gets a page for that meeting, and "Revert to original transcript" brings the single speaker back.
    func testSplitSaveRenameAndRevert() throws {
        let root = TestTemp.root.appendingPathComponent("distavo-reassign-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let base = "Meeting_2026-11-20_10.00.00"
        try sample().save(workDir: work, base: base)
        try Data((TranscriptEditing.renderClean(sample()) + "\n").utf8).write(to: Pipeline.cachedTranscriptURL(workDir: work, base: base))
        try "# Call\n\nSPEAKER_00 opened and SPEAKER_01 showed the numbers.\n".write(to: notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
        _ = try SpeakerRename.apply(mapping: ["SPEAKER_00": "Anna Berg"], base: base, notesDir: notes, workDir: work)

        let current = try XCTUnwrap(TranscriptSegments.load(workDir: work, base: base))
        let label = TranscriptEditing.newSpeakerLabel(in: current, alsoUsed: Set(SpeakerNames.load(workDir: work, base: base)?.names.keys.map { $0 } ?? []))
        XCTAssertEqual(label, "SPEAKER_02", "SPEAKER_00 is Anna's original label and stays hers")
        try TranscriptEditStore.save(TranscriptEditing.reassigning([2, 3], to: label, in: current), workDir: work, base: base)

        let clean = try String(contentsOf: Pipeline.cachedTranscriptURL(workDir: work, base: base), encoding: .utf8)
        XCTAssertTrue(clean.contains("SPEAKER_02"), clean)
        XCTAssertTrue(clean.contains("Anna Berg"), clean)
        _ = try SpeakerRename.apply(mapping: [label: "Pere Soler"], base: base, notesDir: notes, workDir: work)
        let after = try XCTUnwrap(TranscriptSegments.load(workDir: work, base: base))
        XCTAssertEqual(after.segments.map(\.speaker), ["Anna Berg", "Anna Berg", "Pere Soler", "Pere Soler", "SPEAKER_01"])

        let people = PeoplePages.collect(notesDir: notes, workDir: work, ownerName: "Dana Owner", timeZone: TimeZone(identifier: "Europe/London")!)
        XCTAssertEqual(people.map(\.name), ["Anna Berg", "Pere Soler"])

        try TranscriptEditStore.revert(workDir: work, base: base)
        let reverted = try XCTUnwrap(TranscriptSegments.load(workDir: work, base: base))
        XCTAssertEqual(reverted.segments.map(\.speaker), ["Anna Berg", "Anna Berg", "Anna Berg", "Anna Berg", "SPEAKER_01"])
    }

    // MARK: Review of 2026-11-23

    func testADragThatCrossesASpeakerLineTakesOnlyWhatItTouches() {
        let t = TranscriptSegments(segments: [
            .init(start: 0, end: 2, text: "first of anna", speaker: "SPEAKER_00"),
            .init(start: 2, end: 4, text: "second of anna", speaker: "SPEAKER_00"),
            .init(start: 4, end: 6, text: "first of pere", speaker: "SPEAKER_01"),
            .init(start: 6, end: 8, text: "second of pere", speaker: "SPEAKER_01"),
            .init(start: 8, end: 10, text: "third of pere", speaker: "SPEAKER_01"),
        ])
        let l = TranscriptLayout(t)
        let from = range(of: "of anna", in: l).location + 20   // inside "second of anna"
        let to = range(of: "first of pere", in: l).location + 5
        XCTAssertEqual(l.segmentIndices(in: NSRange(location: from, length: to - from)), [1, 2])
        // Starting ON the speaker line still means its whole turn.
        let header = range(of: "SPEAKER_01", in: l)
        XCTAssertEqual(l.segmentIndices(in: NSRange(location: header.location, length: 4)), [2, 3, 4])
        XCTAssertEqual(l.range(ofSegments: [3, 4]), NSRange(location: range(of: "second of pere", in: l).location,
                                                              length: NSMaxRange(range(of: "third of pere", in: l)) - range(of: "second of pere", in: l).location))
        XCTAssertNil(l.range(ofSegments: [99]))
    }

    /// A label that was in the transcript as first transcribed is never given to a new speaker, even when no
    /// segment carries it any more: Revert would hand the new speaker's name to that label's first owner.
    func testANewSpeakerNeverReusesALabelOfTheOriginalTranscript() throws {
        let root = TestTemp.root.appendingPathComponent("distavo-reassign2-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try sample().save(workDir: work, base: "d")
        try Data((TranscriptEditing.renderClean(sample()) + "\n").utf8).write(to: Pipeline.cachedTranscriptURL(workDir: work, base: "d"))
        XCTAssertEqual(TranscriptEditStore.takenLabels(workDir: work, base: "d"), [], "nothing edited or renamed yet")
        // SPEAKER_01's only part goes to SPEAKER_00: the label no longer appears in the transcript.
        try TranscriptEditStore.save(TranscriptEditing.reassigning([4], to: "SPEAKER_00", in: sample()), workDir: work, base: "d")
        let now = try XCTUnwrap(TranscriptSegments.load(workDir: work, base: "d"))
        XCTAssertEqual(TranscriptEditing.newSpeakerLabel(in: now), "SPEAKER_01", "the transcript alone would hand it out again")
        XCTAssertEqual(TranscriptEditing.newSpeakerLabel(in: now, alsoUsed: TranscriptEditStore.takenLabels(workDir: work, base: "d")), "SPEAKER_02")
    }

    /// A named speaker whose every part went to someone else no longer spoke in that meeting, and neither did
    /// a speaker made by a split once the transcript is reverted.
    func testASpeakerWithoutAnyPartLeftDidNotSpeak() throws {
        let root = TestTemp.root.appendingPathComponent("distavo-reassign3-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let base = "Meeting_2026-11-20_10.00.00"
        let zone = TimeZone(identifier: "Europe/London")!
        func people() -> [String] { PeoplePages.collect(notesDir: notes, workDir: work, timeZone: zone).map(\.name) }
        try sample().save(workDir: work, base: base)
        try Data((TranscriptEditing.renderClean(sample()) + "\n").utf8).write(to: Pipeline.cachedTranscriptURL(workDir: work, base: base))
        try "# Call\n".write(to: notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
        _ = try SpeakerRename.apply(mapping: ["SPEAKER_00": "Anna Berg", "SPEAKER_01": "Pere Soler"], base: base, notesDir: notes, workDir: work)
        XCTAssertEqual(people(), ["Anna Berg", "Pere Soler"])
        // Pere's only part was Anna's after all.
        var now = try XCTUnwrap(TranscriptSegments.load(workDir: work, base: base))
        try TranscriptEditStore.save(TranscriptEditing.reassigning([4], to: "Anna Berg", in: now), workDir: work, base: base)
        XCTAssertEqual(people(), ["Anna Berg"])
        XCTAssertEqual(SpeakerNames.load(workDir: work, base: base)?.names["SPEAKER_01"], "Pere Soler", "the mapping stays for Reset and Revert")
        try TranscriptEditStore.revert(workDir: work, base: base)
        XCTAssertEqual(people(), ["Anna Berg", "Pere Soler"])
        // A split, a name for the new speaker, then Revert: the new speaker is gone again.
        now = try XCTUnwrap(TranscriptSegments.load(workDir: work, base: base))
        let label = TranscriptEditing.newSpeakerLabel(in: now, alsoUsed: TranscriptEditStore.takenLabels(workDir: work, base: base))
        try TranscriptEditStore.save(TranscriptEditing.reassigning([2, 3], to: label, in: now), workDir: work, base: base)
        _ = try SpeakerRename.apply(mapping: [label: "Bo Lind"], base: base, notesDir: notes, workDir: work)
        XCTAssertEqual(people(), ["Anna Berg", "Bo Lind", "Pere Soler"])
        try TranscriptEditStore.revert(workDir: work, base: base)
        XCTAssertEqual(people(), ["Anna Berg", "Pere Soler"])
    }

    // MARK: What the pipeline wrote into the clean transcript survives a save

    /// The pipeline applies a replacement per turn, so "chat" + "GPT" in two segments reads "ChatGPT" in the
    /// clean transcript only. Moving another part, or fixing a word elsewhere, must not undo that.
    func testASaveKeepsTheTurnsItDidNotChangeAsThePipelineWroteThem() throws {
        let root = TestTemp.root.appendingPathComponent("distavo-reassign4-\(UUID().uuidString)")
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let t = TranscriptSegments(segments: [
            .init(start: 0, end: 2, text: "we tried chat", speaker: "SPEAKER_00"),
            .init(start: 2, end: 4, text: "GPT yesterday", speaker: "SPEAKER_00"),
            .init(start: 4, end: 6, text: "and it worked", speaker: "SPEAKER_01"),
            .init(start: 6, end: 8, text: "I disagree", speaker: "SPEAKER_01"),
            .init(start: 8, end: 10, text: "we tried chat", speaker: "SPEAKER_00"),
            .init(start: 10, end: 12, text: "GPT again", speaker: "SPEAKER_00"),
        ])
        let rules = [ReplacementRule(from: "chat GPT", to: "ChatGPT")]
        let asWritten = TranscriptCleaner.clean(t.segments.map { Segment(speaker: $0.speaker ?? "", text: $0.text, start: $0.start, end: $0.end) },
                                                replacements: rules)
        XCTAssertTrue(asWritten.contains("we tried ChatGPT yesterday"))
        try t.save(workDir: work, base: "c")
        let cleanURL = Pipeline.cachedTranscriptURL(workDir: work, base: "c")
        try Data((asWritten + "\n").utf8).write(to: cleanURL)
        func clean() throws -> String { try String(contentsOf: cleanURL, encoding: .utf8) }

        // A move in the middle turn: the first and the last turn are untouched.
        try TranscriptEditStore.save(TranscriptEditing.reassigning([3], to: "SPEAKER_02", in: t), workDir: work, base: "c")
        XCTAssertEqual(try clean(), "[SPEAKER_00]\nwe tried ChatGPT yesterday\n\n[SPEAKER_01]\nand it worked\n\n[SPEAKER_02]\nI disagree\n\n[SPEAKER_00]\nwe tried ChatGPT again\n")
        // A text edit in the last turn: only that turn is rendered from its segments.
        var now = try XCTUnwrap(TranscriptSegments.load(workDir: work, base: "c"))
        now.segments[5].text = "GPT once more"
        try TranscriptEditStore.save(now, workDir: work, base: "c")
        XCTAssertTrue(try clean().hasPrefix("[SPEAKER_00]\nwe tried ChatGPT yesterday\n\n"))
        XCTAssertTrue(try clean().hasSuffix("[SPEAKER_00]\nwe tried chat GPT once more\n"))
        // Revert brings back exactly what the pipeline wrote.
        try TranscriptEditStore.revert(workDir: work, base: "c")
        XCTAssertEqual(try clean(), asWritten + "\n")
    }

    func testTextTheTimedTranscriptNeverHadStaysInAnUntouchedTurn() {
        let t = sample()
        // The engine gave "first untimed words" no times: it is in the clean transcript only.
        let cached = "[SPEAKER_00]\nfirst untimed words good morning all thanks for joining happy to be here I run procurement\n\n[SPEAKER_01]\nover to the numbers\n"
        var edited = t
        edited.segments[4].text = "over to the figures"
        XCTAssertEqual(TranscriptEditing.renderClean(edited, previous: t, cachedClean: cached),
                       "[SPEAKER_00]\nfirst untimed words good morning all thanks for joining happy to be here I run procurement\n\n[SPEAKER_01]\nover to the figures")
        // Nothing to carry over: the plain render.
        XCTAssertEqual(TranscriptEditing.renderClean(edited, previous: t, cachedClean: TranscriptEditing.renderClean(t) + "\n"), TranscriptEditing.renderClean(edited))
        XCTAssertEqual(TranscriptEditing.renderClean(edited, previous: t, cachedClean: nil), TranscriptEditing.renderClean(edited))
        // The cached text does not belong to these segments (another speaker line, fewer turns): the plain render.
        XCTAssertEqual(TranscriptEditing.renderClean(edited, previous: t, cachedClean: cached.replacingOccurrences(of: "[SPEAKER_00]", with: "[Anna]")),
                       TranscriptEditing.renderClean(edited))
        XCTAssertEqual(TranscriptEditing.renderClean(edited, previous: t, cachedClean: "[SPEAKER_00]\nall of it\n"), TranscriptEditing.renderClean(edited))
    }

    /// A speaker whose only segment had no times is a whole turn of the clean transcript that the timed one
    /// lacks. It stays where it was through a save elsewhere.
    func testAWholeTurnTheTimedTranscriptNeverHadStaysInPlace() throws {
        let t = TranscriptSegments(segments: [
            .init(start: 0, end: 2, text: "good morning", speaker: "SPEAKER_00"),
            .init(start: 2, end: 4, text: "shall we start", speaker: "SPEAKER_00"),
            .init(start: 4, end: 6, text: "the numbers first", speaker: "SPEAKER_01"),
            .init(start: 6, end: 8, text: "then the plan", speaker: "SPEAKER_01"),
            .init(start: 8, end: 10, text: "agreed", speaker: "SPEAKER_00"),
        ])
        // SPEAKER_02 spoke twice without times: between the two halves of SPEAKER_00's opening, and at the end.
        let cached = ["[SPEAKER_02]\nbefore anyone", "[SPEAKER_00]\ngood morning", "[SPEAKER_02]\nhello all", "[SPEAKER_00]\nshall we start",
                      "[SPEAKER_01]\nthe numbers first then the plan", "[SPEAKER_00]\nagreed", "[SPEAKER_02]\nbye"]
        func saved(_ edited: TranscriptSegments) -> [String] {
            TranscriptEditing.renderClean(edited, previous: t, cachedClean: cached.joined(separator: "\n\n") + "\n").components(separatedBy: "\n\n")
        }
        // A word fixed in the last timed turn: everything else, the untimed turns included, is as it was.
        var word = t
        word.segments[4].text = "agreed then"
        XCTAssertEqual(saved(word), Array(cached[0...4]) + ["[SPEAKER_00]\nagreed then", "[SPEAKER_02]\nbye"])
        // A part of SPEAKER_01's turn moved to a new speaker: that turn is rendered anew, the rest is kept.
        XCTAssertEqual(saved(TranscriptEditing.reassigning([3], to: "SPEAKER_03", in: t)),
                       Array(cached[0...3]) + ["[SPEAKER_01]\nthe numbers first", "[SPEAKER_03]\nthen the plan", "[SPEAKER_00]\nagreed", "[SPEAKER_02]\nbye"])
        // The opening turn itself is changed: it is rendered from its segments (the untimed turn that cut it in
        // two goes with it); what stood before it and everything after it is kept.
        var opening = t
        opening.segments[0].text = "good morning everyone"
        XCTAssertEqual(saved(opening), ["[SPEAKER_02]\nbefore anyone", "[SPEAKER_00]\ngood morning everyone shall we start", "[SPEAKER_01]\nthe numbers first then the plan",
                                        "[SPEAKER_00]\nagreed", "[SPEAKER_02]\nbye"])
        // Through the store, and back with Revert.
        let root = TestTemp.root.appendingPathComponent("distavo-reassign5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try t.save(workDir: root, base: "u")
        let url = Pipeline.cachedTranscriptURL(workDir: root, base: "u")
        try Data((cached.joined(separator: "\n\n") + "\n").utf8).write(to: url)
        try TranscriptEditStore.save(word, workDir: root, base: "u")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("[SPEAKER_02]\nhello all\n\n[SPEAKER_00]\nshall we start"))
        // A second save starts from what the first one wrote.
        var again = try XCTUnwrap(TranscriptSegments.load(workDir: root, base: "u"))
        again.segments[2].text = "the figures first"
        try TranscriptEditStore.save(again, workDir: root, base: "u")
        let twice = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(twice, (Array(cached[0...3]) + ["[SPEAKER_01]\nthe figures first then the plan", "[SPEAKER_00]\nagreed then", "[SPEAKER_02]\nbye"]).joined(separator: "\n\n") + "\n")
        try TranscriptEditStore.revert(workDir: root, base: "u")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), cached.joined(separator: "\n\n") + "\n")
    }

    func testTheTurnsAreLinedUpInOrderAndIdenticalTextWins() {
        XCTAssertEqual(TranscriptEditing.aligned(["[A]\nx", "[B]\ny"], with: ["[A]\nx", "[B]\ny"]), [0...0, 1...1])
        XCTAssertEqual(TranscriptEditing.aligned(["[A]\nx", "[B]\ny"], with: ["[A]\nw", "[A]\nx", "[C]\nz", "[B]\ny"]), [1...1, 3...3])
        XCTAssertNil(TranscriptEditing.aligned(["[A]\nx", "[B]\ny"], with: ["[B]\ny", "[A]\nx", "[C]\nz"]))
        XCTAssertNil(TranscriptEditing.aligned(["[A]\nx", "[B]\ny"], with: ["[A]\nx"]))
        XCTAssertNil(TranscriptEditing.aligned([], with: ["[A]\nx"]))
    }

    /// Two turns that render alike but were written differently: each keeps its own text, by position.
    func testTurnsThatRenderAlikeButWereWrittenDifferentlyKeepTheirOwnText() {
        let t = TranscriptSegments(segments: [
            .init(start: 0, end: 1, text: "yes", speaker: "SPEAKER_00"), .init(start: 1, end: 2, text: "no", speaker: "SPEAKER_01"),
            .init(start: 2, end: 3, text: "yes", speaker: "SPEAKER_00"), .init(start: 3, end: 4, text: "maybe", speaker: "SPEAKER_01"),
        ])
        let cached = "[SPEAKER_00]\nyes indeed\n\n[SPEAKER_01]\nno\n\n[SPEAKER_00]\nyes\n\n[SPEAKER_01]\nmaybe so\n"
        var edited = t
        edited.segments[1].text = "never"
        XCTAssertEqual(TranscriptEditing.renderClean(edited, previous: t, cachedClean: cached),
                       "[SPEAKER_00]\nyes indeed\n\n[SPEAKER_01]\nnever\n\n[SPEAKER_00]\nyes\n\n[SPEAKER_01]\nmaybe so")
    }

    // MARK: third review: a save never loses a turn

    private func segs(_ parts: [(String, String)]) -> TranscriptSegments {
        TranscriptSegments(segments: parts.enumerated().map { .init(start: Double($0.offset), end: Double($0.offset) + 1, text: $0.element.1, speaker: $0.element.0) })
    }

    func testACachedTextThatCannotBeLinedUpForSureIsRenderedPlain() {
        // A rule emptied a whole turn: the cached text has a piece that is no turn.
        let t = segs([("A", "hello there"), ("B", "um"), ("A", "so the plan"), ("B", "chat"), ("B", "GPT yes"), ("A", "chat"), ("A", "GPT later")])
        var e = t
        e.segments[6].text = "GPT later on"
        let cached = "[A]\nhello there\n\n[B]\n\n\n[A]\nso the plan\n\n[B]\nChatGPT yes\n\n[A]\nChatGPT later\n"
        XCTAssertEqual(TranscriptEditing.renderClean(e, previous: t, cachedClean: cached), TranscriptEditing.renderClean(e))
        // A cached-only twin of a turn: two ways to line them up, so none is taken.
        let u = segs([("A", "plan one"), ("B", "yes"), ("A", "plan two")])
        var f = u
        f.segments[1].text = "yes sure"
        let twins = "[A]\nplan one\n\n[B]\nyes uh\n\n[A]\nplan two indeed\n\n[B]\nyes\n\n[A]\nbye\n"
        let out = TranscriptEditing.renderClean(f, previous: u, cachedClean: twins)
        XCTAssertEqual(out, TranscriptEditing.renderClean(f))
        XCTAssertNil(TranscriptEditing.aligned(["[B]\nyes", "[A]\nx"], with: ["[B]\nyes", "[C]\nz", "[B]\nyes", "[A]\nx"]))
    }

    func testASaveThatChangesNoTurnKeepsTheCachedTextWhateverItLooksLike() {
        let t = segs([("A", "hello there"), ("B", "um"), ("A", "so the plan")])
        let cached = "[A]\nhello there\n\n[B]\n\n\n[A]\nso the plan and more\n"
        XCTAssertEqual(TranscriptEditing.renderClean(t, previous: t, cachedClean: cached), cached.trimmingCharacters(in: .newlines))
        var timing = t
        timing.segments[1].end += 0.2   // a time, not a word
        XCTAssertEqual(TranscriptEditing.renderClean(timing, previous: t, cachedClean: cached), cached.trimmingCharacters(in: .newlines))
    }

    func testFilesOfTheSameShapeAreTakenTurnForTurnWhenTheLongTurnCutsAgree() {
        // The cached last turn has words without times at its end, the first a respelt first word.
        let t = segs([("A", "chat"), ("A", "GPT is here"), ("B", "fine"), ("A", "good bye")])
        var e = t
        e.segments[2].text = "fine then"
        XCTAssertEqual(TranscriptEditing.renderClean(e, previous: t, cachedClean: "[A]\nChatGPT is here\n\n[B]\nfine\n\n[A]\ngood bye and thanks to all of you\n"),
                       "[A]\nChatGPT is here\n\n[B]\nfine then\n\n[A]\ngood bye and thanks to all of you")
        XCTAssertNotNil(TranscriptEditing.aligned(["[A]\none two", "[A]\nthree four", "[B]\nx"], with: ["[A]\nOne, two", "[A]\nthree four", "[B]\ny and more"]))
        XCTAssertNil(TranscriptEditing.aligned(["[A]\nyes yes", "[A]\nyes yes yes", "[B]\nx"], with: ["[A]\nyes yes yes", "[A]\nyes yes", "[B]\nx"]),
                     "speech that repeats at a cut that moved")
        XCTAssertNil(TranscriptEditing.aligned(["[A]\none two", "[A]\nthree four", "[B]\nx"], with: ["[A]\none", "[A]\ntwo three four", "[B]\nx"]),
                     "the cut between A's two turns fell elsewhere")
    }

    /// A rule that shortens the text moves the 1,800-character cut, and the speech repeats on both sides of it.
    func testRepeatedSpeechAtAMovedCutLosesAndDoublesNothing() {
        let rules = [ReplacementRule(from: "zz", to: "z")]
        for lead in [4, 9, 16, 23, 31, 40] {
            var parts: [(String, String)] = (0..<2).map { ("SPEAKER_00", "pre\($0) " + String(repeating: "zz ", count: lead)) }
            parts += (0..<80).map { _ in ("SPEAKER_00", "Yes I agree with that.") }
            parts.append(("SPEAKER_01", "Thanks bye everyone"))
            let cached = TranscriptCleaner.clean(parts.map { Segment(speaker: $0.0, text: $0.1, start: 0, end: 1) }, replacements: rules) + "\n"
            let timed = segs(parts).applying(CompiledReplacements(rules))
            for at in [0, 40, 81] {
                var e = timed
                e.segments[at].text += " added"
                let out = TranscriptEditing.renderClean(e, previous: timed, cachedClean: cached)
                XCTAssertEqual(out.components(separatedBy: "agree").count - 1, 80, "lead \(lead), edit at \(at)")
                XCTAssertEqual(out.components(separatedBy: " added").count - 1, 1, "lead \(lead), edit at \(at)")
            }
        }
    }

    func testALongTurnCutAtAnotherPointInTheTwoFilesLosesNoSegment() {
        let body = String(repeating: "word ", count: 34)
        let parts = (0..<14).map { ("A", "tok\($0)start \(body)tok\($0)end") }
        let t = segs(parts)
        // The cached text had one untimed sentence after the second segment: its cut falls one segment earlier.
        var withUntimed = parts.map { Segment(speaker: $0.0, text: $0.1, start: 0, end: 1) }
        withUntimed.insert(Segment(speaker: "A", text: "untimed \(body)", start: nil, end: nil), at: 2)
        let cached = TranscriptCleaner.clean(withUntimed) + "\n"
        XCTAssertEqual(cached.components(separatedBy: "\n\n").count, TranscriptEditing.renderClean(t).components(separatedBy: "\n\n").count)
        var e = t
        e.segments[13].text = "tok13start changed tok13end"
        let out = TranscriptEditing.renderClean(e, previous: t, cachedClean: cached)
        for k in 0..<14 { XCTAssertEqual(out.components(separatedBy: "tok\(k)start").count - 1, 1, "segment \(k)") }
    }

    func testAnUntimedTurnNextToAChangedTurnStaysWhenTheSpeakersDidNotChange() {
        let t = segs([("A", "we tried chat"), ("A", "GPT today"), ("B", "fine")])
        var e = t
        e.segments[1].text = "GPT yesterday"
        XCTAssertEqual(TranscriptEditing.renderClean(e, previous: t, cachedClean: "[A]\nwe tried ChatGPT today\n\n[X]\nuntimed aside\n\n[B]\nfine\n"),
                       "[A]\nwe tried chat GPT yesterday\n\n[X]\nuntimed aside\n\n[B]\nfine")
    }

    func testAMoveThatJoinsTurnsLeavesOutWhatSatBetweenThem() {
        let t = segs([("C", "first"), ("A", "alpha"), ("B", "beta"), ("A", "gamma"), ("B", "delta chat"), ("B", "GPT")])
        let cached = "[C]\nfirst\n\n[X]\nbefore\n\n[A]\nalpha\n\n[X]\nuntimed between\n\n[B]\nbeta\n\n[A]\ngamma\n\n[X]\nafter\n\n[B]\ndelta ChatGPT\n"
        XCTAssertEqual(TranscriptEditing.renderClean(TranscriptEditing.reassigning([2], to: "A", in: t), previous: t, cachedClean: cached),
                       "[C]\nfirst\n\n[X]\nbefore\n\n[A]\nalpha beta gamma\n\n[X]\nafter\n\n[B]\ndelta ChatGPT")
    }

    /// Seeded random transcripts whose clean text has cached-only turns and per-turn rewrites: an edit of ONE
    /// segment never loses a cached turn that is not next to it, never duplicates one, and no edit at all gives
    /// the cached text back.
    func testRandomTranscriptsKeepEveryCachedTurnAwayFromTheEdit() {
        var seed: UInt64 = 0x5EED_2026_1123
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        for round in 0..<300 {
            let count = 2 + next(12)
            var segments: [TranscriptSegments.Segment] = [], speaker = 0
            for k in 0..<count {
                if next(3) == 0 { speaker = (speaker + 1 + next(2)) % 3 }
                segments.append(.init(start: Double(k) * 2, end: Double(k) * 2 + 1.5, text: "word\(round)x\(k) said", speaker: "SPEAKER_0\(speaker)"))
            }
            let t = TranscriptSegments(segments: segments)
            let rendered = TranscriptEditing.renderClean(t).components(separatedBy: "\n\n")
            // The cached text: some turns rewritten (a per-turn replacement), some cached-only turns in between.
            var cached: [String] = [], extras = 0
            for (n, turn) in rendered.enumerated() {
                if next(4) == 0 { cached.append("[SPEAKER_09]\nuntimed \(round)-\(n)"); extras += 1 }
                cached.append(next(3) == 0 ? turn.replacingOccurrences(of: " said", with: " SAID") : turn)
            }
            if next(4) == 0 { cached.append("[SPEAKER_09]\nuntimed \(round)-end"); extras += 1 }
            let cachedText = cached.joined(separator: "\n\n") + "\n"
            guard cached != rendered else { continue }
            XCTAssertEqual(TranscriptEditing.renderClean(t, previous: t, cachedClean: cachedText), cached.joined(separator: "\n\n"), "round \(round)")

            var edited = t
            let at = next(count)
            edited.segments[at].text = "CHANGED\(round)"
            let out = TranscriptEditing.renderClean(edited, previous: t, cachedClean: cachedText).components(separatedBy: "\n\n")
            XCTAssertEqual(Set(out).count, out.count, "round \(round): a turn twice")
            XCTAssertEqual(out.filter { $0.contains("CHANGED\(round)") }.count, 1, "round \(round)")
            // The changed segment's turn, by index among the rendered turns.
            var turnOf: [Int] = [], turn = -1, last: String?
            for seg in segments { if seg.speaker != last { turn += 1; last = seg.speaker }; turnOf.append(turn) }
            let changed = turnOf[at]
            // Every cached turn that is neither the changed turn nor a cached-only neighbour of it is still there, in order.
            var expected: [String] = [], r = 0
            for (n, c) in cached.enumerated() {
                if c.hasPrefix("[SPEAKER_09]") {
                    let nextIsChanged = r == changed, previousIsChanged = r - 1 == changed
                    if !nextIsChanged && !previousIsChanged { expected.append(c) }
                    _ = n
                } else {
                    if r != changed { expected.append(c) }
                    r += 1
                }
            }
            XCTAssertEqual(out.filter(expected.contains), expected, "round \(round)")
            // Every word of every segment is in the result.
            for (k, seg) in edited.segments.enumerated() where k != at {
                XCTAssertTrue(out.contains { $0.contains(seg.text.replacingOccurrences(of: " said", with: "")) }, "round \(round) segment \(k)")
            }
        }
    }
}
