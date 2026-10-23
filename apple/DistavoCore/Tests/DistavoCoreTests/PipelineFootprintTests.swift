import XCTest
import Darwin
@testable import DistavoCore

/// Memory-growth guard for the pure pipeline (Vikunja #4019). Runs `Pipeline.processOne` N times on
/// synthetic fixtures with fake engines (no audio, model or server) and fails if the process
/// footprint keeps rising. It can only clear or implicate DistavoCore: the engines in
/// DistavoEmbedded (WhisperKit, SpeakerKit, Parakeet) are faked out here.
/// Gated: `DISTAVO_LIVE=1 swift test --filter PipelineFootprintTests`.
final class PipelineFootprintTests: XCTestCase {

    /// `phys_footprint` of this process in MB (what `footprint` and Activity Monitor report).
    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    func testRepeatedProcessingDoesNotGrowFootprint() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DISTAVO_LIVE"] == "1", "set DISTAVO_LIVE=1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-foot-" + UUID().uuidString)
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path

        // A long synthetic transcript (about 3 h of talk) so any per-run retention is visible.
        var segments: [[String: Any]] = []
        for i in 0..<4000 {
            var seg: [String: Any] = [:]
            seg["speaker"] = i % 2 == 0 ? "SPEAKER_00" : "SPEAKER_01"
            seg["start"] = Double(i) * 2
            seg["end"] = Double(i) * 2 + 1.9
            seg["text"] = "Synthetic sentence number " + String(i) + " about the project plan and the budget."
            segments.append(seg)
        }
        let note = "# Meeting notes\n\n## Executive summary\n" + String(repeating: "Synthetic summary line. ", count: 60)
        let deps = PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in ["segments": segments] },
            ollamaReachable: { _ in true },
            summarise: { _, _, _, _ in note },
            audioDurationSeconds: { _ in 600 })

        var samples: [Double] = []
        for run in 0..<30 {
            let input = rec.appendingPathComponent("synthetic-\(run).opus")
            try Data([0, 1, 2, 3]).write(to: input)
            let result = await Pipeline.processOne(path: input, config: cfg, deps: deps, stableChecks: 1, stableDelay: 0)
            XCTAssertEqual(result.status, .done, result.message ?? "")
            if run == 4 || run % 5 == 4 { samples.append(footprintMB()) }
        }
        print("FOOTPRINT-MB after runs 5,10,...,30:", samples.map { Int($0) })
        let baseline = try XCTUnwrap(samples.first)
        XCTAssertLessThan((samples.last ?? 0) - baseline, 200, "footprint kept rising: \(samples)")
    }
}
