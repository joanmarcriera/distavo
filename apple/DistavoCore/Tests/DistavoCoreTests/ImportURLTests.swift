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

    func testHTTPSPublicNameAccepted() {
        let v = valid("  https://Example.com/pod/ep1.mp3?x=1  ")
        XCTAssertEqual(v?.url.absoluteString, "https://example.com/pod/ep1.mp3?x=1")
        XCTAssertEqual(valid("https://cdn.example.co.uk:8443")?.url.absoluteString, "https://cdn.example.co.uk:8443/")
        XCTAssertNil(valid("https://example.com/a.mp3#frag")?.url.fragment, "fragment dropped")
    }

    func testRejectedSchemesAndShapes() {
        XCTAssertEqual(problem(""), .empty)
        XCTAssertEqual(problem("   "), .empty)
        for s in ["ftp://example.com/a.mp3", "file:///etc/passwd", "javascript:alert(1)", "http://example.com/a.mp3",
                  "gopher://example.com/", "data:audio/mp3;base64,AAAA", "HTTP://example.com/a.mp3"] {
            XCTAssertEqual(problem(s), .notHTTPS, s)
        }
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

    func testIPLiteralsInEveryNotationAndLocalNamesAreRefused() {
        for host in ["127.0.0.1", "10.0.0.1", "192.168.1.1", "8.8.8.8", "2130706433", "0x7f.0.0.1", "0177.0.0.1", "127.1", "0x7f000001",
                     "[::1]", "[fd00::1]", "[2001:db8::1]", "[::ffff:127.0.0.1]", "localhost", "LOCALHOST", "nas.local", "foo.localhost",
                     "router.lan", "printer.home.arpa", "svc.internal", "intranet", "host", "1.2.3.4.5", "a.b.123", "-bad.example.com",
                     "bad-.example.com", "a..example.com", "ex_ample.com", "x.t", "evil.test"] {
            let p = problem("https://\(host)/a.mp3")
            XCTAssertTrue(p == .notAPublicName || p == .malformed || p == .noHost, "\(host) -> \(String(describing: p))")
        }
    }

    // MARK: destination vetting (injected resolver)

    private func dest(_ addrs: [String]?, host: String = "cdn.example.com") -> Result<Void, ImportURLPolicy.DestinationProblem> {
        ImportURLPolicy.checkDestination(URL(string: "https://\(host)/a.mp3")!, resolver: { _ in addrs })
    }

    func testPublicAddressesPass() {
        XCTAssertNoThrow(try dest(["93.184.216.34"]).get())
        XCTAssertNoThrow(try dest(["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"]).get())
        XCTAssertNoThrow(try dest(["1.1.1.1", "8.8.4.4", "172.32.0.1", "100.128.0.1", "192.169.0.1", "198.20.0.1"]).get())
    }

    func testEveryNonPublicClassIsRefused() {
        let bad = ["127.0.0.1", "127.255.255.254", "0.0.0.0", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.0.5", "169.254.169.254",
                   "100.64.0.1", "100.127.255.255", "224.0.0.1", "239.255.255.250", "255.255.255.255", "240.0.0.1", "192.0.0.1", "192.0.2.1",
                   "198.18.0.1", "198.51.100.7", "203.0.113.9",
                   "::1", "::", "fe80::1", "fe80::1%en0", "fc00::1", "fd12:3456::1", "ff02::1", "2001:db8::1", "2002:7f00:1::", "64:ff9b::7f00:1",
                   "::ffff:127.0.0.1", "::ffff:10.0.0.1", "::ffff:192.168.1.1", "::127.0.0.1", "2001:0:4136:e378:8000:63bf:3fff:fdd2"]
        for a in bad { XCTAssertEqual(dest([a]).failureValue, .notPublic, a) }
    }

    func testMixedPublicAndPrivateAnswersAreRefused() {
        XCTAssertEqual(dest(["93.184.216.34", "127.0.0.1"]).failureValue, .notPublic, "one bad address poisons the name (rebinding)")
        XCTAssertEqual(dest(["127.0.0.1", "93.184.216.34"]).failureValue, .notPublic)
        XCTAssertEqual(dest(["93.184.216.34", "::1"]).failureValue, .notPublic)
        XCTAssertEqual(dest(["93.184.216.34", "10.0.0.1", "8.8.8.8"]).failureValue, .notPublic)
    }

    func testResolverFailureFailsClosed() {
        XCTAssertEqual(dest(nil).failureValue, .unresolvable)
        XCTAssertEqual(dest([]).failureValue, .unresolvable)
        XCTAssertEqual(dest(["not-an-address"]).failureValue, .notPublic)
        XCTAssertEqual(dest([""]).failureValue, .notPublic)
        XCTAssertEqual(dest(["93.184.216.34", "garbage"]).failureValue, .notPublic)
    }

    func testStartVettingRunsTheSameValidatorAndResolver() {
        let public1: ImportURLPolicy.Resolver = { _ in ["93.184.216.34"] }
        let rebinding: ImportURLPolicy.Resolver = { _ in ["93.184.216.34", "127.0.0.1"] }
        XCTAssertNotNil(try? ImportURLPolicy.vetStart("https://example.com/a.mp3", resolver: public1).get())
        if case .failure(.invalid(.notHTTPS)) = ImportURLPolicy.vetStart("http://example.com/a.mp3", resolver: public1) {} else { XCTFail() }
        if case .failure(.invalid(.notAPublicName)) = ImportURLPolicy.vetStart("https://127.0.0.1/a.mp3", resolver: public1) {} else { XCTFail() }
        if case .failure(.destination(.notPublic)) = ImportURLPolicy.vetStart("https://example.com/a.mp3", resolver: rebinding) {} else { XCTFail() }
    }

    // MARK: redirects (every hop is vetted like the first request)

    func testRedirectHopsAreVettedWithTheSameRules() {
        let from = URL(string: "https://cdn.example.com/a.mp3")!
        let table: [String: [String]] = ["good.example.org": ["93.184.216.34"], "rebind.example.org": ["93.184.216.34", "127.0.0.1"],
                                         "lan.example.org": ["192.168.1.1"], "meta.example.org": ["169.254.169.254"]]
        let resolver: ImportURLPolicy.Resolver = { table[$0] }
        func vet(_ to: String?, _ n: Int = 0) -> ImportURLPolicy.RedirectDecision {
            ImportURLPolicy.vetRedirect(from: from, to: to.flatMap { URL(string: $0) }, count: n, resolver: resolver)
        }
        XCTAssertEqual(vet("https://good.example.org/b.mp3"), .follow(URL(string: "https://good.example.org/b.mp3")!))
        XCTAssertEqual(vet("https://good.example.org/b.mp3", 4), .follow(URL(string: "https://good.example.org/b.mp3")!))
        let refused: [(String?, Int)] = [
            ("https://good.example.org/b.mp3", 5), ("http://good.example.org/b.mp3", 0), ("https://rebind.example.org/b", 0),
            ("https://lan.example.org/b", 0), ("https://meta.example.org/latest", 0), ("https://127.0.0.1/b", 0),
            ("https://localhost/b", 0), ("https://[::1]/b", 0), ("https://10.0.0.1/b", 0), ("file:///etc/passwd", 0),
            ("ftp://good.example.org/b", 0), ("https://u:p@good.example.org/b", 0), ("https://unknown.example.org/b", 0), (nil, 0),
        ]
        for (to, n) in refused {
            if case .refuse = vet(to, n) {} else { XCTFail("must refuse \(to ?? "nil") at hop \(n)") }
        }
    }

    func testHostileRedirectChainStopsAtFirstBadHopAndAtFiveHops() {
        let resolver: ImportURLPolicy.Resolver = { host in host == "evil.example.org" ? ["127.0.0.1"] : ["93.184.216.34"] }
        func walk(_ chain: [String]) -> Int? {   // index of the first refused hop, nil if all followed
            var current = URL(string: "https://start.example.com/x")!
            for (i, next) in chain.enumerated() {
                switch ImportURLPolicy.vetRedirect(from: current, to: URL(string: next), count: i, resolver: resolver) {
                case .follow(let u): current = u
                case .refuse: return i
                }
            }
            return nil
        }
        XCTAssertNil(walk((0..<5).map { "https://h\($0).example.com/" }))
        XCTAssertEqual(walk((0..<9).map { "https://h\($0).example.com/" }), 5, "sixth redirect refused")
        XCTAssertEqual(walk(["https://a.example.com/", "https://evil.example.org/", "https://b.example.com/"]), 1)
        XCTAssertEqual(walk(["https://a.example.com/", "http://b.example.com/"]), 1, "downgrade")
        XCTAssertEqual(walk(["https://a.example.com/", "https://192.168.0.1/"]), 1)
    }

    // MARK: streaming guard

    private let wav = Data("RIFF".utf8) + Data([0x24, 0, 0, 0]) + Data("WAVEfmt ".utf8)

    func testStreamGuardEnforcesTheCapWhateverTheHeadersSaid() {
        var g = ImportStreamGuard(limit: 1000)
        XCTAssertEqual(g.accept(wav), .ok)
        XCTAssertEqual(g.accept(Data(count: 900)), .ok)
        XCTAssertEqual(g.accept(Data(count: 100)), .tooLarge)
        // A never-ending body is cut off at the cap, in bounded steps.
        var endless = ImportStreamGuard(limit: 1_000_000)
        var chunks = 0, verdict = ImportStreamGuard.Verdict.ok
        while verdict == .ok && chunks < 10_000 {
            verdict = endless.accept(chunks == 0 ? wav + Data(count: 65_536) : Data(count: 65_536)); chunks += 1
        }
        XCTAssertEqual(verdict, .tooLarge)
        XCTAssertLessThan(chunks, 20)
        XCTAssertEqual(ImportURLPolicy.maxDownloadBytes, 2_147_483_648)
    }

    func testStreamGuardJudgesTheTypeByMagicBytesNotByNameOrContentType() {
        func verdict(_ d: Data) -> ImportStreamGuard.Verdict { var g = ImportStreamGuard(); return g.accept(d + Data(count: 64)) }
        XCTAssertEqual(verdict(wav), .ok)
        XCTAssertEqual(verdict(Data("ID3".utf8) + Data([4, 0, 0, 0, 0, 0, 0, 0, 0, 0])), .ok)
        XCTAssertEqual(verdict(Data([0xff, 0xfb, 0x90, 0x00] + [UInt8](repeating: 0, count: 10))), .ok)
        XCTAssertEqual(verdict(Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8)), .ok)
        XCTAssertEqual(verdict(Data("OggS".utf8) + Data(count: 12)), .ok)
        XCTAssertEqual(verdict(Data("fLaC".utf8) + Data(count: 12)), .ok)
        XCTAssertEqual(verdict(Data([0x1a, 0x45, 0xdf, 0xa3]) + Data(count: 12)), .ok)
        XCTAssertEqual(verdict(Data("<!DOCTYPE html><html>".utf8)), .notMedia)
        XCTAssertEqual(verdict(Data("MZ".utf8) + Data(count: 30)), .notMedia, "an .exe named .mp3")
        XCTAssertEqual(verdict(Data("#!/bin/sh\nrm -rf ~\n".utf8)), .notMedia)
        XCTAssertEqual(verdict(Data("PK".utf8) + Data([3, 4]) + Data(count: 20)), .notMedia)
        var g = ImportStreamGuard()
        XCTAssertEqual(g.accept(Data("<ht".utf8)), .ok)
        XCTAssertEqual(g.accept(Data("ml>12345678".utf8)), .notMedia)
        var tiny = ImportStreamGuard(); _ = tiny.accept(Data("abc".utf8)); XCTAssertEqual(tiny.finish(), .notMedia)
    }

    func testFeedEnclosuresPointingAtLocalOrForeignSchemesAreDropped() throws {
        let urls = ["https://127.0.0.1/a.mp3", "https://10.0.0.5/a.mp3", "https://192.168.1.1/a.mp3", "https://169.254.169.254/latest",
                    "https://localhost:11434/api", "https://[::1]/a.mp3", "http://example.com/a.mp3", "file:///etc/passwd",
                    "ftp://example.com/a.mp3", "https://u:p@example.com/a.mp3", "https://2130706433/a.mp3", "https://0x7f.1/a.mp3",
                    "//example.com/a.mp3", "/a.mp3"]
        var xml = "<rss><channel>"
        for (i, u) in urls.enumerated() { xml += "<item><title>t\(i)</title><enclosure url=\"\(u)\" type=\"audio/mpeg\"/></item>" }
        xml += "<item><title>ok</title><enclosure url=\"https://cdn.example.com/ok.mp3\" type=\"audio/mpeg\"/></item></channel></rss>"
        XCTAssertEqual(try FeedParser.parse(Data(xml.utf8)).get().map(\.title), ["ok"])
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
