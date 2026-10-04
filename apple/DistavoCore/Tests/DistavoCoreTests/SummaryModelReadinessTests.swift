import XCTest
@testable import DistavoCore

/// Table tests for `SummaryModelReadiness` (Vikunja #2198 S5): every row says
/// whether a recording defers (retried) or fails (once, with guidance).
final class SummaryModelReadinessTests: XCTestCase {
    private let gemma = EmbeddedSummaryModelCatalog.model(id: "gemma-4-e4b")
    private let apple = EmbeddedSummaryModelCatalog.model(id: "apple")

    private func eval(_ state: SummaryModelDownloadState, memoryGB: Int = 16,
                      appleSilicon: Bool = true, freeDiskMB: Int = 100_000,
                      model: EmbeddedSummaryModel? = nil) -> EmbeddedReadiness {
        SummaryModelReadiness.evaluate(model: model ?? gemma, downloadState: state, memoryGB: memoryGB,
                                       isAppleSilicon: appleSilicon, freeDiskMB: freeDiskMB)
    }

    private func kind(_ r: EmbeddedReadiness) -> String {
        switch r {
        case .ready: return "ready"
        case .temporarilyUnavailable: return "defer"
        case .unsupported: return "fail"
        }
    }

    func testTable() {
        let rows: [(String, EmbeddedReadiness, String)] = [
            ("verified", eval(.verified), "ready"),
            ("download pending", eval(.notStarted), "defer"),
            ("download in progress", eval(.inProgress(fraction: 0.4)), "defer"),
            ("manifest mismatch once", eval(.manifestMismatch), "defer"),
            ("failed permanently", eval(.failedPermanently("checksum")), "fail"),
            ("RAM below floor", eval(.verified, memoryGB: 8), "fail"),
            ("RAM below floor, not downloaded", eval(.notStarted, memoryGB: 8), "fail"),
            ("Intel", eval(.verified, appleSilicon: false), "fail"),
            ("not enough disk, pending", eval(.notStarted, freeDiskMB: 2_000), "defer"),
            ("not enough disk, mismatch", eval(.manifestMismatch, freeDiskMB: 2_000), "defer"),
            ("disk irrelevant once verified", eval(.verified, freeDiskMB: 0), "ready"),
            ("disk irrelevant while downloading", eval(.inProgress(fraction: 0.1), freeDiskMB: 0), "defer"),
        ]
        for (name, result, expected) in rows { XCTAssertEqual(kind(result), expected, name) }
    }

    func testRAMFloorIsExactlyTheCatalogueMinimum() {
        XCTAssertEqual(kind(eval(.verified, memoryGB: 15)), "fail")
        XCTAssertEqual(kind(eval(.verified, memoryGB: 16)), "ready")
    }

    func testDiskNeedIsTwiceTheDownload() {
        let need = gemma.downloadMB * SummaryModelReadiness.diskFactor
        XCTAssertEqual(kind(eval(.notStarted, freeDiskMB: need - 1)), "defer")
        if case .temporarilyUnavailable(let why) = eval(.notStarted, freeDiskMB: need - 1) {
            XCTAssertTrue(why.contains("free disk space"))
        } else { XCTFail() }
        if case .temporarilyUnavailable(let why) = eval(.notStarted, freeDiskMB: need) {
            XCTAssertTrue(why.contains("download"), "enough disk: the message is about the download starting")
        } else { XCTFail() }
    }

    func testProgressPercentIsClamped() {
        if case .temporarilyUnavailable(let why) = eval(.inProgress(fraction: 1.7)) {
            XCTAssertTrue(why.contains("100%"))
        } else { XCTFail() }
    }

    func testAppleModelNeedsNoDownload() {
        XCTAssertEqual(eval(.notStarted, freeDiskMB: 0, model: apple), .ready)
        // Apple's own availability is checked elsewhere (EmbeddedSummariser).
        XCTAssertEqual(eval(.notStarted, appleSilicon: false, model: apple), .ready)
    }

    func testPinnedRevisionAndManifest() throws {
        XCTAssertEqual(gemma.revision, "475b9088d29754a3379866cf5aeb6b41acd313c2")
        XCTAssertEqual(gemma.files.count, 8)
        XCTAssertEqual(gemma.files.map(\.bytes).reduce(0, +) / 1_000_000, 5_179, "about the 5.15 GB download")
        let weights = try XCTUnwrap(gemma.files.first { $0.path == "model.safetensors" })
        XCTAssertEqual(gemma.downloadURL(for: weights)?.absoluteString,
                       "https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit/resolve/475b9088d29754a3379866cf5aeb6b41acd313c2/model.safetensors")
        let json = try JSONSerialization.jsonObject(
            with: gemma.manifestJSON(sha256ByPath: ["model.safetensors": "aa", "config.json": "bb"])) as? [String: Any]
        let files = try XCTUnwrap(json?["files"] as? [String: [String: Any]])
        XCTAssertEqual(files["model.safetensors"]?["sha256"] as? String, "aa", "locally computed hashes are written")
        XCTAssertEqual(files["config.json"]?["sha256"] as? String, "bb")
        XCTAssertNil(files["tokenizer.json"]?["sha256"], "an unhashed file is written without a hash so the verifier rejects it")
        XCTAssertNil(apple.downloadURL(for: weights))
    }
}
