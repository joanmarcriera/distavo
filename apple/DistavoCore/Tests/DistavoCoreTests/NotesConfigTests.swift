import XCTest
@testable import DistavoCore

/// Migration for the #2954 `notes` config section: a config predating it decodes to
/// everything OFF / empty, wrong types fall back instead of failing the config, and the
/// keys round-trip under their JSON names.
final class NotesConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: json.data(using: .utf8)!)
    }

    func testConfigPredatingTheSectionDecodesToAllOff() throws {
        for json in ["{}", #"{"summarise": {"backend": "local"}}"#, #"{"notes_dir": "~/n"}"#] {
            let n = try decode(json).notes
            XCTAssertEqual(n, NotesConfig())
            XCTAssertFalse(n.frontmatter); XCTAssertFalse(n.autoTitle); XCTAssertFalse(n.autoTags)
            XCTAssertEqual(n.trackedTerms, []); XCTAssertEqual(n.vaultDir, ""); XCTAssertEqual(n.vaultSubfolder, "")
            XCTAssertFalse(n.hasVault); XCTAssertFalse(n.asksModelForMetadata)
        }
    }

    func testPartialSectionKeepsTheRestOff() throws {
        let n = try decode(#"{"notes": {"frontmatter": true}}"#).notes
        XCTAssertTrue(n.frontmatter)
        XCTAssertFalse(n.autoTitle); XCTAssertEqual(n.vaultDir, "")
    }

    func testWrongTypesFallBackInsteadOfFailingTheConfig() throws {
        let cfg = try decode(#"{"note_owner": "Ann", "notes": {"frontmatter": "yes", "auto_title": 3, "tracked_terms": "x", "vault_dir": 7, "vault_subfolder": []}}"#)
        XCTAssertEqual(cfg.noteOwner, "Ann")
        XCTAssertEqual(cfg.notes, NotesConfig())
        // A wholly wrong-typed section is also just "off".
        XCTAssertEqual(try decode(#"{"notes": "on"}"#).notes, NotesConfig())
        // Bad list entries are dropped, good ones kept.
        XCTAssertEqual(try decode(#"{"notes": {"tracked_terms": ["GDPR", 5, "Slurm"]}}"#).notes.trackedTerms, ["GDPR", "Slurm"])
    }

    func testKeysRoundTripWithTheirJSONNames() throws {
        var c = Config()
        c.notes = NotesConfig(frontmatter: true, autoTitle: true, autoTags: true,
                              trackedTerms: ["GDPR", "pricing"], vaultDir: "~/Vault", vaultSubfolder: "Meetings")
        let data = try JSONEncoder().encode(c)
        let text = String(decoding: data, as: UTF8.self)
        for key in ["\"frontmatter\"", "\"auto_title\"", "\"auto_tags\"", "\"tracked_terms\"", "\"vault_dir\"", "\"vault_subfolder\""] {
            XCTAssertTrue(text.contains(key), key)
        }
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: data).notes, c.notes)
    }

    func testFreshInstallRecommendationLeavesEverythingOff() {
        XCTAssertEqual(Config.recommendedForThisMac(embeddedSupported: true, memoryBytes: 32 << 30).notes, NotesConfig())
        XCTAssertEqual(Config.recommendedForThisMac(embeddedSupported: false, memoryBytes: 8 << 30).notes, NotesConfig())
    }

    func testTermsAreNormalised() {
        XCTAssertEqual(NotesConfig(trackedTerms: [" GDPR ", "gdpr", "a, b", ""]).terms, ["GDPR", "a", "b"])
    }
}
