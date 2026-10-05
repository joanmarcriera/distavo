import XCTest
@testable import DistavoCore

/// Vikunja #2955: URL validation, download policy and the hardened feed parser.
final class ImportURLTests: XCTestCase {

    private func valid(_ s: String) -> ImportURLPolicy.Validated? {
        if case .success(let v) = ImportURLPolicy.validate(s) { return v }
        return nil
    }
    private func problem(_ s: String) -> ImportURLPolicy.Problem? {
        if case .failure(let p) = ImportURLPolicy.validate(s) { return p }
        return nil
    }

    // MARK: URL validation

    func testHTTPSAccepted() {
        let v = valid("  https://example.com/pod/ep1.mp3?x=1  ")
        XCTAssertEqual(v?.url.absoluteString, "https://example.com/pod/ep1.mp3?x=1")
        XCTAssertEqual(v?.isInsecureLocal, false)
    }

    func testRejectedSchemesAndShapes() {
        XCTAssertEqual(problem(""), .empty)
        XCTAssertEqual(problem("   "), .empty)
        XCTAssertEqual(problem("ftp://example.com/a.mp3"), .notHTTPS)
        XCTAssertEqual(problem("file:///etc/passwd"), .notHTTPS)
        XCTAssertEqual(problem("javascript:alert(1)"), .notHTTPS)
        XCTAssertEqual(problem("example.com/a.mp3"), .malformed)
        XCTAssertEqual(problem("https://user:pw@example.com/a.mp3"), .hasCredentials)
        XCTAssertEqual(problem("https://user@example.com/a.mp3"), .hasCredentials)
        XCTAssertEqual(problem("https:///a.mp3"), .noHost)
        XCTAssertEqual(problem("https://exa mple.com/a.mp3"), .malformed)
        XCTAssertEqual(problem("https://example.com/a\n.mp3"), .malformed)
        XCTAssertEqual(problem("https://exämple.com/a.mp3"), .malformed)
        XCTAssertEqual(problem("https://example.com:0/a.mp3"), .malformed)
        XCTAssertEqual(problem("https://example.com:99999/a.mp3"), .malformed)
        XCTAssertEqual(problem("https://example.com/" + String(repeating: "a", count: 3000)), .tooLong)
    }

    func testHTTPOnlyForLoopbackAndLANLiterals() {
        for ok in ["http://localhost:8080/a.mp3", "http://127.0.0.1/a.mp3", "http://192.168.0.5:9000/a.mp3", "http://10.1.2.3/a.mp3",
                   "http://172.16.0.1/a", "http://172.31.255.255/a", "http://169.254.1.1/a", "http://[::1]:80/a.mp3",
                   "http://[fd00::1]/a.mp3", "http://nas.local/a.mp3"] {
            XCTAssertEqual(valid(ok)?.isInsecureLocal, true, ok)
        }
        for bad in ["http://example.com/a.mp3", "http://8.8.8.8/a.mp3", "http://172.32.0.1/a", "http://172.15.0.1/a",
                    "http://192.169.0.1/a", "http://localhost.evil.com/a", "http://127.0.0.1.evil.com/a", "http://[2001:db8::1]/a",
                    "http://0x7f.1/a", "http://2130706433/a"] {
            XCTAssertEqual(problem(bad), .insecureNotLocal, bad)
        }
    }

    func testReturnedURLIsRebuiltFromParsedComponents() {
        XCTAssertEqual(valid("HTTPS://Example.COM:8443")?.url.absoluteString, "https://example.com:8443/")
        XCTAssertNil(valid("https://example.com/a.mp3#frag")?.url.fragment, "fragment dropped")
    }

    // MARK: redirects

