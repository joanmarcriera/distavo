import XCTest
import AVFoundation
import Darwin
@testable import DistavoCore

/// Long recordings in bounded parts (Vikunja #6759): planning and stitching (pure), then a real synthetic
/// 5 h 20 min recording through `Pipeline.processOne` with the live converter and splitter and a fake engine
/// that refuses any input longer than a part, plus resume, a failing part, the long-transcript summary and the
/// crash-loop guard.
final class LongRecordingTests: XCTestCase {

    // MARK: Planning

    /// Loud everywhere except one quiet second per minute at :37, plus the given silent span.
    private func rms(seconds: Int, silent: Range<Int> = 0..<0) -> [Float] {
        (0..<seconds).map { s in silent.contains(s) || s % 60 == 37 ? 0.0001 : 0.1 }
    }

    func testShortRecordingNeedsNoParts() {
        XCTAssertEqual(LongRecording.plan(windowRMS: rms(seconds: 5400), duration: 5400), [])
        XCTAssertEqual(LongRecording.plan(windowRMS: rms(seconds: 3600), duration: 3600), [])
    }

    func testPartsAreContiguousBoundedAndCutAtTheQuietestSecond() {
        let duration = 5 * 3600 + 20 * 60
        let parts = LongRecording.plan(windowRMS: rms(seconds: duration), duration: Double(duration))
        XCTAssertEqual(parts.count, 11)
        XCTAssertEqual(parts.first?.start, 0)
        XCTAssertEqual(parts.last?.end, Double(duration))
        for (a, b) in zip(parts, parts.dropFirst()) { XCTAssertEqual(a.end, b.start) }
        for p in parts {
            XCTAssertLessThanOrEqual(p.duration, LongRecording.maxPartSeconds, "part \(p.index)")
            XCTAssertFalse(p.isSilent)
        }
        // Every cut is on a quiet second (:37 of some minute), within a minute of its nominal boundary.
        for p in parts.dropLast() { XCTAssertEqual(Int(p.end) % 60, 37, "cut at \(p.end)") }
        XCTAssertEqual(parts[0].end, 1777)   // 29:37, the quiet second nearest 30:00
    }

    func testSilentSpanIsFlaggedAndShortTailJoinsThePreviousPart() {
        // Cuts at 29:37, 58:37, 1:27:37, 1:56:37, 2:25:37; a remainder of 32.5 min stays one part (a separate
        // part of under 5 min would follow otherwise).
        let duration = 8737 + 1950
        let parts = LongRecording.plan(windowRMS: rms(seconds: duration, silent: 3500..<7300), duration: Double(duration))
        XCTAssertEqual(parts.map(\.end), [1777, 3517, 5257, 6997, 8737, Double(duration)])
        XCTAssertGreaterThan(parts.last!.duration, LongRecording.partSeconds)
        XCTAssertEqual(parts.filter(\.isSilent).map(\.index), [2, 3])
    }

    // MARK: Stitching

    func testStitchShiftsTimesRenumbersSpeakersAndMergesDetections() {
        let p0 = LongRecording.Part(index: 0, start: 0, end: 1800, isSilent: false)
        let p1 = LongRecording.Part(index: 1, start: 1800, end: 3600, isSilent: true)
        let p2 = LongRecording.Part(index: 2, start: 3600, end: 5400, isSilent: false)
        let r0: [String: Any] = [
            "segments": [["text": "hello", "start": 1.0, "end": 11.0, "speaker": "SPEAKER_01",
                          "words": [["word": "hello", "start": 1.0, "end": 1.5, "speaker": "SPEAKER_01"]]],
                         ["text": "hi", "start": 12.0, "end": 13.0, "speaker": "SPEAKER_00"]],
            "engine": "Parakeet", "detections": [["code": "en", "probability": 0.9]],
            "footer_notes": ["recovered speech"]]
        let r2: [String: Any] = [
            "segments": [["text": "later", "start": 5.0, "end": 6.0, "speaker": "SPEAKER_00"]],
            "engine": "Parakeet", "detections": [["code": "ca", "probability": 0.8]],
            "footer_notes": ["recovered speech"], "language": "en"]
        let out = LongRecording.stitch([.init(part: p0, result: r0), .init(part: p1, result: nil),
                                        .init(part: p2, result: r2)])
        let segs = out["segments"] as! [[String: Any]]
        XCTAssertEqual(segs.map { $0["text"] as! String }, ["hello", "hi", "later"])
        XCTAssertEqual(segs[0]["speaker"] as? String, "SPEAKER_00", "the part's main talker is renumbered first")
        XCTAssertEqual(segs[1]["speaker"] as? String, "SPEAKER_01")
        XCTAssertEqual(segs[2]["start"] as? Double, 3605)
        XCTAssertEqual((segs[0]["words"] as! [[String: Any]])[0]["end"] as? Double, 1.5)
        XCTAssertEqual((segs[0]["words"] as! [[String: Any]])[0]["speaker"] as? String, "SPEAKER_00", "word labels follow")
        XCTAssertEqual(out["engine"] as? String, "Parakeet")
        XCTAssertEqual(out["language"] as? String, "en", "unknown keys come from the first part that has them")
        let det = out["detections"] as! [[String: Any]]
        XCTAssertEqual(det.first?["code"] as? String, "en", "weighted by each part's speech: 11 s of en vs 1 s of ca")
        let notes = out["footer_notes"] as! [String]
        XCTAssertEqual(notes, ["recovered speech"], "engine notes deduplicated")
        let own = out[LongRecording.notesKey] as! [String]
        XCTAssertTrue(own[0].contains("3 parts"), own[0])
        XCTAssertTrue(own[0].contains("1 silent, skipped"), own[0])
    }

