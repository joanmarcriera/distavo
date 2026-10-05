import XCTest
import CryptoKit
@testable import DistavoCore

/// Note language beyond Catalan/Spanish (Vikunja #2956): the resolver, the
/// generic prompt instruction and end-of-turn block, and — most importantly —
/// proof that every case that existed before is unchanged byte for byte.
final class NoteLanguageTests: XCTestCase {

    private func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func prompt(_ style: Prompt.Style, _ lang: String?) -> String {
        Prompt.build(transcript: "SPEAKER_00: hello", noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                     participants: "Marc, Anna", style: style, meetingDate: date, noteLanguage: lang)
    }

    private func eot(_ style: Prompt.Style, _ lang: String?) -> String {
        EndOfTurnBlock.build(noteLanguage: lang, style: style, noteOwner: "Marc", ownerSpeaker: "SPEAKER_00")
    }

    // MARK: Byte-identical pins
    // SHA-256 digests of the FULL prompt / end-of-turn text produced by the code
    // on `main` before #2956 (meeting date rendered in UTC — see setUp). Any change to
    // these outputs fails here; regenerate only with an intentional wording change.

    override func setUp() { setenv("TZ", "UTC", 1); tzset(); NSTimeZone.resetSystemTimeZone() }

    private let goldPrompt: [String: String] = [
        "classic nil": "25b94a060da78417fb15156ed53f7b7f6e9e784bf81a6054fef5483508a20bde",
        "classic ca": "0e937d748ac6c886d4bee23cf421ecb18a6a4ce32d56a5df80d630294f47f4f8",
        "classic es": "f46bb695a16c57eea36d818375652e4335bea1e7ea9588fe1e02e7ed15204d9b",
        "facts_first nil": "9e354f9b08a7fd5d67e533eecc51cd1bbb7595860ce2e4eff98d584292ffca8f",
        "facts_first ca": "f55bc1469f451b94e953a45a3e09f56b2b225457abdc6a052f7c4e090a5a8f83",
        "facts_first es": "695cc244dc7d0803c7ee0d11f7ebb0295b59037b613a57c6bb79a75047d51116",
    ]
    private let goldEOT: [String: String] = [
        "classic nil": "2e65114e1bfd98821021862c9b566a817f7aabe6267de98e42ab6a0f42f8595c",
        "classic ca": "846ead89771344ad60fdea2c42677a2bfae625c1c2ed0886fcf6a68512e80939",
        "classic es": "b2adbe2da38e7f693252f0149706357cbf080155eadcbe08d829126c6fb11aed",
        "facts_first nil": "5508371d616b170a1be48125e3a0ae74ded70377ab2ca4c82e044a241df49c26",
        "facts_first ca": "e34c5870acf3dd2e4e421beb63fed2d9dac7acf8300763f69d6997471ce7a1ef",
        "facts_first es": "981755ac67935d55e47308196ce84408a2c37d7e572bb5d46cbbfc94db7e2468",
    ]

    func testExistingPromptsAndBlocksAreByteIdenticalToMain() {
        for style in [Prompt.Style.classic, .factsFirst] {
            // nil, "en", an unknown code and "auto" all keep the untouched English prompt.
            for lang in [nil, "en", "xx", "auto", ""] as [String?] {
                XCTAssertEqual(sha(prompt(style, lang)), goldPrompt["\(style.rawValue) nil"], "prompt \(style) \(lang ?? "nil")")
                XCTAssertEqual(sha(eot(style, lang)), goldEOT["\(style.rawValue) nil"], "eot \(style) \(lang ?? "nil")")
            }
            for lang in ["ca", "es"] {
                XCTAssertEqual(sha(prompt(style, lang)), goldPrompt["\(style.rawValue) \(lang)"], "prompt \(style) \(lang)")
                XCTAssertEqual(sha(eot(style, lang)), goldEOT["\(style.rawValue) \(lang)"], "eot \(style) \(lang)")
            }
        }
    }

    /// Literal instruction text for the two hand-written languages (as on main).
    func testCatalanAndSpanishInstructionTextUnchanged() {
        XCTAssertEqual(Prompt.languageInstruction(for: "ca"),
            "Escriu les notes en català; mantén els encapçalaments de secció en anglès. Conserva textualment, en la llengua parlada, els fragments citats.")
        XCTAssertEqual(Prompt.languageInstruction(for: "es"),
            "Escribe las notas en español; mantén los encabezados de sección en inglés. Conserva textualmente, en el idioma hablado, los fragmentos citados.")
        XCTAssertNil(Prompt.languageInstruction(for: nil))
        XCTAssertNil(Prompt.languageInstruction(for: "en"))
        XCTAssertNil(Prompt.languageInstruction(for: "xx"))
        XCTAssertNil(Prompt.languageInstruction(for: "auto"))
    }

