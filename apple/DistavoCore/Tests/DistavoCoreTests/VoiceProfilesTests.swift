import XCTest
@testable import DistavoCore

/// Voice profiles (#2944 phase 2). Synthetic vectors and synthetic names only: no audio, no model.
final class VoiceProfilesTests: XCTestCase {
    private let model = "test-model"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A unit vector along axis `i` of 8, tilted by `tilt` towards axis `j`.
    private func v(_ i: Int, tilt: Float = 0, towards j: Int = 7) -> [Float] {
        var out = [Float](repeating: 0, count: 8)
        out[i] = 1; out[j] += tilt
        return out
    }

    private func tempDir() throws -> URL {
        let dir = TestTemp.root.appendingPathComponent("distavo-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Config

    func testOffByDefaultAndForOldConfigs() throws {
        XCTAssertFalse(Config().transcribe.voiceProfiles)
        let old = try JSONDecoder().decode(Config.self, from: Data(#"{"transcribe":{"backend":"server"}}"#.utf8))
        XCTAssertFalse(old.transcribe.voiceProfiles)
        XCTAssertFalse(Config.recommendedForThisMac().transcribe.voiceProfiles)
        let on = try JSONDecoder().decode(Config.self, from: Data(#"{"transcribe":{"voice_profiles":true}}"#.utf8))
        XCTAssertTrue(on.transcribe.voiceProfiles)
    }

    // MARK: Store

    func testEnrolMatchAndReject() {
        var store = VoiceProfileStore(model: model)
        XCTAssertTrue(store.enrol(name: "Oskar Lind", sample: v(0), now: t0))
        XCTAssertTrue(store.enrol(name: "Petra Novak", sample: v(1), now: t0))
        let m = store.match(speakers: ["SPEAKER_00": v(0, tilt: 0.2), "SPEAKER_01": v(1, tilt: 0.3), "SPEAKER_02": v(4)])
        XCTAssertEqual(m["SPEAKER_00"]?.name, "Oskar Lind")
        XCTAssertEqual(m["SPEAKER_01"]?.name, "Petra Novak")
        XCTAssertNil(m["SPEAKER_02"], "an unknown voice keeps its label")
        XCTAssertGreaterThan(m["SPEAKER_00"]!.score, 0.9)
    }

    func testAmbiguousVoiceIsNotNamed() {
        var store = VoiceProfileStore(model: model)
        store.enrol(name: "Oskar Lind", sample: v(0), now: t0)
        store.enrol(name: "Petra Novak", sample: v(1), now: t0)
        // Half way between the two: clears the threshold for both, but not the margin.
        let between: [Float] = [1, 0.95, 0, 0, 0, 0, 0, 0]
        XCTAssertTrue(store.match(speakers: ["SPEAKER_00": between]).isEmpty)
        XCTAssertEqual(store.match(speakers: ["SPEAKER_00": between], margin: 0)["SPEAKER_00"]?.name, "Oskar Lind")
    }

    func testTwoSpeakersNeverShareAProfile() {
        var store = VoiceProfileStore(model: model)
        store.enrol(name: "Oskar Lind", sample: v(0), now: t0)
        let m = store.match(speakers: ["SPEAKER_00": v(0, tilt: 0.4), "SPEAKER_01": v(0, tilt: 0.1)])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m["SPEAKER_01"]?.name, "Oskar Lind", "the closer voice keeps the name")
    }

    func testSamplesPerMicrophoneAndTheCap() {
        var store = VoiceProfileStore(model: model)
        store.enrol(name: "Oskar Lind", sample: v(0), now: t0)
        store.enrol(name: "oskar lind", sample: v(0, tilt: 0.1), now: t0)          // same path: merged
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].samples.count, 1)
        XCTAssertEqual(store.profiles[0].enrolments, 2)
        for axis in 1...6 { store.enrol(name: "Oskar Lind", sample: v(axis), now: t0) }   // other microphones
        XCTAssertEqual(store.profiles[0].samples.count, VoiceProfileStore.maxSamples)
        XCTAssertEqual(store.match(speakers: ["SPEAKER_00": v(6)])["SPEAKER_00"]?.name, "Oskar Lind")
        XCTAssertNil(store.match(speakers: ["SPEAKER_00": v(0)])["SPEAKER_00"], "the oldest sample was dropped")
    }

    func testUnusableSamplesAreRefused() {
        var store = VoiceProfileStore(model: model)
        XCTAssertFalse(store.enrol(name: "Oskar Lind", sample: [], now: t0))
        XCTAssertFalse(store.enrol(name: "Oskar Lind", sample: [0, 0, 0], now: t0))
        XCTAssertFalse(store.enrol(name: "Oskar Lind", sample: [.nan, 1], now: t0))
        XCTAssertFalse(store.enrol(name: "  ", sample: v(0), now: t0))
        store.enrol(name: "Oskar Lind", sample: v(0), now: t0)
        XCTAssertFalse(store.enrol(name: "Oskar Lind", sample: [1, 0], now: t0), "another dimension")
        XCTAssertTrue(store.match(speakers: ["SPEAKER_00": [1, 0]]).isEmpty)
    }

    func testFileIsPrivateAndGoesWhenEmpty() throws {
        let dir = try tempDir()
        var store = VoiceProfileStore(model: model)
        try store.save(supportDir: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: VoiceProfileStore.url(supportDir: dir).path), "nothing stored, no file")
        store.enrol(name: "Oskar Lind", sample: v(0), now: t0)
        try store.save(supportDir: dir)
        let path = VoiceProfileStore.url(supportDir: dir).path
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
        XCTAssertEqual(VoiceProfileStore.load(supportDir: dir, model: model), store)
        XCTAssertTrue(VoiceProfileStore.load(supportDir: dir, model: "another-model").profiles.isEmpty, "never mixed across models")
        XCTAssertTrue(VoiceProfileStore.hasIncompatibleFile(supportDir: dir, model: "another-model"))
        XCTAssertFalse(VoiceProfileStore.hasIncompatibleFile(supportDir: dir, model: model))
        XCTAssertTrue(store.delete(name: "OSKAR LIND"))
        try store.save(supportDir: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // MARK: Sampler

    private func seg(_ speaker: String?, _ start: Double, _ end: Double) -> TranscriptSegments.Segment {
        .init(start: start, end: end, text: "words", speaker: speaker)
    }

    func testSamplerTakesLongTurnsAwayFromTheEdges() {
        let r = VoiceSampler.ranges(for: [
            seg("SPEAKER_00", 0, 12), seg("SPEAKER_01", 12, 13), seg("SPEAKER_00", 13, 40),
            seg("SPEAKER_01", 40, 44), seg(nil, 44, 60), seg("SPEAKER_00", 60, 61),
        ])
        XCTAssertNil(r["SPEAKER_01"], "under eight seconds of usable speech: no sample")
        let ranges = r["SPEAKER_00"]!
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].lowerBound, 0.3, accuracy: 1e-9)
        XCTAssertEqual(ranges[1].lowerBound, 13.3, accuracy: 1e-9)
        let total = ranges.reduce(0.0) { $0 + $1.upperBound - $1.lowerBound }
        XCTAssertEqual(total, VoiceSampler.maxSeconds, accuracy: 1e-9)
        XCTAssertNil(VoiceSampler.ranges(for: [seg("SPEAKER_00", 0, 20)], only: ["Someone else"])["SPEAKER_00"])
    }

    // MARK: Recognise / remember on a recording's files

    private let note = "# Supplier call\n\n## Speakers\n- SPEAKER_00\n- SPEAKER_01\n\nSPEAKER_01 said the pipes are late.\n"
    private let transcript = "[SPEAKER_00]\nHello there.\n\n[SPEAKER_01]\nThe pipes are late.\n"

    private func recording() throws -> (notes: URL, work: URL, support: URL) {
        let root = try tempDir()
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try note.write(to: notes.appendingPathComponent("demo.md"), atomically: true, encoding: .utf8)
        try transcript.write(to: Pipeline.cachedTranscriptURL(workDir: work, base: "demo"), atomically: true, encoding: .utf8)
        try TranscriptSegments(segments: [seg("SPEAKER_00", 0, 20), seg("SPEAKER_01", 20, 45), seg("SPEAKER_00", 45, 47)])
            .save(workDir: work, base: "demo")
        return (notes, work, root.appendingPathComponent("support"))
    }

    // MARK: Recognition before the summary

    /// An engine result with two speakers, long enough turns to sample.
    private var engineResult: [String: Any] {
        ["segments": [
            ["speaker": "SPEAKER_00", "start": 0.0, "end": 20.0, "text": "Hello there, thanks for joining.",
             "words": [["word": "Hello", "start": 0.0, "end": 0.4, "speaker": "SPEAKER_00"]]],
            ["speaker": "SPEAKER_01", "start": 20.0, "end": 45.0, "text": "The pipes are late.",
             "words": [["word": "The", "start": 20.0, "end": 20.2, "speaker": "SPEAKER_01"]]],
        ], "language": "en"]
    }

    private func storeWithPetra() throws -> URL {
        let support = try tempDir()
        var store = VoiceProfileStore(model: model)
        store.enrol(name: "Petra Novak", sample: v(1), now: t0)
        try store.save(supportDir: support)
        return support
    }

    func testRelabelNamesTheKnownVoiceInSegmentsAndWords() async throws {
        let support = try storeWithPetra()
        final class Box: @unchecked Sendable { var asked: [String] = [] }
        let box = Box()
        let out = await VoiceRecognition.relabel(
            result: engineResult, audio: URL(fileURLWithPath: "/dev/null"), supportDir: support, model: model,
            embed: { _, ranges in box.asked = ranges.keys.sorted(); return ["SPEAKER_00": self.v(3), "SPEAKER_01": self.v(1, tilt: 0.2)] })
        XCTAssertEqual(box.asked, ["SPEAKER_00", "SPEAKER_01"])
        XCTAssertEqual(out.names.mapValues(\.name), ["SPEAKER_01": "Petra Novak"])
        let segments = out.result["segments"] as! [[String: Any]]
        XCTAssertEqual(segments.map { $0["speaker"] as? String }, ["SPEAKER_00", "Petra Novak"])
        XCTAssertEqual((segments[1]["words"] as! [[String: Any]])[0]["speaker"] as? String, "Petra Novak")
        XCTAssertEqual(out.result["language"] as? String, "en")
        XCTAssertEqual(segments[1]["text"] as? String, "The pipes are late.")
    }

    func testNothingStoredMeansTheEngineIsNotAsked() async throws {
        let out = await VoiceRecognition.relabel(
            result: engineResult, audio: URL(fileURLWithPath: "/dev/null"), supportDir: try tempDir(), model: model,
            embed: { _, _ in XCTFail("no profile: the engine must not run"); return [:] })
        XCTAssertTrue(out.names.isEmpty)
        XCTAssertEqual((out.result["segments"] as! [[String: Any]]).map { $0["speaker"] as? String }, ["SPEAKER_00", "SPEAKER_01"])
    }

    // MARK: The whole pipeline

    private func pipelineEnv() throws -> (Config, URL, PipelineDeps) {
        let root = try tempDir()
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        let input = rec.appendingPathComponent("demo.opus")
        try Data([0, 1, 2, 3]).write(to: input)
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        let result = engineResult
        let deps = PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in result }, ollamaReachable: { _ in true },
            summarise: { _, _, _, _ in PipelineTests.validNote }, audioDurationSeconds: { _ in nil })
        return (cfg, input, deps)
    }

