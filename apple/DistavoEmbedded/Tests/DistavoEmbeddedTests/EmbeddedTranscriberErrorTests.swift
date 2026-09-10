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
}
