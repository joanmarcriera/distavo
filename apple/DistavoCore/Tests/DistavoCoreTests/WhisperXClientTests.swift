import XCTest
@testable import DistavoCore

final class WhisperXClientTests: XCTestCase {

    func testTranscribeBuildsRequestAndParsesResult() async throws {
        let tmpWav = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-\(UUID().uuidString).wav")
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

    /// "auto" is DistavoCore's own router sentinel (spec §5.2) — the WhisperX
    /// server has no such concept, so it must never see it as a literal
    /// language value. It must be mapped to "" instead, same as an already-
    /// empty language value.
    func testAutoLanguageIsSentAsEmptyToWhisperX() async throws {
        let tmpWav = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-\(UUID().uuidString).wav")
        try Data([0, 1, 2, 3]).write(to: tmpWav)
        defer { try? FileManager.default.removeItem(at: tmpWav) }

        let session = MockURLProtocol.session { req in
            let query = req.url?.query ?? ""
            XCTAssertTrue(query.contains("language="), "expected an empty language= param, got \(query)")
            XCTAssertFalse(query.contains("language=auto"), "must never leak the router's auto sentinel, got \(query)")
            return try MockURLProtocol.ok(req.url!, json: ["segments": [[String: Any]]()])
        }

        var cfg = TranscribeConfig()
        cfg.whisperxURL = "http://host:9000/"
        cfg.language = "auto"
        _ = try await WhisperXClient(session: session).transcribe(wavURL: tmpWav, config: cfg)
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
