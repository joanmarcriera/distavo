import XCTest
@testable import DistavoCore

/// Migration for the #2940 config keys: a config predating them decodes to "no
/// template", and they round-trip.
final class SummaryTemplateConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: json.data(using: .utf8)!)
    }

    func testConfigPredatingTemplatesDecodesToNone() throws {
        for json in ["{}", #"{"summarise": {"backend": "local"}}"#,
                     #"{"summarise": {"prompt_style": "facts_first", "note_language": "auto"}}"#] {
            let cfg = try decode(json)
            XCTAssertEqual(cfg.summarise.template, "")
            XCTAssertEqual(cfg.summarise.customTemplate, "")
            XCTAssertEqual(cfg.summarise.folderTemplates, [:])
            XCTAssertNil(SummaryTemplateCatalog.resolve(config: cfg, folder: "Sales"))
        }
    }

    func testWrongTypedValuesFallBackInsteadOfFailingTheConfig() throws {
        let cfg = try decode(#"{"summarise": {"template": 5, "custom_template": ["x"], "folder_templates": "no", "backend": "local"}}"#)
        XCTAssertEqual(cfg.summarise.template, "")
        XCTAssertEqual(cfg.summarise.customTemplate, "")
        XCTAssertEqual(cfg.summarise.folderTemplates, [:])
        XCTAssertEqual(cfg.summarise.backend, "local")
    }

    func testKeysRoundTripWithTheirJSONNames() throws {
        var c = Config()
        c.summarise.template = "standup"
        c.summarise.customTemplate = "## A"
        c.summarise.folderTemplates = ["Sales": "sales_call"]
        let data = try JSONEncoder().encode(c)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"custom_template\""))
        XCTAssertTrue(text.contains("\"folder_templates\""))
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: data).summarise.folderTemplates, ["Sales": "sales_call"])
    }

    func testFreshInstallRecommendationLeavesTemplatesOff() {
        let s = Config.recommendedForThisMac().summarise
        XCTAssertEqual(s.template, "")
        XCTAssertEqual(s.folderTemplates, [:])
    }
}
