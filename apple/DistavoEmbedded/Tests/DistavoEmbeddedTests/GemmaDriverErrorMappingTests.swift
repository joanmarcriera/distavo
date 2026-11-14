import XCTest
import DistavoCore
@testable import DistavoEmbedded

/// Vikunja #5405: on the Gemma path a context that cannot hold the prompt is a hard failure with a
/// readable message, never a `RetryableDependencyError` (which would defer every 30 minutes forever).
final class GemmaDriverErrorMappingTests: XCTestCase {
    func testContextTooSmallIsAHardFailureNotADeferral() {
        let mapped: Error = GemmaSummariser.mapDriverError(.contextTooSmall)
        XCTAssertFalse(mapped is RetryableDependencyError)
        XCTAssertTrue((mapped as? LocalSummaryError)?.message.contains("context is too small") == true)
    }
}
