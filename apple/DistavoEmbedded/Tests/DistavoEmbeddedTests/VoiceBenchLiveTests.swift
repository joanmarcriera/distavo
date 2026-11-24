import XCTest
@testable import DistavoEmbedded
import DistavoCore

/// "Name Voices" on the owner's own past recordings, headless. Prints ONLY numbers (how many recordings,
/// speakers and voices, how many meetings each voice is in, similarity ranges): no name, no title, no
/// transcript text, so it is safe to run against private meetings. Nothing is written anywhere.
/// SKIPPED unless `DISTAVO_VOICE_BENCH=1`.
///
///   DISTAVO_VOICE_BENCH=1 DISTAVO_BENCH_RECORDINGS=... DISTAVO_BENCH_WORK=... DISTAVO_BENCH_NOTES=... \
///   swift test --filter VoiceBenchLiveTests
final class VoiceBenchLiveTests: XCTestCase {
    func testGroupVoicesOfPastRecordings() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["DISTAVO_VOICE_BENCH"] == "1", "set DISTAVO_VOICE_BENCH=1")
        let rec = URL(fileURLWithPath: try XCTUnwrap(env["DISTAVO_BENCH_RECORDINGS"]))
        let work = URL(fileURLWithPath: try XCTUnwrap(env["DISTAVO_BENCH_WORK"]))
        let notes = URL(fileURLWithPath: try XCTUnwrap(env["DISTAVO_BENCH_NOTES"]))
        var audio: [String: URL] = [:]
        let walker = FileManager.default.enumerator(at: rec, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            if ["wav", "m4a", "mp3", "mp4", "mov", "opus", "aac", "flac"].contains(url.pathExtension.lowercased()) {
                audio[DistavoState.baseFor(recordingsDir: rec, path: url)] = url
            }
        }
        let entries = NotesLibrary.scan(notesDir: notes, workDir: work).filter { !$0.isVariant }
        var occurrences: [VoiceReview.Occurrence] = []
        var scanned = 0, candidates = 0
        let start = Date()
        for e in entries {
            guard let source = audio[e.base],
                  let timed = TranscriptSegments.load(workDir: work, base: e.base) else { continue }
            let c = VoiceReview.candidates(in: timed)
            guard !c.isEmpty else { continue }
            scanned += 1; candidates += c.count
            let samples = await VoiceEmbedder.embeddings(
                audio: source, ranges: Dictionary(uniqueKeysWithValues: c.map { ($0.label, $0.ranges) }))
            for one in c {
                guard let e2 = samples[one.label] else { continue }
                occurrences.append(.init(base: e.base, label: one.label, title: "", date: e.date,
                                         sampleStart: one.sampleStart, sampleEnd: one.sampleEnd, quote: "", embedding: e2))
            }
        }
        print("BENCH notes \(entries.count), with audio and unnamed speakers \(scanned), speakers with enough speech \(candidates), embedded \(occurrences.count), seconds \(Int(Date().timeIntervalSince(start)))")
        for threshold in [Float(0.50), 0.60, 0.70] {
            let voices = VoiceReview.group(occurrences, store: VoiceProfileStore(model: VoiceProfileStore.builtInModel), threshold: threshold)
            print("BENCH threshold \(threshold): voices \(voices.count), meetings per voice \(voices.map(\.meetings))")
        }
        // How similar are speakers of the SAME meeting (certainly different people) and the best match across meetings?
        var same: [Float] = [], bestOther: [Float] = []
        for a in occurrences {
            var best: Float = -1
            for b in occurrences where a.id != b.id {
                let s = VoiceProfileStore.cosine(a.embedding, b.embedding)
                if a.base == b.base { if a.id < b.id { same.append(s) } } else { best = max(best, s) }
            }
            if best > -1 { bestOther.append(best) }
        }
        func line(_ v: [Float]) -> String { v.sorted().map { String(format: "%.2f", $0) }.joined(separator: " ") }
        print("BENCH different people (same meeting): \(line(same))")
        print("BENCH best match in another meeting, per speaker: \(line(bestOther))")
        XCTAssertFalse(occurrences.isEmpty, "no speaker could be embedded")
    }
}
