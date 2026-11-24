import XCTest
import CryptoKit
@testable import DistavoCore

/// The people and transcript operations on a COPY of real data. Runs only when `DISTAVO_TEST_HOME` points at
/// a test home (see `Config.homeDir`); never on the real folders. Prints counts only, never a name or a line
/// of anyone's notes: a failure is reported by index and by a short hash.
final class CopyDataLiveTests: XCTestCase {
    private let zone = TimeZone.current
    private func folders() throws -> (notes: URL, work: URL, owner: String) {
        let real = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard Config.homeDir.path != real else { throw XCTSkip("no DISTAVO_TEST_HOME") }
        let cfg = try Config.load(from: Config.defaultConfigURL)
        let notes = Config.resolvePath(cfg.notesDir), work = Config.resolvePath(cfg.workDir)
        XCTAssertTrue(notes.path.hasPrefix(Config.homeDir.path) && work.path.hasPrefix(Config.homeDir.path), "folders must be inside the test home")
        guard notes.path.hasPrefix(Config.homeDir.path), work.path.hasPrefix(Config.homeDir.path) else { throw XCTSkip("outside the test home") }
        return (notes, work, cfg.noteOwner)
    }
    private func tag(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined() }
    private func snapshot(_ dir: URL) -> [String: String] {
        var out: [String: String] = [:]
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            if let d = try? Data(contentsOf: f) { out[f.lastPathComponent] = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
        }
        return out
    }
    private func update(_ f: (notes: URL, work: URL, owner: String)) throws -> PeoplePages.Summary {
        try PeoplePages.update(notesDir: f.notes, workDir: f.work, ownerName: f.owner, glossary: NameGlossary.load(supportDir: NameGlossary.defaultSupportDir))
    }

    func test1PeoplePagesUpdateSettlesAndTouchesOnlyThePeopleFolder() throws {
        let f = try folders()
        let notesBefore = snapshot(f.notes)
        let first = try update(f)
        let after = snapshot(PeoplePages.folder(notesDir: f.notes))
        let second = try update(f)
        print("COPY people: created \(first.created.count) updated \(first.updated.count) unchanged \(first.unchanged) unreadable \(first.unreadable.count); second run created \(second.created.count) updated \(second.updated.count)")
        XCTAssertEqual(second.created.count, 0)
        XCTAssertEqual(second.updated.count, 0, "a second update must change nothing")
        XCTAssertEqual(snapshot(PeoplePages.folder(notesDir: f.notes)), after)
        XCTAssertEqual(snapshot(f.notes), notesBefore, "no note is touched by a people update")
        let known = PeoplePages.known(notesDir: f.notes)
        XCTAssertEqual(Set(known.map { $0.name.lowercased() }).count, known.count, "one page per name")
        for k in known { XCTAssertFalse(k.name.hasPrefix("_"), tag(k.name)) }
    }

    func test2EveryMergeComesApartToTheSameBytes() throws {
        let f = try folders()
        _ = try update(f)
        let folder = PeoplePages.folder(notesDir: f.notes)
        let names = PeoplePages.known(notesDir: f.notes).map(\.name)
        guard PeopleMerge.setAside(notesDir: f.notes).isEmpty else { throw XCTSkip("the copy already has merged pages") }
        let before = snapshot(folder)
        var done = 0, refused = 0, wrong = 0
        for i in names.indices {
            let other = names[i], keep = names[(i + 1) % names.count]
            guard other != keep else { continue }
            do {
                _ = try PeopleMerge.merge(other, into: keep, notesDir: f.notes)
                _ = try update(f)
                XCTAssertFalse(PeoplePages.known(notesDir: f.notes).contains { $0.name == other }, "pair \(i): the merged name is still a person")
                let out = try PeopleMerge.separate(other, notesDir: f.notes)
                XCTAssertFalse(out.textLeft, "pair \(i): text left behind")
                _ = try update(f)
                done += 1
            } catch { refused += 1 }
            let now = snapshot(folder)
            if now != before {
                wrong += 1
                let changed = Set(now.keys).symmetricDifference(before.keys).count + now.filter { before[$0.key] != nil && before[$0.key] != $0.value }.count
                XCTFail("pair \(i) (\(tag(other)) into \(tag(keep))): \(changed) files differ after merge + undo")
                break
            }
        }
        print("COPY merge: \(done) merged and undone, \(refused) refused, \(wrong) left a difference, of \(names.count) people")
    }

