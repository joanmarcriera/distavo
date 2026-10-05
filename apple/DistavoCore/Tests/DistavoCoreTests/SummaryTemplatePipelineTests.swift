import XCTest
@testable import DistavoCore

/// End to end through `Pipeline.processOne` with fakes (Vikunja #2940): two
/// subfolders of the recordings dir with different templates produce different
/// prompts and differently shaped notes; the per-recording sidecar wins; no
/// template leaves the stock prompt.
final class SummaryTemplatePipelineTests: XCTestCase {

    private final class Prompts: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private struct Env { var config: Config; var recordings: URL; var work: URL; var notes: URL }

    private func makeEnv() throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-tplpipe-\(UUID().uuidString)")
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        return Env(config: cfg, recordings: rec, work: root.appendingPathComponent("work"),
                   notes: root.appendingPathComponent("notes"))
    }

    private func recording(_ env: Env, _ relative: String) throws -> URL {
        let url = env.recordings.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: url)
        return url
    }

    /// A model stand-in that writes whatever headings its prompt asked for, so the
    /// note's shape follows the template and still passes the validator.
    private func deps(_ prompts: Prompts) -> PipelineDeps {
        PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in ["segments": [["speaker": "SPEAKER_00", "text": "hello world"]]] },
            ollamaReachable: { _ in true },
            summarise: { transcript, _, _, context in
                let p = context.prompt(transcript: transcript)
                prompts.add(p)
                let section = p.components(separatedBy: "Return the output in Markdown using exactly these sections:")
                    .last?.components(separatedBy: "Transcript:").first ?? ""
                let headings = section.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
                let filler = "This section holds real content about the meeting, long enough to count as a full sentence of words."
                return "# Meeting notes\n\n" + headings.map { "\($0)\n\(filler)\n" }.joined(separator: "\n")
            },
            audioDurationSeconds: { _ in nil })
    }

    private func note(_ env: Env, _ base: String) throws -> String {
        try String(contentsOf: env.notes.appendingPathComponent("\(base).md"), encoding: .utf8)
    }

    func testTwoFoldersWithDifferentTemplatesYieldDifferentlyShapedNotes() async throws {
        var env = try makeEnv()
        env.config.summarise.template = "lecture"
        env.config.summarise.folderTemplates = ["Sales": "sales_call", "Standups": "standup"]
        let sales = try recording(env, "Sales/call.opus")
        let stand = try recording(env, "Standups/mon.opus")
        let other = try recording(env, "misc.opus")

        let prompts = Prompts()
        for url in [sales, stand, other] {
            let r = await Pipeline.processOne(path: url, config: env.config, deps: deps(prompts),
                                              stableChecks: 1, stableDelay: 0)
            XCTAssertEqual(r.status, .done, r.message)
        }
        let salesNote = try note(env, "Sales__call")
        let standNote = try note(env, "Standups__mon")
        let otherNote = try note(env, "misc")
        XCTAssertTrue(salesNote.contains("## Needs and pain points"))
        XCTAssertFalse(salesNote.contains("## Blockers"))
        XCTAssertTrue(standNote.contains("## Blockers"))
        XCTAssertFalse(standNote.contains("## Needs and pain points"))
        XCTAssertTrue(otherNote.contains("## Key concepts"))          // global setting
        XCTAssertNotEqual(salesNote, standNote)
        XCTAssertEqual(prompts.all.count, 3)
    }

    func testPerRecordingSidecarBeatsTheFolderAndNoTemplateIsStock() async throws {
        var env = try makeEnv()
        env.config.summarise.folderTemplates = ["Sales": "sales_call"]
        let call = try recording(env, "Sales/call.opus")
        try LanguageOverride(template: "interview").save(workDir: env.work, base: "Sales__call")
        let plain = try recording(env, "plain.opus")

        let prompts = Prompts()
        for url in [call, plain] {
            let r = await Pipeline.processOne(path: url, config: env.config, deps: deps(prompts),
                                              stableChecks: 1, stableDelay: 0)
            XCTAssertEqual(r.status, .done, r.message)
        }
        XCTAssertTrue(try note(env, "Sales__call").contains("## Technical assessment"))   // interview, not sales
        // No template anywhere: the prompt is exactly the stock classic one.
        let stock = Prompt.build(transcript: "[SPEAKER_00]\nhello world", noteOwner: env.config.noteOwner,
                                 userSpeaker: env.config.userSpeaker, style: env.config.summarise.promptStyle)
        XCTAssertEqual(prompts.all.last, stock)
    }

    func testUnknownTemplateNeverFailsARecording() async throws {
        var env = try makeEnv()
        env.config.summarise.template = "no-such-template"
        let url = try recording(env, "a.opus")
        let prompts = Prompts()
        let r = await Pipeline.processOne(path: url, config: env.config, deps: deps(prompts),
                                          stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertTrue(try note(env, "a").contains("## Technical scope"))   // stock headings
    }
}
