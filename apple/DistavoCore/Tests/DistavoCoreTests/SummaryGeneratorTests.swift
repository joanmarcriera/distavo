import XCTest
@testable import DistavoCore

/// Failure and edge behaviour of the engine-agnostic driver (the parity cases are in SummaryDriverTests).
final class SummaryGeneratorTests: XCTestCase {

    private struct Boom: Error, Equatable {}

    private final class Fake: SummaryGenerator, @unchecked Sendable {
        let contextSize: Int
        let reply: @Sendable (String) throws -> String
        private let lock = NSLock()
        private var _calls = 0
        init(contextSize: Int, reply: @escaping @Sendable (String) throws -> String = { _ in "# Meeting notes\nok" }) {
            self.contextSize = contextSize; self.reply = reply
        }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        func tokenCount(_ text: String) async -> Int? { nil }
        func generate(_ prompt: String, maxOutputTokens: Int) async throws -> String {
            lock.lock(); _calls += 1; lock.unlock()
            return try reply(prompt)
        }
    }

    private func request(_ text: String) -> SummaryRequest {
        SummaryRequest(transcript: text, noteOwner: "Marc", userSpeaker: "SPEAKER_00")
    }

    func testEngineErrorsPropagateUntouched() async {
        let gen = Fake(contextSize: 4096) { _ in throw Boom() }
        do {
            _ = try await SummaryDriver.run(request("SPEAKER_00: hi"), generator: gen)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? Boom, Boom())
        }
        XCTAssertEqual(gen.calls, 1)
    }

    func testAWindowTooSmallForTheInstructionsThrowsBeforeAnyGeneration() async {
        let gen = Fake(contextSize: 16)
        do {
            _ = try await SummaryDriver.run(request("SPEAKER_00: hi"), generator: gen)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? SummaryDriverError, .contextTooSmall)
        }
        XCTAssertEqual(gen.calls, 0)
    }

    func testSinglePassReportsProgressOnceAndMakesOneCall() async throws {
        final class Box: @unchecked Sendable { var msgs: [String] = []; let l = NSLock() }
        let box = Box()
        let gen = Fake(contextSize: 65536)
        let out = try await SummaryDriver.run(request("SPEAKER_00: hi"), generator: gen) { m in
            box.l.lock(); box.msgs.append(m); box.l.unlock()
        }
        XCTAssertEqual(out, "# Meeting notes\nok")
        XCTAssertEqual(gen.calls, 1)
        XCTAssertEqual(box.msgs, ["Summarising on this Mac\u{2026}"])
    }

    func testMapReduceMakesOneCallPerPartPlusTheFinalNote() async throws {
        let long = (0..<1500).map { "SPEAKER_0\($0 % 2): Point \($0) about the migration timeline and budget." }
            .joined(separator: "\n")
        let gen = Fake(contextSize: 4096) { p in
            p.hasPrefix("You are reading ONE PART") ? "Key points:\n- a" : "# Meeting notes\nfinal"
        }
        let out = try await SummaryDriver.run(request(long), generator: gen)
        XCTAssertEqual(out, "# Meeting notes\nfinal")
        XCTAssertGreaterThan(gen.calls, 2)
    }

    func testAMapPartFailureAbortsTheRun() async {
        let long = (0..<1500).map { "SPEAKER_0\($0 % 2): Point \($0) about the migration timeline and budget." }
            .joined(separator: "\n")
        let gen = Fake(contextSize: 4096) { _ in throw Boom() }
        do {
            _ = try await SummaryDriver.run(request(long), generator: gen)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? Boom, Boom())
        }
        XCTAssertEqual(gen.calls, 1)
    }
}
