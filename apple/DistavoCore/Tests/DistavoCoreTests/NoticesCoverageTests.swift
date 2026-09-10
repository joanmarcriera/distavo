import XCTest
@testable import DistavoCore

/// Guards the release claim that every Hugging Face repository the app can
/// download from is credited in NOTICES.md. This is a plain substring check
/// against the file on disk (not a licensing parser) — it exists so a new
/// downloadable repo added to the catalog can't silently ship uncredited.
final class NoticesCoverageTests: XCTestCase {

    /// NOTICES.md lives at the repo root; this test file is at
    /// apple/DistavoCore/Tests/DistavoCoreTests/, five path components down.
    private func noticesText() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("NOTICES.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testEveryDownloadableHuggingFaceRepoIsCredited() throws {
        let notices = try noticesText()

        var required: [String] = [
            // Argmax's default WhisperKit Core ML repo (large-v3-turbo, small).
            "argmaxinc/whisperkit-coreml",
            // SpeakerKit's pyannote diarization models.
            "argmaxinc/speakerkit-coreml",
            // Whisper tokenizer, fetched regardless of variant.
            "openai/whisper-large-v3",
            // The language-detector variant (whisper-tiny) downloaded on
            // first "Automatic" use.
            EmbeddedModelCatalog.languageDetectorName,
            // NVIDIA Parakeet TDT 0.6B v3, Core ML conversion.
            "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        ]
        // Every custom (non-Argmax) whisperKitRepo the catalog can route to
        // (currently Distavo's own BSC Languages-of-Spain conversions).
        let customRepos = Set(EmbeddedModelCatalog.models.compactMap(\.whisperKitRepo))
        required.append(contentsOf: customRepos)

        let missing = required.filter { !notices.contains($0) }
        XCTAssertTrue(
            missing.isEmpty,
            "NOTICES.md is missing credit for: \(missing.joined(separator: ", ")) " +
            "— every repo the built-in engine can download from must be named in NOTICES.md.")
    }
}
