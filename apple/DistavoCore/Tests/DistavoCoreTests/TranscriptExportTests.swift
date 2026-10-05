import XCTest
import PDFKit
@testable import DistavoCore

/// Vikunja #2943: the segments sidecar and every export format.
final class TranscriptExportTests: XCTestCase {

    private typealias W = TranscriptSegments.Word
    private typealias S = TranscriptSegments.Segment

    private func sample() -> TranscriptSegments {
        TranscriptSegments(segments: [
            S(start: 0.0, end: 2.5, text: "Hello there.", speaker: "SPEAKER_00",
              words: [W(word: "Hello", start: 0.0, end: 0.9), W(word: "there.", start: 1.0, end: 2.5)]),
            S(start: 3661.5, end: 3664.25, text: "R&D <b>rocks</b> & \"quotes\"", speaker: "SPEAKER_01"),
            S(start: 4000, end: 4001, text: "No speaker here"),
        ])
    }

    // MARK: Building + persistence

    func testBuildFromWhisperXResultKeepsSpeakersAndWords() throws {
        let result: [String: Any] = ["segments": [
            ["text": " Hi all ", "start": 0.0, "end": 1.5, "speaker": "SPEAKER_00",
             "words": [["word": " Hi", "start": 0.0, "end": 0.5], ["word": "all", "start": 0.6, "end": 1.5]]],
            ["text": "untimed", "speaker": "SPEAKER_01"],               // dropped: no times
            ["text": "   ", "start": 2.0, "end": 3.0],                  // dropped: blank
            ["text": "Bye", "start": 2.0, "end": 3.0, "speaker": "SPEAKER_UNKNOWN"],
        ]]
        let t = try XCTUnwrap(TranscriptSegments(whisperXResult: result))
        XCTAssertEqual(t.segments.count, 2)
        XCTAssertEqual(t.segments[0].text, "Hi all")
        XCTAssertEqual(t.segments[0].speaker, "SPEAKER_00")
        XCTAssertEqual(t.segments[0].words?.map(\.word), ["Hi", "all"])
        XCTAssertNil(t.segments[1].speaker, "SPEAKER_UNKNOWN is stored as no speaker")
        XCTAssertNil(t.segments[1].words)
        XCTAssertEqual(t.version, 1)
    }

    func testNoTimedSegmentsMeansNoSidecar() {
        XCTAssertNil(TranscriptSegments(whisperXResult: ["text": "just text"]))
        XCTAssertNil(TranscriptSegments(whisperXResult: ["segments": [["text": "x"]]]))
    }

