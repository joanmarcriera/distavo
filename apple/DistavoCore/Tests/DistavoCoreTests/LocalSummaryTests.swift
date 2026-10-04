import XCTest
@testable import DistavoCore

/// Pure tests for the local-Gemma slice S4 (Vikunja #2198): failure policy
/// (OOM -> retryable once, then fail) and the Key-people post-process.
final class LocalSummaryTests: XCTestCase {

    // MARK: Streaming guard + retry

    private func stream(_ chunks: [String]) -> AsyncStream<String> {
        AsyncStream { c in chunks.forEach { c.yield($0) }; c.finish() }
    }

    func testCollectReturnsFullTextWhenNotLooping() async throws {
        let r = try await LoopGuard.collect(stream((1...100).map { "word\($0) " }))
        XCTAssertFalse(r.looped)
        XCTAssertTrue(r.text.hasSuffix("word100 "))
    }

    func testCollectStopsEarlyOnALoop() async throws {
        let row = "- 600 per day | SPEAKER_01 | \"six hundred a day\" | day rate\n"
        let r = try await LoopGuard.collect(stream(Array(repeating: row, count: 400)))
        XCTAssertTrue(r.looped)
        XCTAssertLessThan(r.text.count, row.count * 400, "stopped before the stream ended")
    }

    func testRetryRunsOnceHotterThenSucceeds() async throws {
        var temperatures: [Double] = []
        let out = try await LoopGuard.runWithRetry(temperature: 0.3) { t in
            temperatures.append(t)
            return temperatures.count == 1 ? ("looped", true) : ("good note", false)
        }
        XCTAssertEqual(out, "good note")
        XCTAssertEqual(temperatures.count, 2)
        XCTAssertEqual(temperatures[1], 0.5, accuracy: 1e-9)
    }

    func testRetryDoesNotRunWhenFirstAttemptIsClean() async throws {
        var calls = 0
        _ = try await LoopGuard.runWithRetry(temperature: 0.4) { _ in calls += 1; return ("ok", false) }
        XCTAssertEqual(calls, 1)
    }

    func testSecondLoopFailsWithoutThirdAttempt() async {
        var calls = 0
        do {
            _ = try await LoopGuard.runWithRetry(temperature: 0.4) { _ in calls += 1; return ("x", true) }
            XCTFail("expected a failure")
        } catch { XCTAssertTrue(error is LocalSummaryError) }
        XCTAssertEqual(calls, 2)
    }

    // MARK: Key people

    private let transcript = """
    SPEAKER_00: hola sóc el Marc
    SPEAKER_01: hola, treballo amb Leroy Merlin i fem servir chat gpt
    """

    func testDropsKeyPeopleNotInTranscript() {
        let text = """
        # Meeting notes

        ## Key people and organisations
        - Marc: note owner
        - Leroy Merlin: client
        - OpenAI: vendor of ChatGPT
        - Amazon: cloud provider

        ## Opportunity or purpose
        - OpenAI is discussed.
        """
        let out = SummaryPostProcess.dropUnsupportedKeyPeople(text, transcript: transcript)
        XCTAssertTrue(out.contains("- Marc: note owner"))
        XCTAssertTrue(out.contains("- Leroy Merlin: client"))
        XCTAssertFalse(out.contains("- OpenAI: vendor"))
        XCTAssertFalse(out.contains("- Amazon"))
        XCTAssertTrue(out.contains("- OpenAI is discussed."), "other sections untouched")
    }

    func testKeepsPlaceholdersSpeakerLabelsAndAlwaysKeepNames() {
        let text = """
        ## Key people and organisations
        - none
        - SPEAKER_01: the other party, employer not stated
        - Marc Riera (note owner)
        - Unknown Corp
        """
        let out = SummaryPostProcess.dropUnsupportedKeyPeople(text, transcript: transcript, alwaysKeep: ["Marc Riera"])
        XCTAssertTrue(out.contains("- none"))
        XCTAssertTrue(out.contains("SPEAKER_01"))
        XCTAssertTrue(out.contains("Marc Riera"))
        XCTAssertFalse(out.contains("Unknown Corp"))
    }

    private func keyPeople(_ bullets: [String], transcript t: String, extra: [String] = [],
                           keep: [String] = []) -> String {
        let text = "## Key people and organisations\n" + bullets.map { "- \($0)" }.joined(separator: "\n") + "\n"
        return SummaryPostProcess.dropUnsupportedKeyPeople(text, transcript: t, alwaysKeep: keep, extraHaystack: extra)
    }