    func testRedirectPolicy() {
        let from = URL(string: "https://cdn.example.com/a.mp3")!
        func decide(_ to: String?, _ n: Int = 0, from f: URL? = nil) -> ImportURLPolicy.RedirectDecision {
            ImportURLPolicy.redirect(from: f ?? from, to: to.flatMap { URL(string: $0) }, count: n)
        }
        XCTAssertEqual(decide("https://other.example.com/b.mp3"), .follow(URL(string: "https://other.example.com/b.mp3")!))
        XCTAssertEqual(decide("https://other.example.com/b.mp3", 4), .follow(URL(string: "https://other.example.com/b.mp3")!))
        if case .refuse(let r) = decide("https://other.example.com/b.mp3", 5) { XCTAssertTrue(r.contains("too many")) } else { XCTFail() }
        if case .refuse(let r) = decide("http://other.example.com/b.mp3") { XCTAssertTrue(r.contains("not an acceptable")) } else { XCTFail("plain http to a public host") }
        if case .refuse(let r) = decide("http://192.168.0.1/b.mp3") { XCTAssertTrue(r.contains("https to http")) } else { XCTFail("downgrade") }
        if case .refuse = decide("https://127.0.0.1/b.mp3") {} else { XCTFail("public -> loopback pivot") }
        if case .refuse = decide("https://192.168.1.1/b.mp3") {} else { XCTFail("public -> LAN pivot") }
        if case .refuse = decide("https://localhost/b.mp3") {} else { XCTFail("public -> localhost pivot") }
        if case .refuse = decide("file:///etc/passwd") {} else { XCTFail("file") }
        if case .refuse = decide("https://u:p@example.com/x") {} else { XCTFail("credentials") }
        if case .refuse = decide(nil) {} else { XCTFail("nil target") }
        // A LAN origin may redirect within the LAN over http, but not downgrade from https.
        let lan = URL(string: "http://192.168.0.5/a.mp3")!
        XCTAssertEqual(decide("http://192.168.0.6/b.mp3", from: lan), .follow(URL(string: "http://192.168.0.6/b.mp3")!))
        if case .refuse = decide("http://192.168.0.6/b.mp3", from: URL(string: "https://nas.local/a.mp3")!) {} else { XCTFail("https->http on LAN") }
    }

    // MARK: response classification

    private let u = URL(string: "https://example.com/pod/ep%201.mp3")!
    private func kind(_ ct: String?, status: Int = 200, len: Int64? = nil, url: URL? = nil) -> Result<ImportURLPolicy.ResponseKind, ImportURLPolicy.ResponseProblem> {
        ImportURLPolicy.classify(status: status, contentType: ct, declaredLength: len, url: url ?? u)
    }

    func testClassification() {
        XCTAssertEqual(try? kind("audio/mpeg").get(), .media(fileName: "ep 1.mp3"))
        XCTAssertEqual(try? kind("audio/mpeg; charset=binary").get(), .media(fileName: "ep 1.mp3"))
        XCTAssertEqual(try? kind("application/octet-stream").get(), .media(fileName: "ep 1.mp3"), "generic type + media extension")
        XCTAssertEqual(try? kind("application/rss+xml; charset=utf-8").get(), .feed)
        XCTAssertEqual(try? kind("text/xml").get(), .feed)
        XCTAssertEqual(try? kind("video/mp4", url: URL(string: "https://e.com/download?id=5")).get(), .media(fileName: "download.mp4"))
        XCTAssertEqual(kind("audio/mpeg", status: 404).failureValue, .badStatus(404))
        XCTAssertEqual(kind(nil, status: 302).failureValue, .badStatus(302))
        XCTAssertEqual(kind("text/html").failureValue, .unsupportedType)
        XCTAssertEqual(kind("application/octet-stream", url: URL(string: "https://e.com/payload.exe")).failureValue, .unsupportedType)
        XCTAssertEqual(kind("application/x-msdownload").failureValue, .unsupportedType)
        XCTAssertEqual(kind("audio/mpeg", len: ImportURLPolicy.maxDownloadBytes + 1).failureValue, .tooLarge)
        XCTAssertNotNil(try? kind("audio/mpeg", len: ImportURLPolicy.maxDownloadBytes).get())
    }

    func testSizeCapIsEnforcedWhileStreaming() {
        XCTAssertTrue(ImportURLPolicy.withinCap(received: ImportURLPolicy.maxDownloadBytes))
        XCTAssertFalse(ImportURLPolicy.withinCap(received: ImportURLPolicy.maxDownloadBytes + 1))
        XCTAssertFalse(ImportURLPolicy.withinCap(received: 11, limit: 10))
        XCTAssertEqual(ImportURLPolicy.maxDownloadBytes, 2_147_483_648)
    }

