import XCTest
@testable import DistavoCore

/// Vikunja #2955: `CLIRunner` driven through injected fakes (no engine, no disk).
final class CLIRunnerTests: XCTestCase {

    /// Everything the fake environment observed.
    final class Probe {
        var stdout = Data()
        var stderr = ""
        var files: [String: Data] = [:]
        var existing: [String: CLIFileInfo] = ["/in/talk.m4a": CLIFileInfo(isRegularFile: true, size: 1000)]
        var convertCalls = 0, transcribeCalls = 0, loadConfigCalls = 0
        var transcribeConfig: TranscribeConfig?
        var tempDirsMade: [URL] = [], tempDirsRemoved: [URL] = []
        var config = Config()
        var result: [String: Any] = CLIRunnerTests.timedResult
        var convertError: Error?, transcribeError: Error?
        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    }

    struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    static let timedResult: [String: Any] = ["segments": [
        ["text": "Hello there.", "start": 0.0, "end": 2.5, "speaker": "SPEAKER_00"],
        ["text": "General Kenobi.", "start": 3.0, "end": 5.25, "speaker": "SPEAKER_01"],
    ]]

    private func runner(_ p: Probe) -> CLIRunner {
        CLIRunner(env: CLIEnvironment(
            loadConfig: { p.loadConfigCalls += 1; return p.config },
            fileInfo: { p.existing[$0] },
            convertToWav: { _, _ in p.convertCalls += 1; if let e = p.convertError { throw e } },
            transcribe: { _, cfg in
                p.transcribeCalls += 1; p.transcribeConfig = cfg
                if let e = p.transcribeError { throw e }
                return p.result
            },
            makeTempDir: { let u = URL(fileURLWithPath: "/tmp/fake-\(p.tempDirsMade.count)"); p.tempDirsMade.append(u); return u },
            removeDir: { p.tempDirsRemoved.append($0) },
            writeStdout: { p.stdout.append($0) },
            writeStderr: { p.stderr += $0 },
            writeFile: { path, data, overwrite in
                if !overwrite && p.files[path] != nil { throw Boom() }
                p.files[path] = data
            },
            version: "9.9.9"))
    }

    private func assertExit(_ p: Probe, _ args: [String], _ expected: Int32, _ msg: String = "",
                            file: StaticString = #filePath, line: UInt = #line) async {
        let code = await runner(p).run(args: args)
        XCTAssertEqual(code, expected, msg, file: file, line: line)
    }

    private func run(_ p: Probe, _ args: [String]) async -> Int32 { await runner(p).run(args: args) }

    // MARK: formats

