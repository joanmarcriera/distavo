import XCTest
import AVFoundation
import DistavoCore
@testable import DistavoEmbedded

/// Headless replacement for the manual "signed Direct build" check of the local
/// Gemma summary path (Vikunja #2198): the real `Pipeline.processOne`, the real
/// `SummaryModelManager` (manifest + sha verification, opt-in, remove, discard)
/// and the real `GemmaPipelineRoute` / `MLXGemmaGenerator` on the GPU, against
/// the weights already on disk. SKIPPED unless DISTAVO_LIVE=1.
///
///   DISTAVO_LIVE=1 swift test --filter GemmaPipelineLiveTests
///
/// Inputs (all local; nothing is downloaded, nothing is committed):
///   DISTAVO_GEMMA_DIR      folder of gemma-4-e4b-it-4bit (default: the spike copy)
///   DISTAVO_GEMMA_SPIKE    spike folder holding in/en.txt and in/ca.txt prompts,
///                          whose trailing "Transcript:" is the real transcript
///                          (default ~/Development/_inbox/distavo-2198-spike)
///   DISTAVO_GEMMA_AUDIO_EN / _CA  existing recordings, READ-ONLY; the first 60 s
///                          are clipped into a temp dir (default: the two meetings
///                          in ~/Documents/Distavo/recordings the transcripts came from)
///
/// What is real: audio clip -> AVFoundation WAV conversion -> pipeline state/
/// markers/validation/note writing -> weights verification -> MLX generation.
/// What is canned: transcription (the spike's real transcripts of those two
/// meetings stand in for the transcriber, which is not under test here). All
/// folders are fresh temp dirs; the "download" copies the weights (APFS clone)
/// into the temp models folder, so the app's real models/config/work/notes are
/// never read or written. Temp copies are deleted at the end of each test.
final class GemmaPipelineLiveTests: XCTestCase {

    private let env = ProcessInfo.processInfo.environment
    private var home: String { NSHomeDirectory() }

