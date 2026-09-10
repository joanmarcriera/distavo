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

    /// Converts a WhisperKit *folder* name (`org_name`, using `_` to join the
    /// Hugging Face org and model name — e.g. "openai_whisper-tiny") into the
    /// actual Hugging Face *repository* name ("openai/whisper-tiny"). NOTICES.md
    /// is expected to credit the repository, not WhisperKit's on-disk naming
    /// convention, so every required string here is checked in that form —
    /// this test must never fail again just because a folder name and its
    /// repo name look different. A name with no underscore (already a
    /// repository string, or with nothing to split) passes through unchanged.
    private func repositoryForm(_ name: String) -> String {
        guard let underscore = name.firstIndex(of: "_") else { return name }
        var repo = name
        repo.replaceSubrange(underscore...underscore, with: "/")
        return repo
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
            // first "Automatic" use — the catalog stores this as a WhisperKit
            // folder name ("openai_whisper-tiny"), converted here to the
            // repository NOTICES.md actually credits ("openai/whisper-tiny").
            repositoryForm(EmbeddedModelCatalog.languageDetectorName),
            // NVIDIA Parakeet TDT 0.6B v3, Core ML conversion.
            "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        ]
        // Every custom (non-Argmax) whisperKitRepo the catalog can route to
        // (currently Distavo's own BSC Languages-of-Spain conversions). These
        // are already stored in repository form, so repositoryForm() is a
        // no-op on them (no underscore to split).
        let customRepos = Set(EmbeddedModelCatalog.models.compactMap(\.whisperKitRepo)).map(repositoryForm)
        required.append(contentsOf: customRepos)

        let missing = required.filter { !notices.contains($0) }
        XCTAssertTrue(
            missing.isEmpty,
            "NOTICES.md is missing credit for: \(missing.joined(separator: ", ")) " +
            "— every repo the built-in engine can download from must be named in NOTICES.md.")
    }
}
