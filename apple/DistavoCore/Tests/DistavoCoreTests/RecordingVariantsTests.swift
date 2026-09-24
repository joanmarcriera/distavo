import XCTest
@testable import DistavoCore

/// Vikunja #2201: sibling-discovery for the "Compare two models" window.
final class RecordingVariantsTests: XCTestCase {
    private func tempDirs() -> (notes: URL, work: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-variants-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes")
        let work = root.appendingPathComponent("work")
        try? FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (notes, work)
    }

    private func touch(_ url: URL, _ text: String = "x") {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testNoNotesReturnsEmpty() {
        let (notes, work) = tempDirs()
        XCTAssertEqual(RecordingVariants.list(base: "demo", notesDir: notes, workDir: work), [])
    }

    func testAutomaticOnlyListsOneEntryWithNilModelAndLanguage() {
        let (notes, work) = tempDirs()
        touch(notes.appendingPathComponent("demo.md"))
        touch(work.appendingPathComponent("demo.transcript.clean.txt"))
        let result = RecordingVariants.list(base: "demo", notesDir: notes, workDir: work)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].label, "Automatic")
        XCTAssertNil(result[0].modelLabel)
        XCTAssertNil(result[0].languageCode)
        XCTAssertEqual(result[0].transcriptPath?.lastPathComponent, "demo.transcript.clean.txt")
    }

    /// The automatic run is skipped when its note isn't there yet (still
    /// processing / never run), but variants beside it still show up.
    func testMissingAutomaticNoteIsSkippedButVariantsStillListed() {
        let (notes, work) = tempDirs()
        touch(notes.appendingPathComponent("demo@bsc-los-ca.md"))
        let result = RecordingVariants.list(base: "demo", notesDir: notes, workDir: work)
        XCTAssertEqual(result.map(\.label), ["bsc-los-ca"])
    }

    func testVariantTranscriptMissingIsNilNotCrash() {
        let (notes, work) = tempDirs()
        touch(notes.appendingPathComponent("demo@small-en.md"))
        let result = RecordingVariants.list(base: "demo", notesDir: notes, workDir: work)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].transcriptPath)
    }

    /// Two recordings that share a prefix ("demo" / "demo-extra") must not
    /// bleed into each other's variant list.
    func testDoesNotMatchAnUnrelatedRecordingWithASharedPrefix() {
        let (notes, work) = tempDirs()
        touch(notes.appendingPathComponent("demo.md"))
        touch(notes.appendingPathComponent("demo-extra.md"))
        touch(notes.appendingPathComponent("demo-extra@small-en.md"))
        let result = RecordingVariants.list(base: "demo", notesDir: notes, workDir: work)
        XCTAssertEqual(result.map(\.label), ["Automatic"])
    }

    func testMultipleVariantsSortedBySuffixWithAutomaticFirst() {
        let (notes, work) = tempDirs()
        touch(notes.appendingPathComponent("demo.md"))
        touch(notes.appendingPathComponent("demo@small-en.md"))
        touch(notes.appendingPathComponent("demo@bsc-los-ca.md"))
        let result = RecordingVariants.list(base: "demo", notesDir: notes, workDir: work)
        XCTAssertEqual(result.map(\.label), ["Automatic", "bsc-los-ca", "small-en"])
    }

    // MARK: Suffix parsing

    func testParseRecognisesCatalogModelAndLanguage() {
        let (model, language) = RecordingVariants.parse(suffix: "bsc-los-ca")
        XCTAssertEqual(model, "Català · Castellà · Galego · Euskara (BSC Languages of Spain)")
        XCTAssertEqual(language, "ca")
    }

    /// A model id that itself contains "-" (large-v3-turbo) must not be
    /// mis-split at the wrong dash.
    func testParseHandlesMultiDashModelID() {
        let (model, language) = RecordingVariants.parse(suffix: "large-v3-turbo-en")
        XCTAssertEqual(model, "Best (Whisper large-v3 turbo)")
        XCTAssertEqual(language, "en")
    }

    /// "auto" (no fixed language) parses to a nil language, and the model
    /// segment is still recovered even though it isn't a catalog id (a
    /// WhisperX server size).
    func testParseAutoLanguageIsNilAndUnknownModelKeptVerbatim() {
        let (model, language) = RecordingVariants.parse(suffix: "large-v3-auto")
        XCTAssertEqual(model, "large-v3", "not a catalog id — kept as-is")
        XCTAssertNil(language)
    }

    /// Nothing after any "-" looks like a language: the whole suffix is
    /// returned as an opaque label rather than mis-parsed.
    func testParseFallsBackToWholeSuffixWhenNoLanguageRecognised() {
        let (model, language) = RecordingVariants.parse(suffix: "my-custom-tag")
        XCTAssertEqual(model, "my-custom-tag")
        XCTAssertNil(language)
    }

    func testParseSuffixWithNoDashIsKeptAsModelOnly() {
        let (model, language) = RecordingVariants.parse(suffix: "small")
        XCTAssertEqual(model, "small")
        XCTAssertNil(language)
    }
}
