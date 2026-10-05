import XCTest
@testable import DistavoCore

/// Model output must never produce a live link (security review of #2948).
final class AskDisplayTests: XCTestCase {
    func testMarkdownLinksAreStrippedButTextAndEmphasisKept() {
        let a = AskPrompt.displayText("See **this** [click](https://evil.example/?q=SECRET) and <https://evil.example/x> [1].")
        XCTAssertTrue(a.runs.allSatisfy { $0.link == nil })
        let plain = String(a.characters)
        XCTAssertTrue(plain.contains("click"))
        XCTAssertTrue(plain.contains("this"))
        XCTAssertTrue(a.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }
}
