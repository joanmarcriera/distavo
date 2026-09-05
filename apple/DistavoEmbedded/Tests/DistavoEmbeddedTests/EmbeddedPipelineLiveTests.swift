import XCTest
@testable import DistavoEmbedded
import DistavoCore

/// Full on-device pipeline against a REAL recording, with an optional A/B against
/// Ollama on the same transcript. This is the field-test harness for the
/// on-device summariser (Vikunja #1781) — the gate before turning
/// `summarise.embedded_enabled` on by default.
///
/// It transcribes once and reuses that transcript for both summarisers, so the
/// comparison is like-for-like and a re-run can skip transcription entirely.
///
///   DISTAVO_PIPELINE_LIVE=1 \
///   DISTAVO_PIPELINE_AUDIO=/abs/meeting.wav \
///   DISTAVO_PIPELINE_OUT=/abs/outdir \
///   DISTAVO_PIPELINE_OLLAMA=http://127.0.0.1:11434 \
///   DISTAVO_PIPELINE_OLLAMA_MODEL=llama3.1:8b \
///   swift test --filter EmbeddedPipelineLiveTests
///
/// **Privacy:** outputs are written to `DISTAVO_PIPELINE_OUT`; the test prints
/// only metrics, never transcript or note content. Point it at a scratch dir,
/// not the repo.
final class EmbeddedPipelineLiveTests: XCTestCase {

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    func testLiveRecordingThroughBothSummarisers() async throws {
        try XCTSkipUnless(env["DISTAVO_PIPELINE_LIVE"] == "1", "set DISTAVO_PIPELINE_LIVE=1")
        guard let audioPath = env["DISTAVO_PIPELINE_AUDIO"],
              let outPath = env["DISTAVO_PIPELINE_OUT"] else {
            XCTFail("set DISTAVO_PIPELINE_AUDIO and DISTAVO_PIPELINE_OUT"); return
        }
        let outDir = URL(fileURLWithPath: outPath)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let noteOwner = env["DISTAVO_PIPELINE_OWNER"] ?? "Marc"
        let userSpeaker = env["DISTAVO_PIPELINE_SPEAKER"] ?? "unknown"

        // ── 1. Transcribe (cached: delete transcript.txt to force a re-run) ──
        let transcriptURL = outDir.appendingPathComponent("transcript.txt")
        let transcript: String
        if let cached = try? String(contentsOf: transcriptURL, encoding: .utf8), !cached.isEmpty {
            transcript = cached
            print("METRIC transcribe_seconds=cached")
        } else {
            var cfg = TranscribeConfig()
            cfg.backend = "embedded"
            cfg.diarize = env["DISTAVO_PIPELINE_DIARIZE"] != "0"
            cfg.numSpeakers = Int(env["DISTAVO_PIPELINE_SPEAKERS"] ?? "") ?? 2
            cfg.language = env["DISTAVO_PIPELINE_LANG"] ?? "en"

            let t0 = Date()
            let raw = try await EmbeddedTranscriber.shared.transcribe(
                wavURL: URL(fileURLWithPath: audioPath), config: cfg)
            let cleaned = TranscriptCleaner.clean(TranscriptCleaner.segments(from: raw))
            print("METRIC transcribe_seconds=\(Int(Date().timeIntervalSince(t0)))")
            try cleaned.write(to: transcriptURL, atomically: true, encoding: .utf8)
            transcript = cleaned
        }

        let estTokens = EmbeddedSummaryTokens.estimate(transcript)
        print("METRIC transcript_chars=\(transcript.count) est_tokens=\(estTokens) "
              + "lines=\(transcript.split(separator: "\n").count)")
        XCTAssertFalse(transcript.isEmpty, "empty transcript")

        let plan = EmbeddedSummaryPlanner.plan(
            transcript: transcript, contextSize: 4096,
            noteOwner: noteOwner, userSpeaker: userSpeaker)
        if case let .mapReduce(chunks) = plan {
            print("METRIC plan=mapReduce chunks=\(chunks.count)")
        } else {
            print("METRIC plan=single")
        }

        // ── 2. On-device summary ──
        if EmbeddedSummariser.isAvailable {
            let t1 = Date()
            let note = try await EmbeddedSummariser.summarise(
                transcript: transcript, noteOwner: noteOwner, userSpeaker: userSpeaker)
            let secs = Int(Date().timeIntervalSince(t1))
            try note.write(to: outDir.appendingPathComponent("note-embedded.md"),
                           atomically: true, encoding: .utf8)
            report(label: "embedded", note: note, seconds: secs)
        } else {
            print("METRIC embedded=unavailable reason=\(String(describing: EmbeddedSummariser.unavailableReason()))")
        }

        // ── 3. Ollama summary on the SAME transcript (optional A/B) ──
        if let url = env["DISTAVO_PIPELINE_OLLAMA"], !url.isEmpty {
            let model = env["DISTAVO_PIPELINE_OLLAMA_MODEL"] ?? "llama3.1:8b"
            let client = OllamaClient()
            guard await client.reachable(url) else {
                print("METRIC ollama=unreachable"); return
            }
            let prompt = Prompt.build(
                transcript: transcript, noteOwner: noteOwner, userSpeaker: userSpeaker)
            let t2 = Date()
            let note = try await client.generate(
                url: url, model: model, prompt: prompt, options: SummariseOptions())
            let secs = Int(Date().timeIntervalSince(t2))
            try note.write(to: outDir.appendingPathComponent("note-ollama.md"),
                           atomically: true, encoding: .utf8)
            report(label: "ollama", note: note, seconds: secs)
        }
    }

    /// Print comparable quality metrics WITHOUT revealing note content:
    /// how many of the 16 required sections are present, how many of those are
    /// substantive rather than "unclear"/"none", and how many action rows the
    /// tables actually carry.
    private func report(label: String, note: String, seconds: Int) {
        let required = [
            "Executive summary", "Context", "Key people and organisations",
            "Opportunity or purpose", "Technical scope", "Role expectations",
            "Commercial and compensation discussion", "Timeline", "Decisions made",
            "Action items", "Highest-ROI follow-up", "30-minute post-meeting plan",
            "Open questions for next call", "Risks and concerns",
            "Possible transcription corrections", "Suggested follow-up email",
        ]
        let present = required.filter { note.contains("## \($0)") }

        // Body text under each heading, to spot sections that exist but say nothing.
        var substantive = 0
        let blocks = note.components(separatedBy: "\n## ")
        for block in blocks.dropFirst() {
            let body = block.split(separator: "\n").dropFirst().joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = body.lowercased()
            if body.count > 40, !lowered.hasPrefix("unclear"), !lowered.hasPrefix("none") {
                substantive += 1
            }
        }

        // Markdown table rows that are real data, not header/separator rows.
        let tableRows = note.split(separator: "\n").filter {
            $0.hasPrefix("|") && !$0.contains("---") && !$0.contains("| Action |")
                && !$0.contains("| Priority |")
        }.count

        let failures = SummaryValidator.validate(note)
        print("METRIC \(label)_seconds=\(seconds) chars=\(note.count) "
              + "sections=\(present.count)/16 substantive=\(substantive) "
              + "table_rows=\(tableRows) validator=\(failures.isEmpty ? "clean" : failures.joined(separator: "|"))")
        if present.count < required.count {
            print("METRIC \(label)_missing_sections=\(required.filter { !present.contains($0) }.joined(separator: ","))")
        }
    }
}
