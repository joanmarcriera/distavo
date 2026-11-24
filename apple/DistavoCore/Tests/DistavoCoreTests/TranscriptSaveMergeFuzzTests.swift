import XCTest
@testable import DistavoCore

/// A save of the transcript window never loses, doubles, reorders or re-attributes a timed segment, whatever
/// the cached clean transcript looks like (third review, 2026-11-23). Seeded property test that builds the cached clean transcript the way Pipeline does (untimed segments
/// included, replacements per turn after grouping) and the sidecar the way it does (timed only,
/// replacements per segment), then saves one random edit or move through the merge.
final class TranscriptSaveMergeFuzzTests: XCTestCase {
    typealias S = TranscriptSegments.Segment
    func occurrences(_ needle: String, _ hay: String) -> Int {
        // whole-token count
        hay.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "[]"))).filter { $0 == needle }.count
    }
    func testASaveKeepsEveryTimedSegmentOnceInOrderUnderItsSpeaker() {
        var seed: UInt64 = 0xD15_7A70
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        let fillers = ["padding", "chat", "GPT", "word", "yes", "ok"]
        let rules = [ReplacementRule(from: "padding", to: "pad"), ReplacementRule(from: "chat GPT", to: "ChatGPT"), ReplacementRule(from: "ok", to: "okay")]
        var failures: [String: Int] = [:], examples: [String: String] = [:], rounds = 0
        for round in 0..<1000 {
            let count = 3 + next(30)
            var raw: [S] = [], speaker = 0
            let long = next(2) == 0
            for k in 0..<count {
                if next(long ? 8 : 3) == 0 { speaker = (speaker + 1 + next(2)) % 3 }
                let n = long ? 20 + next(40) : 1 + next(4)
                let filler = (0..<n).map { _ in fillers[next(fillers.count)] }.joined(separator: " ")
                let untimed = next(10) == 0
                let who = untimed && next(2) == 0 ? "SPEAKER_0\((speaker + 1) % 3)" : "SPEAKER_0\(speaker)"
                let tok = untimed ? "u\(k)" : "t\(k)"
                raw.append(.init(start: untimed ? .nan : Double(k), end: untimed ? .nan : Double(k) + 0.5, text: "\(tok)s \(filler) \(tok)e", speaker: who))
            }
            let cached = TranscriptCleaner.clean(raw.map { Segment(speaker: $0.speaker ?? "", text: $0.text, start: $0.start, end: $0.end) }, replacements: rules)
            let timedRaw = raw.filter { !$0.start.isNaN }
            guard !timedRaw.isEmpty else { continue }
            let timed = TranscriptSegments(segments: timedRaw).applying(CompiledReplacements(rules))
            var edited = timed
            let at = next(timed.segments.count)
            let editedTok: String
            if next(2) == 0 {
                editedTok = "EDIT\(round)"
                edited.segments[at].text += " \(editedTok)"
            } else {
                editedTok = ""
                let len = 1 + next(3)
                let idx = Array(at..<min(timed.segments.count, at + len))
                edited = TranscriptEditing.reassigning(idx, to: "SPEAKER_0\(next(4))", in: timed)
                if edited == timed { continue }
            }
            rounds += 1
            let useFresh = ProcessInfo.processInfo.environment["FRESH"] != nil
            let hasUntimed = raw.contains { $0.start.isNaN }
            let out = useFresh ? TranscriptEditing.renderClean(edited) : TranscriptEditing.renderClean(edited, previous: timed, cachedClean: cached + "\n")
            if let d = ProcessInfo.processInfo.environment["DUMP"], d.split(separator: ",").contains(Substring(String(round))) {
                print("=== ROUND \(round) at \(at) editedTok=\(editedTok)")
                print("--- RAW"); for s in raw { print(s.start.isNaN ? "UNTIMED" : "timed", s.speaker ?? "", s.text) }
                print("--- CACHED\n\(cached)\n--- RENDERED\n\(TranscriptEditing.renderClean(timed))\n--- FRESH\n\(TranscriptEditing.renderClean(edited))\n--- OUT\n\(out)\n=== END")
            }
            func fail(_ kind: String) {
                failures[kind + (hasUntimed ? "/untimed" : "/rulesOnly") + (long ? "/long" : "/short"), default: 0] += 1
                if examples[kind + (hasUntimed ? "/untimed" : "/rulesOnly") + (long ? "/long" : "/short")] == nil { examples[kind + (hasUntimed ? "/untimed" : "/rulesOnly") + (long ? "/long" : "/short")] = "round \(round) at \(at)" }
            }
            for seg in timed.segments {
                let tok = String(seg.text.prefix { $0 != " " }.dropLast())   // "t<k>"
                let c = occurrences(tok + "s", out)
                if c == 0 { fail("timed segment lost") }
                if c > 1 { fail("timed segment duplicated") }
            }
            if !editedTok.isEmpty, occurrences(editedTok, out) != 1 { fail("edit not exactly once") }
            for seg in raw where seg.start.isNaN {
                let tok = String(seg.text.prefix { $0 != " " }.dropLast())
                if occurrences(tok + "s", out) > 1 { fail("untimed duplicated") }
            }
            // order of timed tokens
            let order = out.components(separatedBy: CharacterSet.whitespacesAndNewlines).compactMap { w -> Int? in
                guard w.hasPrefix("t"), w.hasSuffix("s"), let n = Int(w.dropFirst().dropLast()) else { return nil }; return n }
            if order != order.sorted() { fail("timed segments reordered") }
            // speaker of each timed segment
            for turn in out.components(separatedBy: "\n\n") {
                let header = String(turn.prefix { $0 != "\n" }).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                for w in turn.components(separatedBy: CharacterSet.whitespacesAndNewlines) where w.hasPrefix("t") && w.hasSuffix("s") {
                    if let n = Int(w.dropFirst().dropLast()), let s = edited.segments.first(where: { $0.text.hasPrefix("t\(n)s ") }), s.speaker != header { fail("timed segment under the wrong speaker") }
                }
            }
        }
        print("FUZZ rounds=\(rounds) failures=\(failures) examples=\(examples)")
        XCTAssertTrue(failures.isEmpty)
    }
}