    func testMatchingIgnoresCaseAndDiacritics() {
        let out = keyPeople(["nuria puig: recruiter", "Unknown Vidal: someone"],
                            transcript: "SPEAKER_00: parlem amb Núria Puig de la consultora")
        XCTAssertTrue(out.contains("nuria puig"))
        XCTAssertFalse(out.contains("Unknown Vidal"))
    }

    /// Only the first name was spoken: a single matching token is enough.
    func testFullNameKeptWhenOnlyFirstNameIsSpoken() {
        let out = keyPeople(["Jordi Puig: hiring manager"], transcript: "SPEAKER_01: hola, sóc en Jordi")
        XCTAssertTrue(out.contains("Jordi Puig"))
    }

    func testHonorificsAreStrippedAndDoNotCountAsMatches() {
        let t = "SPEAKER_01: the doctor said Garcia will join"
        let out = keyPeople(["Dr. Garcia: reviewer", "Sra. Ferrer: assistant", "Mr Smith: unknown", "Mrs. Jones"],
                            transcript: t)
        XCTAssertTrue(out.contains("Dr. Garcia"))
        XCTAssertFalse(out.contains("Sra. Ferrer"))
        XCTAssertFalse(out.contains("Mr Smith"))
        XCTAssertFalse(out.contains("Mrs. Jones"))
        // "Mr" in the transcript must not rescue "Mr Smith".
        XCTAssertFalse(keyPeople(["Mr Smith: x"], transcript: "SPEAKER_00: mr and mrs somebody").contains("Smith"))
    }

    func testApostrophesHyphensAndAccentsAreNormalised() {
        XCTAssertTrue(keyPeople(["O’Brien: client"], transcript: "SPEAKER_00: talk to O'Brien").contains("O’Brien"))
        XCTAssertTrue(keyPeople(["O'Brien: client"], transcript: "SPEAKER_00: talk to O’Brien").contains("O'Brien"))
        XCTAssertTrue(keyPeople(["Martínez: client"], transcript: "SPEAKER_00: ask Martinez").contains("Martínez"))
        XCTAssertTrue(keyPeople(["Martinez: client"], transcript: "SPEAKER_00: ask Martínez").contains("Martinez"))
        XCTAssertTrue(keyPeople(["Anna Garcia-Lopez: lead"], transcript: "SPEAKER_00: Anna Garcia Lopez joins").contains("Garcia-Lopez"))
        XCTAssertTrue(keyPeople(["Garcia Lopez: lead"], transcript: "SPEAKER_00: ask Garcia‐Lopez").contains("Garcia Lopez"))
    }

    /// People named in the participants description or speaker hints are real
    /// even when nobody says their name aloud.
    func testExtraHaystackAndAlwaysKeepSaveParticipants() {
        let out = keyPeople(["Ana Roca: colleague", "Pau Marti: other", "Zed Nobody: invented"],
                            transcript: "SPEAKER_00: hello", extra: ["Ana Roca and Pau Martí from the client"])
        XCTAssertTrue(out.contains("Ana Roca"))
        XCTAssertTrue(out.contains("Pau Marti"))
        XCTAssertFalse(out.contains("Zed Nobody"))
    }

    func testShortTokensAreNotEnoughToMatch() {
        // "Al" and "Bo" are under 3 letters: never a match on their own.
        XCTAssertFalse(keyPeople(["Al Bo: x"], transcript: "SPEAKER_00: al bo").contains("Al Bo"))
    }

    func testNoKeyPeopleSectionIsIdentity() {
        let text = "# Meeting notes\n\n## Context\n- OpenAI"
        XCTAssertEqual(SummaryPostProcess.dropUnsupportedKeyPeople(text, transcript: transcript), text)
    }

    func testCleanAppliesKeyPeopleFilterWhenTranscriptGiven() {
        let body = SummaryPostProcess.requiredHeadings(for: .classic)
            .map { h in h == "## Key people and organisations" ? "\(h)\n\n- Amazon: x\n- Marc: y\n" : "\(h)\n\nbody\n" }
            .joined(separator: "\n")
        let note = "# Meeting notes\n\n" + body
        let cleaned = SummaryPostProcess.clean(note, style: .classic, transcript: transcript)
        XCTAssertFalse(cleaned.contains("Amazon"))
        XCTAssertTrue(cleaned.contains("Marc: y"))
        XCTAssertTrue(SummaryPostProcess.clean(note, style: .classic).contains("Amazon"), "off without a transcript")
    }
}
