import XCTest
@testable import SeshatCore

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
