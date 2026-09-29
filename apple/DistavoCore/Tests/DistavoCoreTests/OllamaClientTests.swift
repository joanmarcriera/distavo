import XCTest
@testable import DistavoCore

final class OllamaClientTests: XCTestCase {

    func testReachableTrueOn200() async throws {
        let session = MockURLProtocol.session { req in
            XCTAssertEqual(req.url?.path, "/api/tags")
            return try MockURLProtocol.ok(req.url!, json: ["models": []])
        }
        let reachable = await OllamaClient(session: session).reachable("http://host:11434/")
        XCTAssertTrue(reachable)
    }

    func testReachableFalseOnError() async throws {
        let session = MockURLProtocol.session { req in
            try MockURLProtocol.ok(req.url!, json: [:], status: 500)
        }
        let reachable = await OllamaClient(session: session).reachable("http://host:11434")
        XCTAssertFalse(reachable)
    }

    func testGenerateParsesResponse() async throws {
        let session = MockURLProtocol.session { req in
            XCTAssertEqual(req.url?.path, "/api/generate")
            XCTAssertEqual(req.httpMethod, "POST")
            return try MockURLProtocol.ok(req.url!, json: ["response": "  # Meeting notes\n"])
        }
        let text = try await OllamaClient(session: session).generate(
            url: "http://host:11434", model: "qwen2.5:7b-instruct",
            prompt: "p", options: SummariseOptions())
        XCTAssertEqual(text, "# Meeting notes")
    }

    /// #2666: gemma4 thinks by default on Ollama and degenerates; the request must opt out.
    func testGenerateSendsThinkFalse() async throws {
        var captured: [String: Any]?
        let session = MockURLProtocol.session { req in
            // URLProtocol receives the body as a stream, not httpBody.
            var data = req.httpBody ?? Data()
            if let stream = req.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
            }
            captured = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return try MockURLProtocol.ok(req.url!, json: ["response": "ok"])
        }
        _ = try await OllamaClient(session: session).generate(
            url: "http://host:11434", model: "gemma4:26b", prompt: "p", options: SummariseOptions())
        XCTAssertEqual(captured?["think"] as? Bool, false)
    }

    func testGenerateEmptyThrows() async {
        let session = MockURLProtocol.session { req in
            try MockURLProtocol.ok(req.url!, json: ["response": "   "])
        }
        do {
            _ = try await OllamaClient(session: session).generate(
                url: "http://host:11434", model: "m", prompt: "p", options: SummariseOptions())
            XCTFail("expected throw")
        } catch let error as OllamaError {
            XCTAssertTrue(error.message.contains("empty"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