    func testSRTIsValidSubRip() async {
        let p = Probe()
        let code = await run(p, ["transcribe", "/in/talk.m4a"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(p.stdoutText,
            "1\n00:00:00,000 --> 00:00:02,500\nSPEAKER_00: Hello there.\n\n"
            + "2\n00:00:03,000 --> 00:00:05,250\nSPEAKER_01: General Kenobi.\n\n")
        XCTAssertEqual(p.stderr, "")
        // Structural check any SRT consumer relies on: index, timing line, text, blank.
        let blocks = p.stdoutText.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        for (i, b) in blocks.enumerated() {
            let lines = b.components(separatedBy: "\n")
            XCTAssertEqual(lines[0], "\(i + 1)")
            XCTAssertNotNil(lines[1].range(of: #"^\d{2}:\d{2}:\d{2},\d{3} --> \d{2}:\d{2}:\d{2},\d{3}$"#, options: .regularExpression))
        }
    }

    func testVTTHasHeaderAndDotSeparator() async {
        let p = Probe()
        let code = await run(p, ["transcribe", "/in/talk.m4a", "--format", "vtt"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(p.stdoutText.hasPrefix("WEBVTT\n\n1\n00:00:00.000 --> 00:00:02.500\n<v SPEAKER_00>Hello there.</v>"))
    }

    func testJSONIsValidAndTimed() async throws {
        let p = Probe()
        let code = await run(p, ["transcribe", "/in/talk.m4a", "-f", "json"])
        XCTAssertEqual(code, 0)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: p.stdout) as? [String: Any])
        let segs = try XCTUnwrap(obj["segments"] as? [[String: Any]])
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[1]["text"] as? String, "General Kenobi.")
        XCTAssertEqual(segs[1]["end"] as? Double, 5.25)
    }

    func testMarkdownIsTheCleanedSpeakerGroupedTranscript() async {
        let p = Probe()
        p.config.transcribe.replacements = [ReplacementRule(from: "Kenobi", to: "Obi-Wan")]
        let code = await run(p, ["transcribe", "/in/talk.m4a", "--format", "md"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(p.stdoutText.contains("SPEAKER_00"))
        XCTAssertTrue(p.stdoutText.contains("Hello there."))
        XCTAssertTrue(p.stdoutText.contains("General Obi-Wan."), "user replacements apply, as in the app")
        XCTAssertFalse(p.stdoutText.contains("-->"))
    }

    func testMarkdownWorksWithTextOnlyResultButSRTReportsNoTimings() async {
        let p = Probe()
        p.result = ["text": "just words, no timings"]
        await assertExit(p, ["transcribe", "/in/talk.m4a", "-f", "md"], 0)
        XCTAssertTrue(p.stdoutText.contains("just words"))
        let p2 = Probe(); p2.result = ["text": "just words"]
        await assertExit(p2, ["transcribe", "/in/talk.m4a", "-f", "srt"], CLIExit.engine.rawValue)
        XCTAssertTrue(p2.stderr.contains("no timed segments"))
        XCTAssertEqual(p2.stdout.count, 0)
    }

    // MARK: output

    func testOutputFileIsWrittenAndStdoutStaysEmpty() async {
        let p = Probe()
        let code = await run(p, ["transcribe", "/in/talk.m4a", "-o", "/out/talk.srt"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(p.stdout.count, 0)
        XCTAssertTrue(String(decoding: p.files["/out/talk.srt"] ?? Data(), as: UTF8.self).hasPrefix("1\n00:00:00,000"))
    }

    func testExistingOutputIsRefusedBeforeTranscribingUnlessForced() async {
        let p = Probe()
        p.existing["/out/talk.srt"] = CLIFileInfo(isRegularFile: true, size: 5)
        let code = await run(p, ["transcribe", "/in/talk.m4a", "-o", "/out/talk.srt"])
        XCTAssertEqual(code, CLIExit.input.rawValue)
        XCTAssertEqual(p.transcribeCalls, 0, "refuse before the slow work")
        XCTAssertTrue(p.stderr.contains("already exists"))
        XCTAssertNil(p.files["/out/talk.srt"])

        await assertExit(p, ["transcribe", "/in/talk.m4a", "-o", "/out/talk.srt", "--force"], 0)
        XCTAssertNotNil(p.files["/out/talk.srt"])
    }

    func testOutputThatWouldReplaceTheInputIsRefusedEvenWithForce() async {
        let p = Probe()
        let code = await run(p, ["transcribe", "/in/talk.m4a", "-o", "/in/../in/talk.m4a", "--force"])
        XCTAssertEqual(code, CLIExit.input.rawValue)
        XCTAssertEqual(p.convertCalls, 0)
    }

    func testRaceOnOutputIsCaughtByTheExclusiveWrite() async {
        let p = Probe()
        let r = CLIRunner(env: {
            var e = runner(p).env
            // The file "appears" between the check and the write.
            e.writeFile = { _, _, overwrite in if !overwrite { throw Boom() } }
            return e
        }())
        let code = await r.run(args: ["transcribe", "/in/talk.m4a", "-o", "/out/x.srt"])
        XCTAssertEqual(code, CLIExit.input.rawValue)
        XCTAssertTrue(p.stderr.contains("could not write"))
    }

    // MARK: input problems -> 3, usage -> 2, engine -> 4

    func testInputProblemsExit3WithoutTouchingTheEngine() async {
        let p = Probe()
        p.existing["/in/dir.m4a"] = CLIFileInfo(isRegularFile: false, size: 0)
        p.existing["/in/empty.m4a"] = CLIFileInfo(isRegularFile: true, size: 0)
        p.existing["/in/notes.txt"] = CLIFileInfo(isRegularFile: true, size: 9)
        for path in ["/in/missing.m4a", "/in/dir.m4a", "/in/empty.m4a", "/in/notes.txt"] {
            await assertExit(p, ["transcribe", path], CLIExit.input.rawValue, path)
        }
        XCTAssertEqual(p.convertCalls + p.transcribeCalls, 0)
        XCTAssertTrue(p.tempDirsMade.isEmpty, "no temp dir for a rejected input")
    }

    func testUnreadableAudioExit3AndTempIsRemoved() async {
        let p = Probe(); p.convertError = Boom()
        await assertExit(p, ["transcribe", "/in/talk.m4a"], CLIExit.input.rawValue)
        XCTAssertEqual(p.tempDirsMade, p.tempDirsRemoved)
        XCTAssertTrue(p.stderr.contains("could not read the audio"))
    }

    func testEngineFailureExit4IncludingRetryableAndTempIsRemoved() async {
        let p = Probe(); p.transcribeError = RetryableDependencyError("model still downloading")
        await assertExit(p, ["transcribe", "/in/talk.m4a"], CLIExit.engine.rawValue)
        XCTAssertTrue(p.stderr.contains("model still downloading"))
        XCTAssertEqual(p.tempDirsMade, p.tempDirsRemoved)
        let p2 = Probe(); p2.transcribeError = Boom()
        await assertExit(p2, ["transcribe", "/in/talk.m4a"], CLIExit.engine.rawValue)
    }

    func testUsageErrorsExit2AndNothingRuns() async {
        let p = Probe()
        for args in [[], ["transcribe"], ["transcribe", "a.m4a", "--nope"], ["frobnicate"]] {
            await assertExit(p, args, CLIExit.usage.rawValue, "\(args)")
        }
        XCTAssertEqual(p.loadConfigCalls + p.convertCalls + p.transcribeCalls, 0)
        XCTAssertTrue(p.stderr.contains("Try 'Distavo --help'"))
    }

    func testHelpAndVersionExit0OnStdout() async {
        let p = Probe()
        await assertExit(p, ["--help"], 0)
        XCTAssertTrue(p.stdoutText.contains("Usage:"))
        XCTAssertTrue(p.stdoutText.contains("Exit codes"))
        let p2 = Probe()
        await assertExit(p2, ["--version"], 0)
        XCTAssertEqual(p2.stdoutText, "Distavo 9.9.9\n")
        XCTAssertEqual(p.stderr + p2.stderr, "")
    }

    // MARK: config handling

    func testFlagsOverrideARunLocalCopyOfTheConfig() async {
        let p = Probe()
        p.config.transcribe.backend = "embedded"
        p.config.transcribe.language = "en"
        let before = p.config
        let code = await run(p, ["transcribe", "/in/talk.m4a", "-l", "ca", "-m", "large-v3-turbo"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(p.transcribeConfig?.language, "ca")
        XCTAssertEqual(p.transcribeConfig?.embeddedModel, "large-v3-turbo")
        XCTAssertEqual(p.config, before, "the loaded config is never mutated or saved")
    }

    func testServerBackendModelFlagSetsTheServerModel() async {
        let p = Probe(); p.config.transcribe.backend = "server"
        _ = await run(p, ["transcribe", "/in/talk.m4a", "-m", "large-v3"])
        XCTAssertEqual(p.transcribeConfig?.model, "large-v3")
    }

    func testUnknownBuiltInModelIsAUsageError() async {
        let p = Probe(); p.config.transcribe.backend = "embedded"
        await assertExit(p, ["transcribe", "/in/talk.m4a", "-m", "no-such-model"], CLIExit.usage.rawValue)
        XCTAssertEqual(p.transcribeCalls, 0)
    }

    func testNoFlagsUsesTheConfigUntouched() async {
        let p = Probe(); p.config.transcribe.language = "es"
        _ = await run(p, ["transcribe", "/in/talk.m4a"])
        XCTAssertEqual(p.transcribeConfig, p.config.transcribe)
    }
}