    private func requireLive() throws -> URL {
        try XCTSkipUnless(env["DISTAVO_LIVE"] == "1", "set DISTAVO_LIVE=1 to run against real Gemma weights")
        let dir = env["DISTAVO_GEMMA_DIR"] ?? home + "/Development/_inbox/distavo-2198-spike/model"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir + "/model.safetensors"), "no weights at \(dir)")
        return URL(fileURLWithPath: dir)
    }

    private func spikeTranscript(_ lang: String) throws -> String {
        let spike = env["DISTAVO_GEMMA_SPIKE"] ?? home + "/Development/_inbox/distavo-2198-spike"
        let prompt = try String(contentsOfFile: "\(spike)/in/\(lang).txt", encoding: .utf8)
        let marker = "\nTranscript:\n"
        guard let range = prompt.range(of: marker, options: .backwards) else {
            throw XCTSkip("no transcript marker in \(spike)/in/\(lang).txt")
        }
        return String(prompt[range.upperBound...])
    }

    /// First `seconds` of an existing recording, written into `dir` (the source is only read).
    private func clip(_ path: String, seconds: Double, into dir: URL, name: String) throws -> URL {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "no recording at \(path)")
        let src = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let frames = AVAudioFrameCount(min(Double(src.length), seconds * src.processingFormat.sampleRate))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: frames))
        try src.read(into: buffer, frameCount: frames)
        let out = dir.appendingPathComponent(name)
        let dst = try AVAudioFile(forWriting: out, settings: src.fileFormat.settings)
        try dst.write(from: buffer)
        return out
    }

    /// "Download" through the manager exactly like Settings' button, wait for verification.
    private func install(_ rig: GemmaRig) async throws {
        await rig.manager.startDownload(GemmaRig.model)
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            switch await rig.manager.status(GemmaRig.model) {
            case .ready: return
            case .failed(let why): return XCTFail("install failed: \(why)")
            default: try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        XCTFail("install timed out")
    }

    /// Share of Catalan among Catalan+English function words in the note's prose
    /// (headings and table rows excluded), the spike's score.py check.
    private func catalanShare(_ note: String) -> Double {
        let ca: Set<String> = ["el", "la", "els", "les", "de", "del", "que", "amb", "per", "una", "és", "i", "en", "no", "es", "al", "però", "això", "com", "més", "molt", "sobre"]
        let en: Set<String> = ["the", "and", "of", "to", "is", "that", "with", "for", "in", "a", "it", "on", "was", "are", "this", "not"]
        var c = 0, e = 0
        for line in note.components(separatedBy: "\n") where !line.hasPrefix("#") && !line.hasPrefix("|") {
            for word in line.lowercased().components(separatedBy: CharacterSet.letters.inverted) {
                if ca.contains(word) { c += 1 } else if en.contains(word) { e += 1 }
            }
        }
        return c + e == 0 ? 0 : Double(c) / Double(c + e)
    }

    private func runMeeting(rig: GemmaRig, lang: String, audioEnv: String, audioDefault: String,
                            recordingName: String) async throws {
        let transcript = try spikeTranscript(lang)
        let segs = segments(fromBlocks: transcript)
        XCTAssertGreaterThan(segs.count, 10, "transcript did not parse")
        rig.setTranscript(segments: segs, language: lang)
        let clipDir = rig.root.appendingPathComponent("clips")
        try FileManager.default.createDirectory(at: clipDir, withIntermediateDirectories: true)
        let audio = try clip(env[audioEnv] ?? audioDefault, seconds: 60, into: clipDir, name: recordingName)
        let rec = try rig.addRecording(named: recordingName, copying: audio)

        let started = Date()
        let (result, log) = await capturingLog {
            // Real AVFoundation conversion; everything else as in the app.
            await Pipeline.processOne(path: rec, config: rig.config, deps: rig.deps(realConvert: true),
                                      stableChecks: 1, stableDelay: 0)
        }
        let seconds = Date().timeIntervalSince(started)
        XCTAssertEqual(result.status, .done, "\(result.message)")
        let notePath = try XCTUnwrap(result.notePath)
        XCTAssertTrue(notePath.path.hasPrefix(rig.notes.path), "note must land in the temp notes dir")
        let note = try String(contentsOf: notePath, encoding: .utf8)

        let required = SummaryPostProcess.requiredHeadings(for: .factsFirst)
        XCTAssertEqual(required.count, 18)
        let present = required.filter { note.components(separatedBy: "\n").contains($0) }
        XCTAssertEqual(present.count, 18, "missing: \(SummaryPostProcess.missingHeadings(in: note, style: .factsFirst))")
        XCTAssertTrue(SummaryValidator.validate(note).isEmpty, "\(SummaryValidator.validate(note))")
        XCTAssertFalse(try rig.state().isFailed(result.base))
        XCTAssertEqual(rig.ollamaChecks.value, 0, "the local model must not fall back to Ollama")

        let trace = log.first { $0.hasPrefix("Summariser") }
        XCTAssertNotNil(trace, "routing trace line missing; log: \(log)")
        XCTAssertTrue(trace?.contains("model=gemma-4-e4b") ?? false)
        XCTAssertTrue(trace?.contains("style=facts_first") ?? false, trace ?? "")
        XCTAssertTrue(trace?.contains("language=\(lang)") ?? false, "trace should show the note language: \(trace ?? "")")
        // The planner estimates ~3.3 chars/token (the real tokenizer measured 3.85), so the
        // 89-min English meeting is planned as map-reduce at the 16K cap; the 61-min Catalan one fits one pass.
        if lang == "ca" { XCTAssertTrue(trace?.contains("plan=single pass") ?? false, trace ?? "") }

        let share = catalanShare(note)
        if lang == "ca" { XCTAssertGreaterThanOrEqual(share, 0.6, "Catalan prose expected, share=\(share)") }
        else { XCTAssertLessThan(share, 0.4, "English prose expected, Catalan share=\(share)") }
        print("METRIC lang=\(lang) wall_seconds=\(String(format: "%.1f", seconds)) headings=\(present.count)/18 "
              + "note_chars=\(note.count) catalan_share=\(String(format: "%.2f", share)) status=\(result.status) trace=\(trace ?? "none")")
    }

    // MARK: (1) full pipeline on a real recording + transcript, English and Catalan

    func testPipelineWithDownloadedGemmaWritesA18HeadingNoteInEnglishAndCatalan() async throws {
        let weights = try requireLive()
        let rig = try GemmaRig(weights: weights, optedIn: false)
        let t0 = Date()
        try await install(rig)      // manifest + sha-256 verification of the 4.9 GB weights, for real
        print("METRIC install_verify_seconds=\(String(format: "%.1f", Date().timeIntervalSince(t0)))")
        XCTAssertTrue(SummaryModelStore.isVerified(GemmaRig.model, root: rig.models))
        XCTAssertEqual(rig.fetches.value, GemmaRig.model.files.count)
        try await runMeeting(rig: rig, lang: "en", audioEnv: "DISTAVO_GEMMA_AUDIO_EN",
                             audioDefault: home + "/Documents/Distavo/recordings/Meeting 2026-07-07 14.59.07.wav",
                             recordingName: "Meeting 2026-07-07 14.59.07.wav")
        try await runMeeting(rig: rig, lang: "ca", audioEnv: "DISTAVO_GEMMA_AUDIO_CA",
                             audioDefault: home + "/Documents/Distavo/recordings/Meeting 2026-07-23 10.58.50.wav",
                             recordingName: "Meeting 2026-07-23 10.58.50.wav")
        XCTAssertEqual(rig.fetches.value, GemmaRig.model.files.count, "no second download during scans")
    }

    // MARK: (3) remove, then scan: no auto re-download

    func testRemoveThenScanDoesNotRedownload() async throws {
        let weights = try requireLive()
        let rig = try GemmaRig(weights: weights, optedIn: false)
        try await install(rig)
        let fetchesAfterInstall = rig.fetches.value
        await rig.manager.remove(GemmaRig.model)
        XCTAssertFalse(SummaryModelStore.isVerified(GemmaRig.model, root: rig.models))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SummaryModelStore.directory(for: GemmaRig.model, root: rig.models).path), "weights deleted")
        let rec = try rig.addRecording(named: "Meeting 2026-07-07 14.59.07.wav")
        for _ in 0..<2 {
            let result = await rig.process(rec)
            XCTAssertEqual(result.status, .deferredNeedLocal)
            XCTAssertTrue(result.message.contains("was removed"), result.message)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(rig.fetches.value, fetchesAfterInstall, "a scan must not re-download a removed model")
        XCTAssertEqual(rig.transcribes.value, 0)
        // The explicit Download button is what brings it back.
        try await install(rig)
        XCTAssertEqual(rig.fetches.value, 2 * fetchesAfterInstall)
    }

    // MARK: (4) weights that verify but will not load: discard, retry once, then fail clearly

    func testUnloadableWeightsAreDiscardedAndRetriedOnceThenFail() async throws {
        let weights = try requireLive()
        let source = weights.appendingPathComponent("model.safetensors")
        let before = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        let rig = try GemmaRig(weights: weights, optedIn: false)
        rig.setTranscript(segments: segments(fromBlocks: try spikeTranscript("ca")), language: "ca")
        try await install(rig)
        let installFetches = rig.fetches.value
        let rec = try rig.addRecording(named: "Meeting 2026-07-23 10.58.50.wav")
        let weightsFile = SummaryModelStore.directory(for: GemmaRig.model, root: rig.models)
            .appendingPathComponent("model.safetensors")

        /// Overwrite the safetensors header length with garbage, in the TEMP clone
        /// only (after verification, so the sentinel still says "verified").
        func corrupt() throws {
            let handle = try FileHandle(forWritingTo: weightsFile)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data(repeating: 0xFF, count: 8))
        }

        // Round 1: loads fail -> weights discarded, recording DEFERS (not failed).
        try corrupt()
        var result = await rig.process(rec)
        XCTAssertEqual(result.status, .deferred, result.message)
        XCTAssertTrue(result.message.contains("download them again"), result.message)
        XCTAssertFalse(SummaryModelStore.isVerified(GemmaRig.model, root: rig.models), "bad weights must be deleted")
        XCTAssertFalse(try rig.state().isFailed(result.base), "first failure must stay retryable")
        XCTAssertEqual(rig.transcribes.value, 1)

        // Retry: the next scan fetches fresh weights (opt-in survives), recording defers meanwhile.
        result = await rig.process(rec)
        XCTAssertEqual(result.status, .deferredNeedLocal, result.message)
        try await rig.waitForDownloadToSettle(timeout: 300)
        XCTAssertEqual(rig.fetches.value, 2 * installFetches, "exactly one re-download")
        XCTAssertTrue(SummaryModelStore.isVerified(GemmaRig.model, root: rig.models))

        // Round 2: corrupt again -> failed with a clear message, and never loops.
        try corrupt()
        result = await rig.process(rec)
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.contains("unreadable twice"), result.message)
        XCTAssertTrue(result.message.contains("Apple Intelligence or Ollama"), result.message)
        XCTAssertTrue(try rig.state().isFailed(result.base))
        XCTAssertEqual(rig.transcribes.value, 2, "NOTE: the retry after a load failure re-ran transcription (open item 9)")

        // And a later scan is refused up front with the permanent explanation, no third download.
        result = await rig.process(rec)
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.contains("could not be downloaded intact"), result.message)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(rig.fetches.value, 2 * installFetches)
        XCTAssertEqual(rig.transcribes.value, 2, "refusal comes before transcription")

        let after = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "the original weights must be untouched")
    }
}