    func testFileNamesAreSanitisedAndNeverFromContentDisposition() {
        func name(_ s: String, _ ext: String = "mp3") -> String { ImportURLPolicy.fileName(for: URL(string: s)!, fallbackExtension: ext) }
        XCTAssertEqual(name("https://e.com/a/..%2F..%2Fetc%2Fpasswd"), "..%2F..%2Fetc%2Fpasswd".removingPercentEncoding.map { QueuedFile.sanitizedName($0) + ".mp3" })
        XCTAssertFalse(name("https://e.com/%2e%2e%2f%2e%2e%2fevil.mp3").contains("/"))
        XCTAssertFalse(name("https://e.com/.hidden.mp3").hasPrefix("."))
        XCTAssertFalse(name("https://e.com/a%00b.mp3").contains("\0"))
        XCTAssertFalse(name("https://e.com/a%1B%5B2Jb.mp3").unicodeScalars.contains { $0.value < 0x20 })
        XCTAssertEqual(name("https://e.com/"), "download.mp3")
        XCTAssertEqual(name("https://e.com/episode"), "episode.mp3")
        XCTAssertTrue(QueuedFile.isSupportedMedia(name("https://e.com/x.exe")), "always ends in a media extension")
        XCTAssertLessThanOrEqual(name("https://e.com/" + String(repeating: "a", count: 500) + ".mp3").count, 125)
    }

    // MARK: feeds

    private func feed(_ xml: String) -> Result<[FeedEnclosure], FeedParser.Failure> { FeedParser.parse(Data(xml.utf8)) }

