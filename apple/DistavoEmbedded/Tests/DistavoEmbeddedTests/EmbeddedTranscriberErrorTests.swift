import XCTest
import DistavoCore
@testable import DistavoEmbedded

final class EmbeddedTranscriberErrorTests: XCTestCase {
    func testOfflineDownloadBecomesRetryable() {
        let offline = URLError(.notConnectedToInternet)
        let mapped = EmbeddedTranscriber.pipelineError(offline, model: "Best")
        guard let retry = mapped as? RetryableDependencyError else {
            return XCTFail("expected RetryableDependencyError, got \(mapped)")
        }
        XCTAssertTrue(retry.message.contains("No internet connection"))
    }

    func testOtherLoadFailuresStayPermanent() {
        struct Boom: Error {}
        let mapped = EmbeddedTranscriber.pipelineError(Boom(), model: "Best")
        XCTAssertTrue(mapped is EmbeddedTranscriberError)
    }

    /// A Parakeet model reaching the WhisperKit transcriber must fail fast with
    /// a typed, permanent error — never crash — and must never touch the
    /// network/coordinator to do so (the guard sits ahead of `withExclusiveAccess`).
    func testWrongEngineModelThrowsBeforeTouchingTheCoordinator() async {
        let parakeet = EmbeddedModelCatalog.model(id: "parakeet-tdt-v3")
        XCTAssertEqual(parakeet.engine, .parakeet)
        do {
            _ = try await EmbeddedTranscriber.shared.transcribe(
                wavURL: URL(fileURLWithPath: "/nonexistent.wav"),
                model: parakeet, languageHint: nil,
                config: TranscribeConfig(backend: "embedded"))
            XCTFail("expected wrongEngine to be thrown")
        } catch let EmbeddedTranscriberError.wrongEngine(model) {
            XCTAssertEqual(model, parakeet.displayName)
        } catch {
            XCTFail("expected EmbeddedTranscriberError.wrongEngine, got \(error)")
        }
    }
}
