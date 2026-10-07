import XCTest
@testable import DistavoCore

/// 1.18: the recorder's "Default (from Settings)" says what Settings holds, and
/// the "Bigger model" field says whether the model is bigger.
final class SettingsDefaultsTests: XCTestCase {

    func testNoteLanguageLabelNamesTheSetting() {
        var c = Config()
        XCTAssertEqual(SettingsDefaults.noteLanguageLabel(c), "Default from Settings (English)")
        c.summarise.noteLanguage = "auto"
        XCTAssertEqual(SettingsDefaults.noteLanguageLabel(c), "Default from Settings (same as the meeting)")
        c.summarise.noteLanguage = "ca"
        XCTAssertEqual(SettingsDefaults.noteLanguageLabel(c), "Default from Settings (always Catalan)")
        c.summarise.noteLanguage = "zz-unknown"
        XCTAssertEqual(SettingsDefaults.noteLanguageLabel(c), "Default from Settings (English)", "unknown = English, as the pipeline treats it")
    }

    func testTemplateLabelNamesTheResolvedTemplate() throws {
        var c = Config()
        XCTAssertEqual(SettingsDefaults.templateLabel(c), "Default from Settings (no template)")
        let standup = try XCTUnwrap(SummaryTemplateCatalog.bundledTemplates.first)
        c.summarise.template = standup.id
        XCTAssertEqual(SettingsDefaults.templateLabel(c), "Default from Settings (\(standup.name))")
        c.summarise.template = SummaryTemplateCatalog.noneID
        XCTAssertEqual(SettingsDefaults.templateLabel(c), "Default from Settings (no template)")
    }

    func testTemplateLabelSaysWhenAFolderRuleDecides() throws {
        var c = Config()
        let t = try XCTUnwrap(SummaryTemplateCatalog.bundledTemplates.last)
        c.summarise.folderTemplates = ["Sales": t.id]
        XCTAssertEqual(SettingsDefaults.templateLabel(c, folder: "Sales"), "Default from Settings (\(t.name), from the folder)")
        XCTAssertEqual(SettingsDefaults.templateLabel(c, folder: ""), "Default from Settings (no template)")
    }

    // MARK: Model sizes

    func testParameterCountsFromTags() {
        XCTAssertEqual(ModelSize.billions("gemma4:26b"), 26)
        XCTAssertEqual(ModelSize.billions("qwen2.5:7b-instruct"), 7)
        XCTAssertEqual(ModelSize.billions("gemma3n:e4b"), 4)
        XCTAssertEqual(ModelSize.billions("gemma3:270m"), 0.27)
        XCTAssertEqual(ModelSize.billions("26.0B"), 26)
        XCTAssertNil(ModelSize.billions("llama3"))
        XCTAssertNil(ModelSize.billions("mistral:latest"))
    }

    func testCompareByNameAlone() {
        XCTAssertEqual(ModelSize.compare("gemma4:26b", to: "gemma4:12b"), .bigger)
        XCTAssertEqual(ModelSize.compare("gemma4:4b", to: "gemma4:12b"), .smaller)
        XCTAssertEqual(ModelSize.compare("Gemma4:12b", to: "gemma4:12b"), .same)
        XCTAssertEqual(ModelSize.compare("mistral", to: "gemma4:12b"), .unknown)
        XCTAssertEqual(ModelSize.compare("", to: "gemma4:12b"), .unknown)
    }

    func testCompareUsesTheServerListWhenNamesSayNothing() {
        let installed = [OllamaModelInfo(name: "mistral:latest", sizeBytes: 4_100_000_000, parameterSize: "7.2B"),
                         OllamaModelInfo(name: "phi:latest", sizeBytes: 1_600_000_000),
                         OllamaModelInfo(name: "big:latest", sizeBytes: 9_000_000_000)]
        XCTAssertEqual(ModelSize.compare("mistral", to: "gemma4:12b", installed: installed), .smaller, "7.2B from the server vs 12b in the tag")
        XCTAssertEqual(ModelSize.compare("big", to: "phi", installed: installed), .bigger, "size on disk when no parameter count")
        XCTAssertTrue(ModelSize.isInstalled("mistral", in: installed))
        XCTAssertFalse(ModelSize.isInstalled("gemma4:26b", in: installed))
    }

    func testVerdictText() {
        let installed = [OllamaModelInfo(name: "gemma4:12b", sizeBytes: 8_000_000_000, parameterSize: "12B")]
        let smaller = ModelSize.verdict(bigger: "gemma4:4b", normal: "gemma4:12b", installed: installed, listed: true)
        XCTAssertEqual(smaller.comparison, .smaller)
        XCTAssertTrue(smaller.text.contains("Smaller than the server model"))
        XCTAssertTrue(smaller.text.contains("not installed"))
        let bigger = ModelSize.verdict(bigger: "gemma4:26b", normal: "gemma4:12b", installed: [], listed: false)
        XCTAssertEqual(bigger.comparison, .bigger)
        XCTAssertFalse(bigger.text.contains("not installed"), "no claim about the server when it was not asked")
    }

    func testModelsParsesTagsLargestFirst() async throws {
        let session = MockURLProtocol.session { req in
            XCTAssertEqual(req.url?.path, "/api/tags")
            return try MockURLProtocol.ok(req.url!, json: ["models": [
                ["name": "gemma4:12b", "size": 8_100_000_000, "details": ["parameter_size": "12.2B"]],
                ["name": "gemma4:26b", "size": 17_000_000_000, "details": ["parameter_size": "26.0B"]],
                ["model": "tiny:latest"], ["size": 5]]])
        }
        let models = try await OllamaClient(session: session).models("http://host:11434/")
        XCTAssertEqual(models.map(\.name), ["gemma4:26b", "gemma4:12b", "tiny:latest"])
        XCTAssertEqual(models[0].sizeLabel, "17 GB")
        XCTAssertEqual(models[1].sizeLabel, "8.1 GB")
        XCTAssertEqual(models[2].sizeLabel, "")
    }

    func testModelsThrowsWhenTheServerIsDown() async {
        let session = MockURLProtocol.session { req in try MockURLProtocol.ok(req.url!, json: [:], status: 500) }
        do {
            _ = try await OllamaClient(session: session).models("http://host:11434")
            XCTFail("expected an error")
        } catch { XCTAssertTrue(error is OllamaError) }
    }
}