    func testStitchNamesAMissingPart() {
        let p0 = LongRecording.Part(index: 0, start: 0, end: 1800, isSilent: false)
        let p1 = LongRecording.Part(index: 1, start: 1800, end: 3600, isSilent: false)
        let out = LongRecording.stitch([.init(part: p0, result: ["segments": [["text": "a", "start": 0.0, "end": 1.0]]]),
                                        .init(part: p1, result: nil, failure: "engine broke")])
        let notes = out[LongRecording.notesKey] as! [String]
        XCTAssertTrue(notes.contains { $0.hasPrefix("Part 2 (0:30:00-1:00:00) could not be transcribed") && $0.hasSuffix("engine broke") },
                      notes.description)
    }

    // MARK: A real 5 h 20 min file through the pipeline

    private struct Fixture {
        let root: URL, recordings: URL, notes: URL, work: URL
        var config: Config
        var source: URL
    }

    /// Mono 8 kHz Int16 WAV: speech-like tone 50 s of every minute, with `silent` (in seconds) all silent.
    private static func writeSyntheticRecording(to url: URL, seconds: Int, silent: Range<Int>, rate: Double = 8000) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
        buffer.frameLength = AVAudioFrameCount(rate)
        let tone = buffer.int16ChannelData![0]
        var toneSecond = [Int16](repeating: 0, count: Int(rate))
        for i in 0..<Int(rate) { toneSecond[i] = Int16(6000 * sin(2 * Double.pi * 220 * Double(i) / rate)) }
        for s in 0..<seconds {
            let loud = !silent.contains(s) && s % 60 < 50
            if loud { toneSecond.withUnsafeBufferPointer { tone.update(from: $0.baseAddress!, count: Int(rate)) } }
            else { tone.update(repeating: 0, count: Int(rate)) }
            try file.write(from: buffer)
        }
    }

    /// One 95-minute work WAV (16 kHz mono Int16, the converter's output format), written once and copied in
    /// by `copyConverter`: the tests of resume, failures and language only need a long work WAV, and the live
    /// converter is already proven by the 5 h test.
    /// Outside `TestTemp.root` (cleaned after every test); removed by `tearDown()` of the class.
    private static let fixtureDir = TestTemp.base
        .appendingPathComponent("distavo-long-fixture-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    private static let workWav95: URL = {
        let url = fixtureDir.appendingPathComponent("work95.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
            try! writeSyntheticRecording(to: url, seconds: 95 * 60, silent: 0..<0, rate: 16000)
        }
        return url
    }()

    override class func tearDown() {
        try? FileManager.default.removeItem(at: fixtureDir)
        super.tearDown()
    }

    private static let copyConverter: (URL, URL) async throws -> Void = { _, dest in
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: workWav95, to: dest)
    }

    /// A 95-minute recording whose conversion is the copy of `workWav95` (the source is a stand-in file).
    private func makeFixture95(name: String) throws -> Fixture {
        let root = TestTemp.root.appendingPathComponent("distavo-long-" + UUID().uuidString)
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        cfg.summarise.backend = "local"
        let source = rec.appendingPathComponent(name)
        try Data([0, 1, 2, 3]).write(to: source)
        return Fixture(root: root, recordings: rec, notes: URL(fileURLWithPath: cfg.notesDir),
                       work: URL(fileURLWithPath: cfg.workDir), config: cfg, source: source)
    }

    private func makeFixture(name: String, seconds: Int, silent: Range<Int>) throws -> Fixture {
        let root = TestTemp.root.appendingPathComponent("distavo-long-" + UUID().uuidString)
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        cfg.summarise.backend = "local"
        let source = rec.appendingPathComponent(name)
        try Self.writeSyntheticRecording(to: source, seconds: seconds, silent: silent)
        return Fixture(root: root, recordings: rec, notes: URL(fileURLWithPath: cfg.notesDir),
                       work: URL(fileURLWithPath: cfg.workDir), config: cfg, source: source)
    }

    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Thread-safe log of what the fake engine was handed.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(name: String, seconds: Double)] = []
        private var langs: [String] = []
        func add(_ name: String, _ seconds: Double) { lock.lock(); items.append((name, seconds)); lock.unlock() }
        func addLanguage(_ l: String) { lock.lock(); langs.append(l); lock.unlock() }
        var languages: [String] { lock.lock(); defer { lock.unlock() }; return langs }
        var all: [(name: String, seconds: Double)] { lock.lock(); defer { lock.unlock() }; return items }
    }

    /// The fake engine: refuses anything longer than a part (as the real engines should never see), returns one
    /// segment per part saying which part it heard, with the labels the other way round on odd parts.
    private func fakeEngine(_ calls: Calls, failOn: Set<Int> = [], retryOn: Set<Int> = [],
                            serverDownOn: Set<Int> = [], engineName: String? = "Fake")
        -> (URL, TranscribeConfig) async throws -> [String: Any] {
        { url, config in
            calls.addLanguage(config.language)
            let file = try AVAudioFile(forReading: url)
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            calls.add(url.lastPathComponent, seconds)
            guard seconds <= LongRecording.maxPartSeconds else {
                throw NSError(domain: "fake-engine", code: 1, userInfo: [NSLocalizedDescriptionKey: "input of \(Int(seconds)) s is too long"])
            }
            let n = calls.all.count
            if retryOn.contains(n) { throw RetryableDependencyError("model still downloading") }
            if failOn.contains(n) { throw NSError(domain: "fake-engine", code: 2, userInfo: [NSLocalizedDescriptionKey: "engine broke"]) }
            if serverDownOn.contains(n) { throw WhisperXError("WhisperX server unreachable") }
            let (owner, other) = n % 2 == 0 ? ("SPEAKER_01", "SPEAKER_00") : ("SPEAKER_00", "SPEAKER_01")
            var out: [String: Any] = ["segments": [
                ["text": "Heard \(url.lastPathComponent) for \(Int(seconds)) seconds.", "start": 1.0, "end": 40.0, "speaker": owner],
                ["text": "Yes.", "start": 41.0, "end": 42.0, "speaker": other]]]
            if let engineName { out["engine"] = engineName }
            return out
        }
    }

    private func deps(_ engine: @escaping (URL, TranscribeConfig) async throws -> [String: Any],
                      summarise: @escaping (String, SummariseTarget, SummariseOptions, NoteContext) async throws -> String
                        = { _, _, _, _ in LongRecordingTests.noteText },
                      liveConverter: Bool = false) -> PipelineDeps {
        PipelineDeps(convertToWav: liveConverter ? { try await AudioConverter.convertToWav(source: $0, dest: $1) }
                                                 : LongRecordingTests.copyConverter,
                     transcribe: engine, ollamaReachable: { _ in true }, summarise: summarise)
    }

    /// A summary the validator accepts: a section heading and enough varied words.
    static let noteText = """
        # Meeting notes

        ## Executive summary
        The team reviewed the migration plan for the storage cluster, agreed the order of the three cut-overs, \
        and named owners for the rollback runbook, the capacity report and the vendor call next Tuesday.

        ## Decisions
        - Migrate the archive tier first because its users tolerate a short outage on a weekend morning.
        - Keep the old array powered for two weeks after the final cut-over as a safety net.
        """

    func testFiveHourTwentyMinuteRecordingIsTranscribedInBoundedPartsAndGetsANote() async throws {
        let seconds = 5 * 3600 + 20 * 60
        // 2:00-3:40 is a forgotten-recorder silence: those parts are skipped without an engine run.
        let fx = try makeFixture(name: "Meeting 2026-11-10 15.30.02.wav", seconds: seconds, silent: 7200..<13200)
        defer { try? FileManager.default.removeItem(at: fx.root) }
        let calls = Calls()
        let before = footprintMB()
        let started = Date()
        let result = await Pipeline.processOne(path: fx.source, config: fx.config, deps: deps(fakeEngine(calls), liveConverter: true),
                                               stableChecks: 1, stableDelay: 0)
        let after = footprintMB()
        print("LONG-RECORDING: \(seconds) s of audio in \(Int(Date().timeIntervalSince(started))) s, "
              + "footprint \(Int(before)) -> \(Int(after)) MB, engine calls \(calls.all.count)")

        XCTAssertEqual(result.status, .done, result.message ?? "")
        // 11 parts; parts 6 and 7 (2:25:50-2:54:50 and 2:54:50-3:23:50) are silent and never reach the engine.
        XCTAssertEqual(calls.all.count, 9, calls.all.map(\.name).description)
        XCTAssertFalse(calls.all.contains { $0.name.hasSuffix("part-06.wav") || $0.name.hasSuffix("part-07.wav") })
        for call in calls.all {
            XCTAssertLessThanOrEqual(call.seconds, LongRecording.maxPartSeconds, call.name)
        }
        let transcript = try String(contentsOf: XCTUnwrap(result.transcriptPath), encoding: .utf8)
        XCTAssertTrue(transcript.contains("part-01.wav"), "first part reached the transcript")
        XCTAssertTrue(transcript.contains("part-11.wav"), "last part reached the transcript")
        let segments = try XCTUnwrap(TranscriptSegments.load(workDir: fx.work, base: result.base))
        // Part 11 starts at 4:50:50; its fake segments sit 1 s and 41 s into the part.
        XCTAssertEqual(segments.segments.last?.start ?? 0, 17_450 + 41, accuracy: 2, "timestamps are absolute (cut within a second of 4:50:50)")
        let note = try String(contentsOf: XCTUnwrap(result.notePath), encoding: .utf8)
        XCTAssertTrue(note.contains("transcribed in 11 parts"), note)
        // The part WAVs never outlive their part, and the caches go with the note.
        let left = try FileManager.default.contentsOfDirectory(atPath: fx.work.path).filter { $0.contains(".part-") }
        XCTAssertEqual(left, [])
        // Bounded memory: the pipeline never holds the 5 h of audio (300 M samples, > 1 GB as Float32).
        XCTAssertLessThan(after - before, 400, "footprint grew \(Int(after - before)) MB")
    }

    func testDeferredRunResumesFromThePartsAlreadyDone() async throws {
        let fx = try makeFixture95(name: "resume.wav")
        defer { try? FileManager.default.removeItem(at: fx.root) }
        let first = Calls()
        let r1 = await Pipeline.processOne(path: fx.source, config: fx.config, deps: deps(fakeEngine(first, retryOn: [3])),
                                           stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r1.status, .deferred, r1.message ?? "")
        XCTAssertEqual(first.all.count, 3)
        // Retry now (as Process now does), with the engine back.
        let state = try DistavoState.Store(stateDir: fx.work.appendingPathComponent(".state"), notesDir: fx.notes)
        state.retryFailed()
        let second = Calls()
        let r2 = await Pipeline.processOne(path: fx.source, config: fx.config, deps: deps(fakeEngine(second)),
                                           stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r2.status, .done, r2.message ?? "")
        XCTAssertEqual(second.all.map(\.name), ["resume.part-03.wav", "resume.part-04.wav"],
                       "parts 1 and 2 came from the cache")
    }

    func testOneFailingPartStillGivesANoteThatSaysWhatIsMissing() async throws {
        let fx = try makeFixture95(name: "onefails.wav")
        defer { try? FileManager.default.removeItem(at: fx.root) }
        let calls = Calls()
        let r = await Pipeline.processOne(path: fx.source, config: fx.config, deps: deps(fakeEngine(calls, failOn: [2])),
                                          stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message ?? "")
        let note = try String(contentsOf: XCTUnwrap(r.notePath), encoding: .utf8)
        XCTAssertTrue(note.contains("Part 2 ("), note)
        XCTAssertTrue(note.contains("engine broke"), note)
    }

    func testEveryPartFailingFailsTheRecordingWithTheEngineError() async throws {
        let fx = try makeFixture95(name: "allfail.wav")
        defer { try? FileManager.default.removeItem(at: fx.root) }
        let calls = Calls()
        let r = await Pipeline.processOne(path: fx.source, config: fx.config,
                                          deps: deps(fakeEngine(calls, failOn: [1, 2, 3, 4])), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .failed)
        XCTAssertTrue((r.message ?? "").contains("engine broke"), r.message ?? "")
    }

    func testTheOwnersConfirmedLanguageReachesEveryPart() async throws {
        var fx = try makeFixture95(name: "catalan.wav")
        defer { try? FileManager.default.removeItem(at: fx.root) }
        fx.config.transcribe.language = "auto"
        try LanguageOverride(code: "ca").save(workDir: fx.work, base: "catalan")
        let calls = Calls()
        let r = await Pipeline.processOne(path: fx.source, config: fx.config, deps: deps(fakeEngine(calls)),
                                          stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message ?? "")
        XCTAssertEqual(calls.languages, ["ca", "ca", "ca", "ca"])
    }

    func testAServerFailureMidwayFailsLikeAWholeFileRunAndKeepsThePartsForTheRetry() async throws {
        let fx = try makeFixture95(name: "server.wav")
        defer { try? FileManager.default.removeItem(at: fx.root) }
        let calls = Calls()
        let r = await Pipeline.processOne(path: fx.source, config: fx.config,
                                          deps: deps(fakeEngine(calls, serverDownOn: [2], engineName: nil)),
                                          stableChecks: 1, stableDelay: 0)
        XCTAssertNotEqual(r.status, .done, "never a note with a hole the size of an outage")
        XCTAssertEqual(calls.all.count, 2, "stopped at the failing part")
        let cached = try FileManager.default.contentsOfDirectory(atPath: fx.work.path).filter { $0.hasSuffix(".json") && $0.contains(".part-") }
        XCTAssertEqual(cached, ["server.part-01.json"])
    }

    func testPartNotesReachTheNoteWhenTheEngineDoesNotNameItself() async throws {
        let fx = try makeFixture95(name: "noengine.wav")
        defer { try? FileManager.default.removeItem(at: fx.root) }
        let r = await Pipeline.processOne(path: fx.source, config: fx.config,
                                          deps: deps(fakeEngine(Calls(), failOn: [3], engineName: nil)),
                                          stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message ?? "")
        let note = try String(contentsOf: XCTUnwrap(r.notePath), encoding: .utf8)
        XCTAssertTrue(note.contains("transcribed in 4 parts"), note)
        XCTAssertTrue(note.contains("Part 3 ("), note)
    }

    func testCachedPartsAreNotReusedAfterATranscriptionSettingChange() throws {
        let root = TestTemp.root.appendingPathComponent("distavo-cachekey-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wav = root.appendingPathComponent("x.wav")
        try Data([1, 2, 3]).write(to: wav)
        let part = LongRecording.Part(index: 0, start: 0, end: 1800, isSilent: false)
        var cfg = TranscribeConfig()
        let key = LongRecording.WavKey(wav, config: cfg)
        LongRecording.saveCache(["segments": []], workDir: root, base: "x", part: part, key: key)
        XCTAssertNotNil(LongRecording.loadCache(workDir: root, base: "x", part: part, key: key))
        cfg.embeddedModel = "something-else"
        XCTAssertNil(LongRecording.loadCache(workDir: root, base: "x", part: part, key: LongRecording.WavKey(wav, config: cfg)))
    }

    // MARK: Long transcript, Ollama context

    func testTranscriptLongerThanTheContextIsSummarisedInPartsThenMerged() async throws {
        let root = TestTemp.root.appendingPathComponent("distavo-longsum-" + UUID().uuidString)
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        cfg.summarise.backend = "local"
        cfg.summarise.options.numCtx = 8192
        cfg.summarise.options.numPredict = 1024
        let input = rec.appendingPathComponent("long-talk.opus")
        try Data([0, 1, 2, 3]).write(to: input)
        // About 60k characters of talk (20k tokens estimated): far over an 8k context.
        var segments: [[String: Any]] = []
        for i in 0..<1000 {
            let speaker = i % 2 == 0 ? "SPEAKER_00" : "SPEAKER_01"
            let start = Double(i) * 6
            let text = "Line \(i) of the long meeting about the migration plan and its budget."
            segments.append(["speaker": speaker, "start": start, "end": start + 5, "text": text])
        }
        let inputs = Calls()
        let d = PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in ["segments": segments] },
            ollamaReachable: { _ in true },
            summarise: { transcript, _, _, context in
                inputs.add(transcript, Double(EmbeddedSummaryTokens.estimate(context.prompt(transcript: transcript))))
                return LongRecordingTests.noteText
            },
            audioDurationSeconds: { _ in 6000 })
        let r = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message ?? "")
        XCTAssertGreaterThanOrEqual(inputs.all.count, 4, "several parts plus the merge")
        for call in inputs.all {
            XCTAssertLessThanOrEqual(Int(call.seconds) + cfg.summarise.options.numPredict, cfg.summarise.options.numCtx,
                                     "every prompt fits the context")
        }
        XCTAssertTrue(inputs.all.last!.name.contains("archive tier"), "the last call merges the part notes")
        XCTAssertFalse(inputs.all.last!.name.contains("Line 0 of"), "the merge input is the part notes, not the transcript")
        let note = try String(contentsOf: XCTUnwrap(r.notePath), encoding: .utf8)
        XCTAssertTrue(note.contains("summarised in"), note)
    }

    func testShortTranscriptStillGoesInOnePass() {
        let context = NoteContext(noteOwner: "", userSpeaker: "SPEAKER_00")
        XCTAssertNil(Pipeline.longTranscriptParts("A short meeting.", target: .ollama(url: "u", model: "m"),
                                                  options: SummariseOptions(), context: context))
        let long = String(repeating: "word ", count: 200_000)
        XCTAssertNil(Pipeline.longTranscriptParts(long, target: .embedded(model: "apple"),
                                                  options: SummariseOptions(), context: context),
                     "on-device engines plan their own chunks")
        XCTAssertNotNil(Pipeline.longTranscriptParts(long, target: .ollama(url: "u", model: "m"),
                                                     options: SummariseOptions(), context: context))
    }

    // MARK: Crash-loop guard

    func testRecordingInterruptedByACrashIsSetAsideAtLaunchNotRetried() throws {
        let root = TestTemp.root.appendingPathComponent("distavo-crash-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        let notes = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let state = try DistavoState.Store(stateDir: root.appendingPathComponent("work/.state"), notesDir: notes)
        let file = rec.appendingPathComponent("big.wav")
        try Data([1]).write(to: file)
        state.markProcessing("big")                                   // the app died here
        state.markProcessing("finished"); state.markDone("finished")
        try "# note".write(to: notes.appendingPathComponent("finished.md"), atomically: true, encoding: .utf8)

        XCTAssertEqual(state.setAsideInterrupted(), ["big"])
        XCTAssertTrue(state.isFailed("big"))
        XCTAssertEqual(state.failedBases().first?.error, DistavoState.Store.interruptedReason)
        XCTAssertFalse(state.isProcessing("big"))
        XCTAssertEqual(DistavoState.iterPending(recordingsDir: rec, state: state), [], "not picked up again")
        XCTAssertEqual(state.setAsideInterrupted(), [], "a second launch has nothing new to say")

        state.retryFailed()                                            // Process now
        XCTAssertEqual(DistavoState.iterPending(recordingsDir: rec, state: state).map(\.lastPathComponent), ["big.wav"])
    }

    func testAnotherRunningDistavoKeepsItsFile() throws {
        let root = TestTemp.root.appendingPathComponent("distavo-owner-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try DistavoState.Store(stateDir: root.appendingPathComponent(".state"),
                                           notesDir: root.appendingPathComponent("notes"))
        state.markProcessing("theirs", pid: 4242)
        state.markProcessing("crashed", pid: 4343)
        let set = state.setAsideInterrupted(ownPID: 1, isAlive: { $0 == 4242 })
        XCTAssertEqual(set, ["crashed"])
        XCTAssertTrue(state.isProcessing("theirs"))
        state.clearProcessingMarkers(ownedBy: 1)                      // our quit leaves theirs alone
        XCTAssertTrue(state.isProcessing("theirs"))
        state.clearProcessingMarkers(ownedBy: 4242)
        XCTAssertFalse(state.isProcessing("theirs"))
    }

    func testNormalQuitLeavesNothingToSetAside() throws {
        let root = TestTemp.root.appendingPathComponent("distavo-quit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try DistavoState.Store(stateDir: root.appendingPathComponent(".state"),
                                           notesDir: root.appendingPathComponent("notes"))
        state.markProcessing("in-flight")
        state.clearProcessingMarkers()                                 // applicationWillTerminate
        XCTAssertEqual(state.setAsideInterrupted(), [])
        XCTAssertFalse(state.isFailed("in-flight"))
    }
}