    func testRSSEnclosures() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>Show</title>
        <item><title>Ep 2 &amp; more</title><enclosure url="https://cdn.example.com/2.mp3" length="1234" type="audio/mpeg"/></item>
        <item><title>  Ep 1
           spaced </title><enclosure url="https://cdn.example.com/1.m4a" type="audio/mp4"/></item>
        <item><title>No audio</title></item>
        <item><title>Bad url</title><enclosure url="javascript:alert(1)" type="audio/mpeg"/></item>
        <item><title>Plain http</title><enclosure url="http://example.com/x.mp3" type="audio/mpeg"/></item>
        </channel></rss>
        """
        let items = try feed(xml).get()
        XCTAssertEqual(items.map(\.title), ["Ep 2 & more", "Ep 1 spaced"])
        XCTAssertEqual(items[0].url.absoluteString, "https://cdn.example.com/2.mp3")
        XCTAssertEqual(items[0].bytes, 1234); XCTAssertEqual(items[0].mimeType, "audio/mpeg")
        XCTAssertNil(items[1].bytes)
    }

    func testAtomEnclosures() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>F</title>
        <entry><title>One</title><link rel="alternate" href="https://e.com/one"/><link rel="enclosure" href="https://e.com/one.mp3" type="audio/mpeg" length="9"/></entry>
        </feed>
        """
        let items = try feed(xml).get()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].url.absoluteString, "https://e.com/one.mp3")
    }

    func testXXEAndDoctypeAreRefusedAndNothingIsFetched() {
        let xxe = """
        <?xml version="1.0"?><!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <rss><channel><item><title>&xxe;</title><enclosure url="https://e.com/a.mp3" type="audio/mpeg"/></item></channel></rss>
        """
        XCTAssertEqual(feed(xxe).failureValue, .forbiddenConstruct)
        XCTAssertEqual(feed("<!doctype rss><rss/>").failureValue, .forbiddenConstruct, "case-insensitive")
        XCTAssertEqual(feed("<!DocType\nrss><rss/>").failureValue, .forbiddenConstruct)
        XCTAssertEqual(feed("<rss><!ENTITY a \"b\"></rss>").failureValue, .forbiddenConstruct)
        let remote = #"<?xml version="1.0"?><!DOCTYPE r SYSTEM "http://evil.example/x.dtd"><rss/>"#
        XCTAssertEqual(feed(remote).failureValue, .forbiddenConstruct)
    }

    func testBillionLaughsIsRefused() {
        var xml = #"<?xml version="1.0"?><!DOCTYPE lolz [<!ENTITY lol "lol">"#
        var prev = "lol"
        for i in 1...9 {
            xml += "<!ENTITY lol\(i) \"" + String(repeating: "&\(prev);", count: 10) + "\">"
            prev = "lol\(i)"
        }
        xml += "]><rss><channel><item><title>&\(prev);</title></item></channel></rss>"
        XCTAssertEqual(feed(xml).failureValue, .forbiddenConstruct)
    }

    func testUTF16CannotSmuggleADoctype() {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE a [<!ENTITY x \"y\">]><rss/>"
        let data = xml.data(using: .utf16)!
        XCTAssertEqual(FeedParser.parse(data).failureValue, .forbiddenConstruct)
    }

    func testHugeFeedIsRefused() {
        let big = Data(repeating: 0x20, count: ImportURLPolicy.maxFeedBytes + 1)
        XCTAssertEqual(FeedParser.parse(big).failureValue, .tooLarge)
    }

    func testItemCountIsCapped() throws {
        var xml = "<rss><channel>"
        for i in 0..<500 { xml += "<item><title>t\(i)</title><enclosure url=\"https://e.com/\(i).mp3\" type=\"audio/mpeg\"/></item>" }
        xml += "</channel></rss>"
        let items = try FeedParser.parse(Data(xml.utf8), limit: 200).get()
        XCTAssertEqual(items.count, 200)
        XCTAssertEqual(items.last?.title, "t199")
    }

    func testDeepNestingIsRefused() {
        let xml = "<rss>" + String(repeating: "<a>", count: 200) + String(repeating: "</a>", count: 200) + "</rss>"
        XCTAssertEqual(feed(xml).failureValue, .forbiddenConstruct)
    }

    func testNotAFeedAndMalformed() {
        XCTAssertEqual(feed("<html><body>hi</body></html>").failureValue, .notAFeed)
        XCTAssertEqual(feed("<rss><channel><item>").failureValue, .malformed)
        XCTAssertEqual(feed("").failureValue, .malformed)
        XCTAssertEqual(FeedParser.parse(Data([0x3c, 0x00, 0x72])).failureValue, .forbiddenConstruct, "NUL byte")
    }

    func testTitlesAreTerminalSafeAndBounded() throws {
        let xml = "<rss><channel><item><title>x]0;pwn y\u{202E}z\u{2028}" + String(repeating: "a", count: 500)
            + "</title><enclosure url=\"https://e.com/a.mp3\" type=\"audio/mpeg\"/></item></channel></rss>"
        let t = try feed(xml).get()[0].title
        XCTAssertFalse(t.unicodeScalars.contains { TerminalSafe.isDangerous($0) })
        XCTAssertLessThanOrEqual(t.count, 260)
    }

    func testRandomXMLishInputNeverCrashes() {
        var rng = SystemRandomNumberGenerator()
        let pieces = ["<rss>", "</rss>", "<item>", "</item>", "<title>", "</title>", "<enclosure url=\"https://e.com/a.mp3\"/>",
                      "<enclosure url=\"", "\"/>", "<![CDATA[", "]]>", "&amp;", "&bad;", "<!--", "-->", "<?xml", "?>", "<", ">", "\u{0}", "x"]
        for _ in 0..<3000 {
            let s = (0..<Int.random(in: 0...25, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
            _ = FeedParser.parse(Data(s.utf8))
        }
    }
}

private extension Result {
    var failureValue: Failure? { if case .failure(let e) = self { return e } else { return nil } }
}

final class ImportURLConfigNotNeededTests: XCTestCase {
    func testImportHasNoConfigKeyAndNothingRunsUnlessUserPastes() {
        // There is deliberately no config key for URL import: it is a menu action that only
        // acts on an address the user types, so there is nothing to default off.
        let json = String(decoding: try! JSONEncoder().encode(Config()), as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("import"))
    }
}