    func test3BriefAndAskFindEveryKnownPerson() throws {
        let f = try folders()
        _ = try update(f)
        let people = PeoplePages.collect(notesDir: f.notes, workDir: f.work, ownerName: f.owner, timeZone: zone)
        var noEntry = 0, askMissed = 0, askWrong = 0
        for (i, p) in people.enumerated() {
            let e = MeetingBrief.entries(for: [p.name], notesDir: f.notes, workDir: f.work, ownerName: f.owner, timeZone: zone)
            if e.first?.person?.name != p.name { noEntry += 1; XCTFail("person \(i) \(tag(p.name)): the brief does not find them by their own name") }
            let bases = AskPeople.bases(for: "What did \(p.name) say about the plan?", notesDir: f.notes, workDir: f.work, ownerName: f.owner, timeZone: zone)
            let theirs = Set(p.meetings.map(\.base))
            if bases.isEmpty { askMissed += 1 } else if !bases.isSubset(of: theirs) { askWrong += 1 }
        }
        print("COPY brief/ask: \(people.count) people, brief missed \(noEntry), ask found nobody for \(askMissed), ask gave other meetings for \(askWrong)")
        XCTAssertEqual(askWrong, 0)
        XCTAssertEqual(AskPeople.bases(for: "what was decided about the budget?", notesDir: f.notes, workDir: f.work, ownerName: f.owner, timeZone: zone), [],
                       "a question naming nobody")
    }

    func test4ATranscriptSaveKeepsEverythingAndRevertRestoresTheBytes() throws {
        let f = try folders()
        let entries = NotesLibrary.scan(notesDir: f.notes, workDir: f.work, timeZone: zone)
        var checked = 0, merged = 0, plain = 0, same = 0, sizeOff = 0, revertOff = 0
        for (i, e) in entries.enumerated() {
            let segURL = TranscriptSegments.url(workDir: f.work, base: e.base), cleanURL = Pipeline.cachedTranscriptURL(workDir: f.work, base: e.base)
            guard let t = TranscriptSegments.load(workDir: f.work, base: e.base), t.segments.count > 3,
                  let seg0 = try? Data(contentsOf: segURL), let clean0 = try? Data(contentsOf: cleanURL),
                  !TranscriptEditStore.isModified(workDir: f.work, base: e.base) else { continue }
            checked += 1
            let cached = String(decoding: clean0, as: UTF8.self)
            let rendered = TranscriptEditing.renderClean(t)
            if rendered + "\n" == cached { same += 1 }
            // No change at all: the cached text, or the plain render when the two cannot be lined up.
            let untouched = TranscriptEditing.renderClean(t, previous: t, cachedClean: cached)
            if untouched + "\n" == cached || untouched == cached.trimmingCharacters(in: .newlines) { merged += 1 } else {
                plain += 1
                XCTAssertEqual(untouched, rendered, "note \(i): neither the cached text nor the plain render")
            }
            // One word added in the middle, saved through the store.
            var edited = t
            let at = t.segments.count / 2
            edited.segments[at].text += " zqxmarker"
            try TranscriptEditStore.save(edited, workDir: f.work, base: e.base)
            let saved = try String(contentsOf: cleanURL, encoding: .utf8)
            XCTAssertEqual(saved.components(separatedBy: "zqxmarker").count - 1, 1, "note \(i): the edit is not there exactly once")
            let words = { (s: String) in s.split(whereSeparator: { $0.isWhitespace }).count }
            let lower = min(words(cached), words(rendered)), upper = max(words(cached), words(rendered)) + 1
            if words(saved) < lower || words(saved) > upper { sizeOff += 1; XCTFail("note \(i): \(words(saved)) words after the save, cached \(words(cached)), rendered \(words(rendered))") }
            // A move of two parts to a new speaker.
            let again = try XCTUnwrap(TranscriptSegments.load(workDir: f.work, base: e.base))
            let label = TranscriptEditing.newSpeakerLabel(in: again, alsoUsed: TranscriptEditStore.takenLabels(workDir: f.work, base: e.base))
            try TranscriptEditStore.save(TranscriptEditing.reassigning([at, at + 1], to: label, in: again), workDir: f.work, base: e.base)
            let moved = try String(contentsOf: cleanURL, encoding: .utf8)
            XCTAssertTrue(moved.contains("[\(label)]\n"), "note \(i): the new speaker has no turn")
            if words(moved) < lower || words(moved) > upper + 4 { sizeOff += 1; XCTFail("note \(i): \(words(moved)) words after the move, cached \(words(cached)), rendered \(words(rendered))") }
            try TranscriptEditStore.revert(workDir: f.work, base: e.base)
            if (try? Data(contentsOf: segURL)) != seg0 || (try? Data(contentsOf: cleanURL)) != clean0 { revertOff += 1; XCTFail("note \(i): revert did not restore the bytes") }
        }
        print("COPY transcripts: \(checked) checked; cached == render for \(same); kept from the cached text \(merged), plain render \(plain); word count off \(sizeOff); revert off \(revertOff)")
    }

