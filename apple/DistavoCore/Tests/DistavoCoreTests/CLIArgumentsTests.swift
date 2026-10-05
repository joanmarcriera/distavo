import XCTest
@testable import DistavoCore

/// Vikunja #2955: the pure CLI argument parser.
final class CLIArgumentsTests: XCTestCase {

    private func ok(_ args: [String], file: StaticString = #filePath, line: UInt = #line) -> CLICommand? {
        if case .success(let c) = CLIArguments.parse(args) { return c }
        XCTFail("expected success for \(args)", file: file, line: line); return nil
    }
    private func err(_ args: [String]) -> CLIParseError? {
        if case .failure(let e) = CLIArguments.parse(args) { return e }
        return nil
    }

    // MARK: entry gate

    func testOnlyAKnownFirstArgumentIsCLIMode() {
        XCTAssertTrue(CLIArguments.isCLIInvocation(["transcribe", "a.m4a"]))
        XCTAssertTrue(CLIArguments.isCLIInvocation(["--help"]))
        XCTAssertTrue(CLIArguments.isCLIInvocation(["--version"]))
        XCTAssertFalse(CLIArguments.isCLIInvocation([]))
    }

    func testArgumentsMacOSPassesNeverTriggerCLIMode() {
        XCTAssertFalse(CLIArguments.isCLIInvocation(["-psn_0_123456"]))
        XCTAssertFalse(CLIArguments.isCLIInvocation(["-NSDocumentRevisionsDebugMode", "YES"]))
        XCTAssertFalse(CLIArguments.isCLIInvocation(["-ApplePersistenceIgnoreState", "YES"]))
        XCTAssertFalse(CLIArguments.isCLIInvocation(["-AppleLanguages", "(en)"]))
        // A verb that is not the FIRST argument does not count.
        XCTAssertFalse(CLIArguments.isCLIInvocation(["-ApplePersistenceIgnoreState", "transcribe"]))
        // Exact match only: no prefixes, case folding or whitespace.
        for s in ["Transcribe", "transcribe ", "transcribes", "--helpx", "-help", "--Version", ""] {
            XCTAssertFalse(CLIArguments.isCLIInvocation([s]), s)
        }
    }

    // MARK: help / version / unknown

    func testHelpAndVersion() {
        XCTAssertEqual(ok(["--help"]), .help)
        XCTAssertEqual(ok(["-h"]), .help)
        XCTAssertEqual(ok(["help"]), .help)
        XCTAssertEqual(ok(["--version"]), .version)
        XCTAssertEqual(ok(["version"]), .version)
        XCTAssertEqual(err([]), .noCommand)
        XCTAssertEqual(err(["frobnicate"]), .unknownCommand("frobnicate"))
    }

    // MARK: transcribe

    func testMinimalTranscribeDefaultsToSRT() {
        XCTAssertEqual(ok(["transcribe", "a.m4a"]),
                       .transcribe(CLITranscribeOptions(input: "a.m4a", format: .srt)))
    }

    func testAllOptionsLongAndShort() {
        let long = ok(["transcribe", "/x/My Talk.m4a", "--format", "VTT", "--output", "/o/out file.vtt",
                       "--language", "ca", "--model", "large-v3-turbo", "--force"])
        let short = ok(["transcribe", "-f", "vtt", "-o", "/o/out file.vtt", "-l", "ca", "-m", "large-v3-turbo",
                        "--force", "/x/My Talk.m4a"])
        let expected = CLICommand.transcribe(CLITranscribeOptions(
            input: "/x/My Talk.m4a", format: .vtt, output: "/o/out file.vtt",
            language: "ca", model: "large-v3-turbo", force: true))
        XCTAssertEqual(long, expected)
        XCTAssertEqual(short, expected)
    }

    func testEqualsSyntax() {
        XCTAssertEqual(ok(["transcribe", "a.wav", "--format=json", "--output=out.json", "--language=pt-BR"]),
                       .transcribe(CLITranscribeOptions(input: "a.wav", format: .json, output: "out.json", language: "pt-BR")))
    }

    func testPathsWithSpacesAndUnicodeAreOneArgument() {
        XCTAssertEqual(ok(["transcribe", "/Users/me/Reunió d'equip (v2).m4a"]),
                       .transcribe(CLITranscribeOptions(input: "/Users/me/Reunió d'equip (v2).m4a")))
    }

