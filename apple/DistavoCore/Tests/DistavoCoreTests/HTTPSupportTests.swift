import XCTest
@testable import DistavoCore

/// HTTPSupport.swift holds the two helpers shared by the Ollama / WhisperX clients:
/// URL slash trimming and the Ollama `options` payload. The failure-mode tests at the end drive them through
/// WhisperXClient with MockURLProtocol (non-2xx, empty body, timeout, reachability).
final class HTTPSupportTests: XCTestCase {

    func testTrimmedTrailingSlashesRemovesEveryTrailingSlash() {
        XCTAssertEqual("http://host:11434/".trimmedTrailingSlashes(), "http://host:11434")
        XCTAssertEqual("http://host///".trimmedTrailingSlashes(), "http://host")
    }

    func testTrimmedTrailingSlashesLeavesInnerAndAbsentSlashes() {
        XCTAssertEqual("http://host/api".trimmedTrailingSlashes(), "http://host/api")
        XCTAssertEqual("".trimmedTrailingSlashes(), "")
        XCTAssertEqual("///".trimmedTrailingSlashes(), "")
    }

    func testOptionsPayloadUsesOllamaSnakeCaseKeys() {
        let p = SummariseOptions().asPayload
        XCTAssertEqual(Set(p.keys), ["num_ctx", "temperature", "top_p", "seed",
                                     "num_predict", "repeat_penalty", "repeat_last_n"])
    }

    func testOptionsPayloadCarriesTheConfiguredValues() {
        let o = SummariseOptions(numCtx: 8192, temperature: 0.3, topP: 0.9, seed: 7,
                                 numPredict: 100, repeatPenalty: 1.2, repeatLastN: 64)
        let p = o.asPayload
        XCTAssertEqual(p["num_ctx"] as? Int, 8192)
        XCTAssertEqual(p["temperature"] as? Double, 0.3)
        XCTAssertEqual(p["top_p"] as? Double, 0.9)
        XCTAssertEqual(p["seed"] as? Int, 7)
        XCTAssertEqual(p["num_predict"] as? Int, 100)
        XCTAssertEqual(p["repeat_penalty"] as? Double, 1.2)
        XCTAssertEqual(p["repeat_last_n"] as? Int, 64)
    }

    func testOptionsPayloadIsJSONSerialisable() throws {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(SummariseOptions().asPayload))
    }

    // MARK: shared-HTTP failure modes through WhisperXClient (MockURLProtocol)

    private func tempWav() throws -> URL {
        let u = TestTemp.root.appendingPathComponent("distavo-\(UUID().uuidString).wav")
        try Data([0, 1, 2, 3]).write(to: u)
        return u
    }

    private func failure(_ session: URLSession) async -> String? {
        let wav = try! tempWav()
        defer { try? FileManager.default.removeItem(at: wav) }
        do {
            _ = try await WhisperXClient(session: session).transcribe(wavURL: wav, config: TranscribeConfig())
            return nil
        } catch {
            return (error as? WhisperXError)?.message ?? "\(error)"
        }
    }

    func testNon2xxIsReportedWithItsStatus() async {
        let s = MockURLProtocol.session { req in try MockURLProtocol.ok(req.url!, json: [:], status: 503) }
        let msg = await failure(s)
        XCTAssertEqual(msg, "WhisperX request failed: HTTP 503")
    }

    func testEmptyBodyIsNotAnObject() async {
        let s = MockURLProtocol.session { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let msg = await failure(s)
        XCTAssertEqual(msg, "WhisperX returned non-object JSON")
    }

    func testJSONArrayBodyIsNotAnObject() async {
        let s = MockURLProtocol.session { req in try MockURLProtocol.ok(req.url!, json: [1, 2]) }
        let msg = await failure(s)
        XCTAssertEqual(msg, "WhisperX returned non-object JSON")
    }

    func testTimeoutBecomesAWhisperXError() async {
        let s = MockURLProtocol.session { _ in throw URLError(.timedOut) }
        let msg = await failure(s)
        XCTAssertNotNil(msg)
        XCTAssertFalse(msg!.isEmpty)
    }

    func testReachableOnlyOn200() async {
        let ok = MockURLProtocol.session { req in try MockURLProtocol.ok(req.url!, json: [:]) }
        let reachable200 = await WhisperXClient(session: ok).reachable("http://h:9000/")
        XCTAssertTrue(reachable200)
        let bad = MockURLProtocol.session { req in try MockURLProtocol.ok(req.url!, json: [:], status: 500) }
        let reachable500 = await WhisperXClient(session: bad).reachable("http://h:9000")
        XCTAssertFalse(reachable500)
        let down = MockURLProtocol.session { _ in throw URLError(.cannotConnectToHost) }
        let reachableDown = await WhisperXClient(session: down).reachable("http://h:9000")
        XCTAssertFalse(reachableDown)
    }
}
