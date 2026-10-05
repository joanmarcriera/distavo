import XCTest
@testable import DistavoCore

/// Vikunja #2955: untrusted text never reaches a terminal as control sequences.
final class TerminalSafeTests: XCTestCase {

    private func assertInert(_ s: String, file: StaticString = #filePath, line: UInt = #line) {
        let out = TerminalSafe.neutralised(s)
        for u in out.unicodeScalars where u != "\n" && u != "\t" {
            XCTAssertFalse(TerminalSafe.isDangerous(u), "left \(u.value) in \(out.debugDescription)", file: file, line: line)
        }
    }

    func testEscapeSequencesAreDefused() {
        for s in ["\u{1B}[2J", "\u{1B}]0;pwned\u{07}", "\u{1B}]8;;https://evil.example\u{1B}\\click\u{1B}]8;;\u{1B}\\",
                  "\u{1B}]52;c;aGVsbG8=\u{07}", "\u{9B}2J", "\u{9D}0;t\u{9C}", "a\u{0}b\u{7F}c", "line\rOVERWRITE"] {
            assertInert(s)
            XCTAssertFalse(TerminalSafe.neutralised(s).contains("\u{1B}"))
        }
        XCTAssertEqual(TerminalSafe.neutralised("\u{1B}[2J"), "\u{241B}[2J")
        XCTAssertEqual(TerminalSafe.neutralised("a\rb"), "a\u{240D}b", "a lone CR must not overwrite a line")
    }

    func testBidiOverridesAreMarked() {
        XCTAssertEqual(TerminalSafe.neutralised("evil\u{202E}txt.exe"), "evil<U+202E>txt.exe")
        assertInert("\u{2066}x\u{2069}\u{200F}\u{061C}\u{2028}")
    }

    func testOrdinaryTextIsUntouchedIncludingUnicode() {
        let s = "Hola, què tal?\n\tSPEAKER_00: 你好 😀 Ünïcode"
        XCTAssertEqual(TerminalSafe.neutralised(s), s)
    }

    func testCRLFCollapsesToLF() {
        XCTAssertEqual(TerminalSafe.neutralised("a\r\nb"), "a\nb")
    }

    func testSinkDecision() {
        let evil = "x\u{1B}[31my"
        XCTAssertEqual(TerminalSafe.forSink(evil, isTerminal: false), evil, "files and pipes get the text faithfully")
        XCTAssertNotEqual(TerminalSafe.forSink(evil, isTerminal: true), evil)
    }

    func testRandomScalarsAlwaysInert() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let s = String(String.UnicodeScalarView((0..<20).compactMap { _ in Unicode.Scalar(UInt32.random(in: 0...0x2100, using: &rng)) }))
            assertInert(s)
        }
    }

    // MARK: CLI integration

    private func runner(transcriptText: String, tty: Bool, out: @escaping (Data) -> Void, err: @escaping (String) -> Void,
                        failWith: Error? = nil) -> CLIRunner {
        CLIRunner(env: CLIEnvironment(
            loadConfig: { Config() },
            fileInfo: { $0 == "/in/a\u{1B}[2J.m4a" || $0 == "/in/a.m4a" ? CLIFileInfo(isRegularFile: true, size: 9) : nil },
            convertToWav: { _, _ in },
            transcribe: { _, _ in
                if let failWith { throw failWith }
                return ["segments": [["text": transcriptText, "start": 0.0, "end": 1.0, "speaker": "SPEAKER_00\u{1B}]0;x\u{07}"]]]
            },
            makeTempDir: { URL(fileURLWithPath: "/tmp/x") }, removeDir: { _ in },
            writeStdout: out, writeStderr: err,
            writeFile: { _, _, _ in }, version: "1", stdoutIsTerminal: tty))
    }

    func testTerminalStdoutIsNeutralisedButPipeIsFaithful() async {
        let evil = "hi \u{1B}[2J\u{1B}]52;c;AAAA\u{07} there"
        for (tty, format) in [(true, "md"), (true, "srt"), (true, "json")] {
            var out = Data()
            let code = await runner(transcriptText: evil, tty: tty, out: { out.append($0) }, err: { _ in })
                .run(args: ["transcribe", "/in/a.m4a", "-f", format])
            XCTAssertEqual(code, 0)
            XCTAssertFalse(String(decoding: out, as: UTF8.self).contains("\u{1B}"), format)
            XCTAssertFalse(String(decoding: out, as: UTF8.self).contains("\u{07}"), format)
        }
        var piped = Data()
        _ = await runner(transcriptText: evil, tty: false, out: { piped.append($0) }, err: { _ in })
            .run(args: ["transcribe", "/in/a.m4a", "-f", "md"])
        XCTAssertTrue(String(decoding: piped, as: UTF8.self).contains("\u{1B}[2J"), "pipe/file output is faithful")
    }

    func testDiagnosticsAreAlwaysNeutralised() async {
        struct Evil: LocalizedError { var errorDescription: String? { "bad \u{1B}]0;title\u{07} engine\r" } }
        var err = ""
        let code = await runner(transcriptText: "x", tty: false, out: { _ in }, err: { err += $0 }, failWith: Evil())
            .run(args: ["transcribe", "/in/a.m4a"])
        XCTAssertEqual(code, CLIExit.engine.rawValue)
        XCTAssertFalse(err.contains("\u{1B}") || err.contains("\u{07}") || err.contains("\r"))
        var err2 = ""
        _ = await runner(transcriptText: "x", tty: false, out: { _ in }, err: { err2 += $0 })
            .run(args: ["transcribe", "/in/missing\u{1B}[31m.m4a"])
        XCTAssertFalse(err2.contains("\u{1B}"))
        var err3 = ""
        _ = await runner(transcriptText: "x", tty: false, out: { _ in }, err: { err3 += $0 })
            .run(args: ["transcribe", "a.m4a", "--bogus\u{1B}[2J"])
        XCTAssertFalse(err3.contains("\u{1B}"))
    }
}