    func test5NothingCrashesOnAnyNoteOrTranscript() throws {
        let f = try folders()
        let entries = NotesLibrary.scan(notesDir: f.notes, workDir: f.work, timeZone: zone)
        var intros = 0, said = 0, lines = 0
        for e in entries {
            if let t = TranscriptSegments.load(workDir: f.work, base: e.base) {
                intros += SelfIntroductions.bySpeaker(t.segments).count
                for s in Set(t.segments.compactMap(\.speaker)) where SelfIntroductions.said(by: s, in: t.segments) != nil { said += 1 }
            }
            if let h = SpeakerHints.load(workDir: f.work, base: e.base), let p = h.participants {
                lines += 1
                _ = SpeakerHints.joinedPeople(p)
                _ = PeoplePages.participants(p, alsoPresent: [], notesDir: f.notes)
            }
        }
        print("COPY scan: \(entries.count) notes, \(intros) introductions, \(said) stated roles, \(lines) participants lines")
    }
    func test6RenameASpeakerAndResetBringsEveryFileBack() throws {
        let f = try folders()
        var done = 0, off = 0, failed = 0
        for (i, e) in NotesLibrary.scan(notesDir: f.notes, workDir: f.work, timeZone: zone).enumerated() where !e.isVariant {
            guard SpeakerNames.load(workDir: f.work, base: e.base) == nil, !TranscriptEditStore.isModified(workDir: f.work, base: e.base),
                  let t = TranscriptSegments.load(workDir: f.work, base: e.base),
                  let label = t.segments.compactMap(\.speaker).first(where: { $0.hasPrefix("SPEAKER_") }) else { continue }
            let files = [e.notePath, TranscriptSegments.url(workDir: f.work, base: e.base), Pipeline.cachedTranscriptURL(workDir: f.work, base: e.base)]
            let before = files.map { try? Data(contentsOf: $0) }
            do {
                _ = try SpeakerRename.apply(mapping: [label: "Zq Tester"], base: e.base, notesDir: f.notes, workDir: f.work)
                XCTAssertTrue((try String(contentsOf: files[2], encoding: .utf8)).contains("[Zq Tester]"), "note \(i): the clean transcript does not carry the name")
                _ = try SpeakerRename.reset(base: e.base, notesDir: f.notes, workDir: f.work)
                done += 1
            } catch { failed += 1; continue }
            let after = files.map { try? Data(contentsOf: $0) }
            if after != before {
                off += 1
                let which = zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }.map { ["note", "segments", "clean"][$0.offset] }
                XCTFail("note \(i): after rename + reset these differ: \(which)")
            }
            if done >= 40 { break }
        }
        print("COPY rename: \(done) renamed and reset, \(failed) refused, \(off) not restored")
    }

    func test7TickingAnActionItemAndBackChangesNothing() throws {
        let f = try folders()
        var ticked = 0, off = 0
        let all = ActionItems.scan(notesDir: f.notes)
        for (i, note) in all.enumerated() {
            guard let item = note.items.first(where: { !$0.isDone }) else { continue }
            let url = URL(fileURLWithPath: item.notePath)
            let before = try Data(contentsOf: url)
            do {
                try ActionItems.toggle(item: item, to: true)
                XCTAssertNotEqual(try Data(contentsOf: url), before, "note \(i): the tick changed nothing")
                var back = item; back.isDone = true
                try ActionItems.toggle(item: back, to: false)
                ticked += 1
            } catch { XCTFail("note \(i): toggle threw \(type(of: error))") }
            if try Data(contentsOf: url) != before { off += 1; XCTFail("note \(i): tick + untick left a difference") }
        }
        print("COPY action items: \(all.count) notes with items, \(all.reduce(0) { $0 + $1.items.count }) items, \(ticked) ticked and unticked, \(off) left a difference")
    }

    func test8EveryTranscriptExportsInEveryFormat() throws {
        let f = try folders()
        var n = 0, empty = 0
        for e in NotesLibrary.scan(notesDir: f.notes, workDir: f.work, timeZone: zone) {
            guard let t = TranscriptSegments.load(workDir: f.work, base: e.base), !t.segments.isEmpty else { continue }
            n += 1
            let sizes = [SubtitleExport.srt(t).count, SubtitleExport.vtt(t).count, TranscriptDocument.html(t, title: "t").count, TranscriptDocument.docx(t, title: "t").count]
            if sizes.contains(where: { $0 < 20 }) || SubtitleExport.cues(t).isEmpty { empty += 1 }
        }
        print("COPY export: \(n) transcripts, \(empty) with an empty export")
        XCTAssertEqual(empty, 0)
    }

    func test9TheBriefIsWrittenAndIsNotAPerson() throws {
        let f = try folders()
        _ = try update(f)
        let names = PeoplePages.known(notesDir: f.notes).prefix(5).map(\.name)
        let url = try MeetingBrief.write(for: Array(names) + ["Nobody Known Zq"], notesDir: f.notes, workDir: f.work, ownerName: f.owner, timeZone: zone)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("_"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let second = try update(f)
        print("COPY brief: \(names.count) people asked, \(text.components(separatedBy: "\n## ").count - 1) sections, \(text.count) characters; update after it created \(second.created.count) updated \(second.updated.count)")
        XCTAssertEqual(second.created.count + second.updated.count, 0)
        XCTAssertFalse(PeoplePages.known(notesDir: f.notes).contains { $0.name.contains("Brief") })
        XCTAssertEqual(ActionItems.scan(notesDir: f.notes).filter { $0.items.contains { $0.notePath.contains("/people/") } }.count, 0, "people files hold no action items")
    }
}