    func testDoubleDashEndsOptions() {
        XCTAssertEqual(ok(["transcribe", "--format", "md", "--", "-weird name.m4a"]),
                       .transcribe(CLITranscribeOptions(input: "-weird name.m4a", format: .md)))
        // After `--` a flag-looking token is just a (second) input.
        XCTAssertEqual(err(["transcribe", "--", "--force", "b.m4a"]), .tooManyInputs)
        XCTAssertEqual(err(["transcribe", "--"]), .missingInput)
    }

    func testOutputDashMeansStdout() {
        guard case .transcribe(let o)? = ok(["transcribe", "a.wav", "-o", "-"]) else { return XCTFail() }
        XCTAssertTrue(o.writesToStdout)
        guard case .transcribe(let o2)? = ok(["transcribe", "a.wav"]) else { return XCTFail() }
        XCTAssertTrue(o2.writesToStdout)
        guard case .transcribe(let o3)? = ok(["transcribe", "a.wav", "-o", "x.srt"]) else { return XCTFail() }
        XCTAssertFalse(o3.writesToStdout)
    }

    func testUsageErrors() {
        XCTAssertEqual(err(["transcribe"]), .missingInput)
        XCTAssertEqual(err(["transcribe", "a.m4a", "b.m4a"]), .tooManyInputs)
        XCTAssertEqual(err(["transcribe", "a.m4a", "--bogus"]), .unknownFlag("--bogus"))
        XCTAssertEqual(err(["transcribe", "a.m4a", "-z"]), .unknownFlag("-z"))
        XCTAssertEqual(err(["transcribe", "a.m4a", "--format"]), .missingValue("--format"))
        XCTAssertEqual(err(["transcribe", "a.m4a", "--format", "--force"]), .missingValue("--format"))
        XCTAssertEqual(err(["transcribe", "a.m4a", "--output="]), .missingValue("--output"))
        XCTAssertEqual(err(["transcribe", "a.m4a", "--format", "docx"]), .invalidFormat("docx"))
        XCTAssertEqual(err(["transcribe", "a.m4a", "--format", "srt", "--format", "vtt"]), .duplicateFlag("--format"))
        XCTAssertEqual(err(["transcribe", "a.m4a", "--force", "--force"]), .duplicateFlag("--force"))
        XCTAssertEqual(err(["transcribe", "a.m4a", "--force=yes"]), .unexpectedValue("--force"))
        XCTAssertEqual(err(["transcribe", "a.m4a", "-l", "en;rm -rf"]), .invalidLanguage("en;rm -rf"))
        XCTAssertEqual(err(["transcribe", "a.m4a", "-l", "español"]), .invalidLanguage("español"))
        XCTAssertEqual(err(["transcribe", "a.m4a", "-m", "a b"]), .invalidModel("a b"))
        XCTAssertEqual(err(["transcribe", "a.m4a", "-m", "x$(id)"]), .invalidModel("x$(id)"))
    }

    func testNULAndHugeValuesRejected() {
        XCTAssertEqual(err(["transcribe", "a\0b.m4a"]), .invalidPath("a\0b.m4a"))
        let huge = String(repeating: "a", count: 5000)
        if case .invalidPath? = err(["transcribe", huge]) {} else { XCTFail() }
        if case .invalidLanguage? = err(["transcribe", "a.m4a", "-l", String(repeating: "e", count: 17)]) {} else { XCTFail() }
    }

    func testErrorMessagesNeutraliseControlCharactersAndLength() {
        let msg = CLIParseError.unknownFlag("--x\u{1B}[31m" + String(repeating: "y", count: 200)).message
        XCTAssertFalse(msg.contains("\u{1B}"))
        XCTAssertLessThan(msg.count, 120)
    }

    func testArbitraryArgumentListsNeverCrash() {
        var rng = SystemRandomNumberGenerator()
        let pool = ["transcribe", "--", "-", "--format", "-f", "-o", "--output", "=", "--force", "srt", "",
                    "a.m4a", "--format=", "-l", "--language=ca", "\0", "😀", String(repeating: "z", count: 5000)]
        for _ in 0..<3000 {
            let args = (0..<Int.random(in: 0...8, using: &rng)).map { _ in pool.randomElement(using: &rng)! }
            _ = CLIArguments.parse(args)
            _ = CLIArguments.isCLIInvocation(args)
        }
    }
}
