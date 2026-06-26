import XCTest
@testable import SeshatCore

final class IssueReportTests: XCTestCase {

    func testBuildsWellFormedNewIssueURL() {
        let url = IssueReport.githubNewIssueURL(
            repoSlug: "Joanmarcriera/seshat", title: "Issue: report", body: "hello")
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.hasPrefix(
            "https://github.com/Joanmarcriera/seshat/issues/new?"))
    }

    func testPercentEncodesSpacesNewlinesAndUnicode() {
        let url = IssueReport.githubNewIssueURL(
            repoSlug: "owner/repo", title: "a b", body: "l1\nl2 · ok")
        let string = url!.absoluteString
        XCTAssertTrue(string.contains("title=a%20b"), string)        // space → %20 (not +)
        XCTAssertTrue(string.contains("body=l1%0Al2%20%C2%B7%20ok"), string)  // \n → %0A, · → %C2%B7
    }

    func testQuerySubDelimitersRoundTripIntact() {
        // & = + # would corrupt the query if left raw (URLComponents.queryItems would).
        let title = "Crash on launch"
        let body = "args: a & b = c+d #e"
        let url = IssueReport.githubNewIssueURL(repoSlug: "owner/repo", title: title, body: body)
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.queryItems?.first { $0.name == "title" }?.value, title)
        XCTAssertEqual(components.queryItems?.first { $0.name == "body" }?.value, body)
    }

    func testNonASCIIIsPercentEncodedAndRoundTrips() {
        // Unicode letters must be encoded, not left raw (CharacterSet.alphanumerics would).
        let title = "Café crash — ñoño"
        let body = "user: José · host: münchen"
        let url = IssueReport.githubNewIssueURL(repoSlug: "owner/repo", title: title, body: body)
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.allSatisfy { $0.isASCII }, url!.absoluteString)  // no raw bytes leak
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.queryItems?.first { $0.name == "title" }?.value, title)
        XCTAssertEqual(components.queryItems?.first { $0.name == "body" }?.value, body)
    }
}
