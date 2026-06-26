import XCTest
@testable import SeshatCore

final class WhisperXClientTests: XCTestCase {

    func testTranscribeBuildsRequestAndParsesResult() async throws {
        let tmpWav = FileManager.default.temporaryDirectory
            .appendingPathComponent("seshat-\(UUID().uuidString).wav")
        try Data([0, 1, 2, 3]).write(to: tmpWav)
        defer { try? FileManager.default.removeItem(at: tmpWav) }

        let session = MockURLProtocol.session { req in
            XCTAssertEqual(req.url?.path, "/asr")
            XCTAssertEqual(req.httpMethod, "POST")
            let query = req.url?.query ?? ""
            XCTAssertTrue(query.contains("model=medium"))
            XCTAssertTrue(query.contains("output_format=json"))
            XCTAssertTrue(query.contains("diarize=true"))
            XCTAssertTrue(query.contains("num_speakers=2"))
            let contentType = req.value(forHTTPHeaderField: "Content-Type") ?? ""
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
            return try MockURLProtocol.ok(req.url!, json: [
                "segments": [["speaker": "SPEAKER_00", "text": "hi"]],
            ])
        }

        var cfg = TranscribeConfig()
        cfg.whisperxURL = "http://host:9000/"
        let result = try await WhisperXClient(session: session).transcribe(wavURL: tmpWav, config: cfg)
        let segments = TranscriptCleaner.segments(from: result)
        XCTAssertEqual(segments.first?.text, "hi")
    }

    func testMultipartBodyShape() {
        let body = WhisperXClient.multipartBody(
            boundary: "B", fieldName: "audio_file", filename: "x.wav",
            mimeType: "audio/wav", fileData: Data("DATA".utf8))
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("--B\r\n"))
        XCTAssertTrue(text.contains("name=\"audio_file\"; filename=\"x.wav\""))
        XCTAssertTrue(text.contains("Content-Type: audio/wav"))
        XCTAssertTrue(text.contains("DATA"))
        XCTAssertTrue(text.hasSuffix("--B--\r\n"))
    }
}