    // MARK: Generic language

    func testFrenchPromptNamesFrenchAndKeepsEnglishHeadings() {
        for style in [Prompt.Style.classic, .factsFirst] {
            let p = prompt(style, "fr")
            XCTAssertTrue(p.contains("Write the notes in French; keep the section headings in English."), "\(style)")
            XCTAssertTrue(p.contains("Keep quoted excerpts verbatim, in the language actually spoken."))
            XCTAssertFalse(p.contains("Use British English."), "the English rule is replaced")
            XCTAssertNotEqual(sha(p), goldPrompt["\(style.rawValue) nil"])
            // Everything but that one rule is shared with the English prompt.
            let english = prompt(style, nil)
            let swapped = english.replacingOccurrences(
                of: "Use British English.", with: Prompt.languageInstruction(for: "fr")!)
            XCTAssertEqual(p, swapped)
        }
    }

    func testGenericInstructionNamesAnyCatalogLanguage() {
        XCTAssertTrue(Prompt.languageInstruction(for: "de")!.contains("in German;"))
        XCTAssertTrue(Prompt.languageInstruction(for: "ja")!.contains("in Japanese;"))
        XCTAssertTrue(Prompt.languageInstruction(for: "cy")!.contains("in Welsh;"))
    }

    func testFrenchEndOfTurnBlockIsEnglishWordedWithFrenchRule() {
        for style in [Prompt.Style.classic, .factsFirst] {
            let b = eot(style, "fr")
            XCTAssertTrue(b.hasPrefix("FINAL REMINDER: write ALL the prose of the notes in FRENCH (not English); "), b)
            XCTAssertTrue(b.contains("section headings stay in English"))
            XCTAssertTrue(b.contains("use exactly the \(SummaryPostProcess.requiredHeadings(for: style).count) section headings"))
            XCTAssertTrue(b.contains("SPEAKER ROLES (authoritative): SPEAKER_00 IS Marc"))
            // The tail is the English block's tail, untouched.
            XCTAssertTrue(b.hasSuffix(eot(style, nil).components(separatedBy: "Output nothing after the last section").last!))
        }
    }

    // MARK: Resolver

    func testResolveSettingAndOverride() {
        // "en" (and unknown / empty) -> nil whatever was detected.
        XCTAssertNil(NoteLanguage.resolve(setting: "en", perRecording: nil, detected: "fr"))
        XCTAssertNil(NoteLanguage.resolve(setting: "bogus", perRecording: nil, detected: "fr"))
        XCTAssertNil(NoteLanguage.resolve(setting: "", perRecording: nil, detected: "fr"))
        // "auto" follows detection; English / unknown / no detection -> nil.
        XCTAssertEqual(NoteLanguage.resolve(setting: "auto", perRecording: nil, detected: "fr"), "fr")
        XCTAssertEqual(NoteLanguage.resolve(setting: "auto", perRecording: nil, detected: "ca"), "ca")
        XCTAssertNil(NoteLanguage.resolve(setting: "auto", perRecording: nil, detected: "en"))
        XCTAssertNil(NoteLanguage.resolve(setting: "auto", perRecording: nil, detected: nil))
        XCTAssertNil(NoteLanguage.resolve(setting: "auto", perRecording: nil, detected: "zz"))
        // A fixed code ignores detection.
        XCTAssertEqual(NoteLanguage.resolve(setting: "es", perRecording: nil, detected: "fr"), "es")
        XCTAssertEqual(NoteLanguage.resolve(setting: "es", perRecording: nil, detected: nil), "es")
        // The per-recording value wins, including "en" and "auto".
        XCTAssertEqual(NoteLanguage.resolve(setting: "en", perRecording: "de", detected: "fr"), "de")
        XCTAssertNil(NoteLanguage.resolve(setting: "fr", perRecording: "en", detected: "fr"))
        XCTAssertEqual(NoteLanguage.resolve(setting: "en", perRecording: "auto", detected: "fr"), "fr")
        XCTAssertEqual(NoteLanguage.resolve(setting: "fr", perRecording: "", detected: nil), "fr")
    }

    func testIsValidChoice() {
        for ok in ["auto", "en", "fr", "ca", "yue"] { XCTAssertTrue(NoteLanguage.isValidChoice(ok), ok) }
        for bad in ["", "xx", "French", "AUTO"] { XCTAssertFalse(NoteLanguage.isValidChoice(bad), bad) }
    }
}
