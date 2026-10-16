import XCTest
@testable import DistavoCore

final class VocabularyUsageTests: XCTestCase {
    func testWholeWordCaseInsensitiveMatch() {
        XCTAssertEqual(VocabularyUsage.terms(["ERP", "Slurm", "Bull"], in: "El nostre erp, i un bulldog."), ["ERP"])
    }

    func testRecordAndStale() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        VocabularyUsage.record(terms: ["ERP", "Slurm"], transcript: "parlem de l'ERP", workDir: dir, now: old)
        let usage = VocabularyUsage.load(workDir: dir)
        XCTAssertEqual(usage.keys.sorted(), ["erp"])
        let now = old.addingTimeInterval(100 * 86_400)
        XCTAssertEqual(VocabularyUsage.stale(["ERP", "Slurm"], usage: usage, olderThanDays: 90, now: now), ["ERP"])
        XCTAssertEqual(VocabularyUsage.stale(["ERP", "Slurm"], usage: usage, olderThanDays: 90, now: now, includeNever: true),
                       ["ERP", "Slurm"])
    }
}