    func testPipelineGivesTheSummaryTheRecognisedName() async throws {
        var (cfg, input, deps) = try pipelineEnv()
        cfg.transcribe.voiceProfiles = true
        cfg.noteOwner = "Petra Novak"
        deps.voiceProfilesDir = try storeWithPetra()
        deps.voiceModel = model
        deps.voiceEmbeddings = { _, _ in ["SPEAKER_00": self.v(3), "SPEAKER_01": self.v(1)] }
        final class Box: @unchecked Sendable { var transcript = ""; var owner = "" }
        let box = Box()
        deps.summarise = { transcript, _, _, context in
            box.transcript = transcript; box.owner = context.userSpeaker
            return PipelineTests.validNote
        }
        let r = await Pipeline.processOne(path: input, config: cfg, deps: deps, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertTrue(box.transcript.contains("[Petra Novak]") && !box.transcript.contains("[SPEAKER_01]"), box.transcript)
        XCTAssertTrue(box.transcript.contains("[SPEAKER_00]"), "the unknown voice keeps its label")
        XCTAssertEqual(box.owner, "Petra Novak", "the owner is found by their own remembered voice")
        XCTAssertTrue(r.message.contains("voices recognised: Petra Novak"))
        let work = URL(fileURLWithPath: cfg.workDir)
        XCTAssertEqual(SpeakerNames.load(workDir: work, base: "demo")?.names, ["SPEAKER_01": "Petra Novak"])
        XCTAssertEqual(TranscriptSegments.load(workDir: work, base: "demo")?.segments[1].speaker, "Petra Novak")
        let note = try String(contentsOf: try XCTUnwrap(r.notePath), encoding: .utf8)
        XCTAssertTrue(note.contains("Speakers named from remembered voices: Petra Novak"), note)
    }

    func testPipelineIsUnchangedWhenTheSettingIsOff() async throws {
        var (cfg, input, deps) = try pipelineEnv()
        deps.voiceProfilesDir = try storeWithPetra()
        deps.voiceModel = model
        deps.voiceEmbeddings = { _, _ in XCTFail("off: the engine must not run"); return [:] }
        let plain = await Pipeline.processOne(path: input, config: cfg, deps: deps, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(plain.status, .done)
        let note = try String(contentsOf: try XCTUnwrap(plain.notePath), encoding: .utf8)
        XCTAssertFalse(note.contains("remembered voices"))
        XCTAssertNil(SpeakerNames.load(workDir: URL(fileURLWithPath: cfg.workDir), base: "demo"))
        XCTAssertEqual(plain.timings?.steps.map(\.name), ["convert", "transcribe", "summarise+note"])
        _ = cfg
    }

    func testRememberStoresOnlyTheTickedNames() async throws {
        let (notes, work, support) = try recording()
        try SpeakerRename.apply(mapping: ["SPEAKER_00": "Dana Owner", "SPEAKER_01": "Petra Novak"], base: "demo",
                                notesDir: notes, workDir: work)
        let stored = try await VoiceRecognition.remember(
            names: ["Petra Novak", "SPEAKER_07"], base: "demo", audio: work.appendingPathComponent("demo.wav"),
            workDir: work, supportDir: support, model: model,
            embed: { _, ranges in
                XCTAssertEqual(ranges.keys.sorted(), ["Petra Novak"], "only the ticked name is embedded")
                return ["Petra Novak": self.v(1)]
            }, now: t0)
        XCTAssertEqual(stored, ["Petra Novak"])
        XCTAssertEqual(VoiceProfileStore.load(supportDir: support, model: model).names, ["Petra Novak"])
    }

    func testANameAlreadyInTheRecordingIsNotGivenTwice() async throws {
        let support = try storeWithPetra()
        var result = engineResult
        var segments = result["segments"] as! [[String: Any]]
        segments[0]["speaker"] = "Petra Novak"
        result["segments"] = segments
        let out = await VoiceRecognition.relabel(
            result: result, audio: URL(fileURLWithPath: "/dev/null"), supportDir: support, model: model,
            embed: { _, _ in ["SPEAKER_01": self.v(1)] })
        XCTAssertTrue(out.names.isEmpty, "it would merge two speakers into one person")
    }

    func testTheFileIsPrivateAndLeavesNoTemporaryFileBehind() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var store = VoiceProfileStore(model: VoiceProfileStore.builtInModel)
        XCTAssertTrue(store.enrol(name: "Anna", sample: [1, 0, 0], now: Date()))
        for _ in 0..<2 {   // first write, then a replace
            try store.save(supportDir: dir)
            let attrs = try FileManager.default.attributesOfItem(atPath: VoiceProfileStore.url(supportDir: dir).path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [VoiceProfileStore.fileName])
        }
        XCTAssertEqual(VoiceProfileStore.load(supportDir: dir, model: VoiceProfileStore.builtInModel).names, ["Anna"])
    }
}