    func testSaveLoadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(TranscriptSegments.load(workDir: dir, base: "m"))
        try sample().save(workDir: dir, base: "m@bsc-ca")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("m@bsc-ca.segments.json").path))
        XCTAssertEqual(TranscriptSegments.load(workDir: dir, base: "m@bsc-ca"), sample())
    }

    func testJSONExportRoundTripsSegmentsAndSpeakers() throws {
        let data = try TranscriptExportFormat.json.render(sample(), title: "T")
        XCTAssertEqual(try JSONDecoder().decode(TranscriptSegments.self, from: data), sample())
    }

    // MARK: SRT / VTT

    func testTimestampFormatting() {
        XCTAssertEqual(TimeFormat.clock(3661.5, separator: ","), "01:01:01,500")
        XCTAssertEqual(TimeFormat.clock(0.9996, separator: "."), "00:00:01.000")   // no ".1000"
        XCTAssertEqual(TimeFormat.clock(-1, separator: ","), "00:00:00,000")
        XCTAssertEqual(TimeFormat.label(65), "1:05")
        XCTAssertEqual(TimeFormat.label(3661), "1:01:01")
    }

    func testSRTCueNumberingAndTimesMatchSegments() {
        let srt = SubtitleExport.srt(sample())
        let blocks = srt.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        XCTAssertEqual(blocks.count, 3)
        XCTAssertTrue(blocks[0].hasPrefix("1\n00:00:00,000 --> 00:00:02,500\nSPEAKER_00: Hello there."))
        XCTAssertTrue(blocks[1].hasPrefix("2\n01:01:01,500 --> 01:01:04,250\n"))
        XCTAssertTrue(blocks[2].hasPrefix("3\n01:06:40,000 --> 01:06:41,000\nNo speaker here"))
        XCTAssertTrue(srt.hasSuffix("\n\n"))
    }

    func testVTTHeaderVoiceTagsAndEscaping() {
        let vtt = SubtitleExport.vtt(sample())
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n1\n00:00:00.000 --> 00:00:02.500\n<v SPEAKER_00>Hello there.</v>"))
        XCTAssertTrue(vtt.contains("<v SPEAKER_01>R&amp;D &lt;b&gt;rocks&lt;/b&gt; &amp;"))
        XCTAssertTrue(vtt.contains("\nNo speaker here\n"), "no voice tag without a speaker")
    }

    func testCueTimesStayWithinHalfASecondOfSegmentsEvenWhenSplit() {
        // A 20 s monologue with words every 0.5 s must split, and every cue's
        // times must be exactly its words' times, hence inside the segment.
        let words = (0..<40).map { W(word: "word\($0)", start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.4) }
        let seg = S(start: 0, end: 19.9, text: words.map(\.word).joined(separator: " "), speaker: "SPEAKER_00", words: words)
        let cues = SubtitleExport.cues(TranscriptSegments(segments: [seg]))
        XCTAssertGreaterThan(cues.count, 2, "long segment is split by words")
        for cue in cues {
            XCTAssertLessThanOrEqual(cue.end - cue.start, SubtitleExport.maxCueSeconds + 0.001)
            XCTAssertLessThanOrEqual(cue.text.count, SubtitleExport.maxCueChars)
            XCTAssertGreaterThanOrEqual(cue.start, seg.start - 0.5)
            XCTAssertLessThanOrEqual(cue.end, seg.end + 0.5)
        }
        XCTAssertEqual(cues.first?.start, 0)
        XCTAssertEqual(cues.last?.end ?? 0, 19.9, accuracy: 0.5)
        // No word is lost or duplicated.
        XCTAssertEqual(cues.map(\.text).joined(separator: " "), seg.text)
        // Cues are in order and do not overlap.
        for (a, b) in zip(cues, cues.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start) }
    }

    func testLongSegmentWithoutWordsIsNotSplitOrInvented() {
        let seg = S(start: 0, end: 30, text: String(repeating: "lorem ipsum ", count: 20))
        XCTAssertEqual(SubtitleExport.cues(TranscriptSegments(segments: [seg])).count, 1)
    }

    func testZeroLengthCueGetsAMinimumDuration() {
        let cues = SubtitleExport.cues(TranscriptSegments(segments: [S(start: 5, end: 5, text: "x")]))
        XCTAssertEqual(cues[0].end, 5.4, accuracy: 0.001)
    }

    // MARK: HTML

    func testHTMLEscapesAndLabelsSpeakers() {
        let html = TranscriptDocument.html(sample(), title: "A <Meeting> & more")
        XCTAssertTrue(html.contains("<title>A &lt;Meeting&gt; &amp; more</title>"))
        XCTAssertTrue(html.contains("R&amp;D &lt;b&gt;rocks&lt;/b&gt; &amp; &quot;quotes&quot;"))
        XCTAssertFalse(html.contains("<b>rocks</b>"))
        XCTAssertTrue(html.contains("<span class=\"speaker\">SPEAKER_00</span> <time>0:00</time>"))
        XCTAssertTrue(html.contains("<time>1:01:01</time>"))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("http"), "self-contained: no external references")
    }

    func testTurnsMergeConsecutiveSameSpeaker() {
        let t = TranscriptSegments(segments: [
            S(start: 0, end: 1, text: "a", speaker: "A"), S(start: 1, end: 2, text: "b", speaker: "A"),
            S(start: 2, end: 3, text: "c", speaker: "B"),
        ])
        let turns = TranscriptTurn.group(t)
        XCTAssertEqual(turns.map(\.text), ["a b", "c"])
        XCTAssertEqual(turns.map(\.speaker), ["A", "B"])
    }

    // MARK: ZIP / DOCX

    func testCRC32KnownVector() {
        XCTAssertEqual(StoredZipWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(StoredZipWriter.crc32(Data()), 0)
    }

    func testDocxIsAValidZipWithSpeakerLabels() throws {
        let data = TranscriptDocument.docx(sample(), title: "Weekly <sync>")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).docx")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        // `unzip -t` verifies every CRC and the directory structure.
        let test = try run("/usr/bin/unzip", ["-t", file.path])
        XCTAssertEqual(test.status, 0, test.output)
        XCTAssertTrue(test.output.contains("No errors detected"), test.output)

        let listing = try run("/usr/bin/unzip", ["-Z1", file.path]).output
        XCTAssertEqual(listing.split(separator: "\n").map(String.init),
                       ["[Content_Types].xml", "_rels/.rels", "word/document.xml"])

        let xml = try run("/usr/bin/unzip", ["-p", file.path, "word/document.xml"]).output
        XCTAssertTrue(xml.contains("SPEAKER_00"))
        XCTAssertTrue(xml.contains("SPEAKER_01"))
        XCTAssertTrue(xml.contains("<w:rPr><w:b/></w:rPr><w:t xml:space=\"preserve\">SPEAKER_00"), "labels are bold")
        XCTAssertTrue(xml.contains("Weekly &lt;sync&gt;"))
        XCTAssertTrue(xml.contains("R&amp;D &lt;b&gt;rocks"))
        // Well-formed XML (a parse error here is what makes Word say "unreadable content").
        let parser = XMLParser(data: Data(xml.utf8))
        XCTAssertTrue(parser.parse(), "document.xml must be well-formed: \(String(describing: parser.parserError))")
    }

    func testDocxStripsIllegalXMLControlCharacters() throws {
        let t = TranscriptSegments(segments: [S(start: 0, end: 1, text: "bad\u{0001}char", speaker: "A")])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("c-\(UUID().uuidString).docx")
        try TranscriptDocument.docx(t, title: "x").write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let xml = try run("/usr/bin/unzip", ["-p", file.path, "word/document.xml"]).output
        XCTAssertTrue(xml.contains("badchar"))
        XCTAssertTrue(XMLParser(data: Data(xml.utf8)).parse())
    }

    // MARK: PDF

    func testPDFParsesAndCarriesSpeakerLabels() throws {
        let data = TranscriptPDF.render(sample(), title: "Weekly sync")
        XCTAssertTrue(data.starts(with: Data("%PDF-".utf8)))
        let doc = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThanOrEqual(doc.pageCount, 1)
        let text = doc.string ?? ""
        XCTAssertTrue(text.contains("Weekly sync"))
        XCTAssertTrue(text.contains("SPEAKER_00"))
        XCTAssertTrue(text.contains("SPEAKER_01"))
        XCTAssertTrue(text.contains("Hello there."))
    }

    func testPDFPaginatesLongTranscripts() throws {
        let segs = (0..<400).map {
            S(start: Double($0), end: Double($0) + 1, text: "This is sentence number \($0) of a long meeting.",
              speaker: $0 % 2 == 0 ? "SPEAKER_00" : "SPEAKER_01")
        }
        let doc = try XCTUnwrap(PDFDocument(data: TranscriptPDF.render(TranscriptSegments(segments: segs), title: "Long")))
        XCTAssertGreaterThan(doc.pageCount, 3)
        XCTAssertTrue((doc.string ?? "").contains("sentence number 399"), "last segment reaches the last page")
    }

    func testEveryFormatRendersNonEmpty() throws {
        for format in TranscriptExportFormat.allCases {
            XCTAssertFalse(try format.render(sample(), title: "T").isEmpty, "\(format)")
        }
    }

    private func run(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
