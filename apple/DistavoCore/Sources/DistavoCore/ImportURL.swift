import Foundation
import Darwin

// Pure rules for "Import from URL..." (Vikunja #2955, Direct edition): URL validation,
// destination (resolver) vetting, download policy (size cap, redirects, content types, file
// naming, magic bytes) and a hardened RSS/Atom enclosure parser. No networking and no file I/O
// here, so every rule is unit-tested with hostile inputs. The Direct app target (`Import/`)
// performs the actual, user-initiated download and calls these rules at EVERY hop. Compiled
// into every edition; used only by Direct.
//
// This is the one place Distavo fetches from the internet, and only because the user pasted
// an address and pressed Download. Nothing is uploaded.
//
// SSRF POLICY (an import is a request to a stranger's server, never to this Mac or this network):
//  - ONE validator (`validate`) is applied to the pasted URL, every feed enclosure URL and every
//    redirect Location. https only; no user info; the host must be a DNS NAME: IP literals in any
//    notation (dotted, decimal, hex, octal, IPv6), `localhost`, single-label and `.local` /
//    `.localhost` / `.internal` / `.lan` / `.home.arpa` names are refused.
//  - ONE destination check (`checkDestination`) resolves the name ONCE through an injected
//    resolver and requires EVERY returned address to be PUBLIC (refusing loopback, private,
//    link-local, CGNAT, ULA, multicast, unspecified, reserved/documentation, NAT64, 6to4 and
//    IPv4-mapped/compatible forms of those). Anything unresolvable fails closed.
//  - There is deliberately NO "allow a server on my network" option: plain http and LAN
//    destinations are refused outright (use Finder or the Transcribe File shortcut for local files).
//  - RESIDUAL RISK, stated plainly: the connection itself is made by URLSession, which resolves the
//    name again, so a DNS answer that changes between our check and the connection is not pinned.
//    https keeps the host name so TLS must present a certificate valid for that name, which a
//    local plain-http service (Ollama, the MCP server, a router page) cannot. Same trade-off as
//    docs/ask-local-only.md. The system proxy, if you have one configured, is honoured: an import
//    is ordinary internet traffic.

public enum ImportURLPolicy {
    public static let maxURLLength = 2048
    /// Hard cap on a downloaded media file, enforced while streaming (decoded bytes).
    public static let maxDownloadBytes: Int64 = 2 * 1024 * 1024 * 1024
    public static let maxFeedBytes = 5 * 1024 * 1024
    public static let maxRedirects = 5
    public static let maxFeedItems = 200
    /// How many newest enclosures the picker offers.
    public static let pickerCount = 15

    public enum Problem: Error, Equatable, Sendable {
        case empty, tooLong, malformed, notHTTPS, hasCredentials, noHost, notAPublicName
    }

    public struct Validated: Equatable, Sendable {
        public let url: URL
    }

    /// Validate a pasted, feed-supplied or redirect-supplied address. The returned `url` is
    /// rebuilt from the PARSED components (never the original string).
    public static func validate(_ raw: String) -> Result<Validated, Problem> {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .failure(.empty) }
        if s.utf8.count > maxURLLength { return .failure(.tooLong) }
        if s.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value > 0x7e }) {
            return .failure(.malformed)   // whitespace, controls, DEL and non-ASCII (use the percent-encoded form)
        }
        guard let comps = URLComponents(string: s), let scheme = comps.scheme?.lowercased() else { return .failure(.malformed) }
        guard scheme == "https" else { return .failure(.notHTTPS) }
        guard comps.user == nil, comps.password == nil else { return .failure(.hasCredentials) }
        guard let host = comps.host?.lowercased(), !host.isEmpty else { return .failure(.noHost) }
        if let port = comps.port, !(1...65535).contains(port) { return .failure(.malformed) }
        guard isPublicDNSName(host) else { return .failure(.notAPublicName) }
        var rebuilt = URLComponents()
        rebuilt.scheme = "https"
        rebuilt.host = host
        rebuilt.port = comps.port
        rebuilt.percentEncodedPath = comps.percentEncodedPath.isEmpty ? "/" : comps.percentEncodedPath
        rebuilt.percentEncodedQuery = comps.percentEncodedQuery
        guard let url = rebuilt.url else { return .failure(.malformed) }
        return .success(Validated(url: url))
    }

    /// A syntactically plausible public DNS name: letters/digits/hyphens in labels, at least two
    /// labels, a non-numeric TLD, and none of the local-only suffixes. Rejects every numeric
    /// notation an IP could hide in (`127.1`, `2130706433`, `0x7f.0.0.1`, `0177.0.0.1`, `[::1]`).
    static func isPublicDNSName(_ host: String) -> Bool {
        guard host.utf8.count <= 253, !host.hasSuffix(".") || host.dropLast().contains(".") else { return false }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for l in labels {
            guard (1...63).contains(l.utf8.count), !l.hasPrefix("-"), !l.hasSuffix("-"),
                  l.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x2d }) else { return false }
        }
        // A numeric last label means an IP in some notation (or a typo): refuse. Real TLDs contain letters.
        guard let tld = labels.last, tld.utf8.contains(where: { $0 >= 0x61 && $0 <= 0x7a }) else { return false }
        if tld.hasPrefix("xn--") == false, tld.utf8.count < 2 { return false }
        let blockedSuffixes = ["localhost", "local", "internal", "lan", "home", "corp", "intranet", "private", "test", "invalid", "arpa"]
        if blockedSuffixes.contains(String(tld)) { return false }
        return true
    }

    // MARK: destination (resolver) vetting

    /// Resolves `host` to numeric address strings (getaddrinfo in the app; a fake in tests).
    public typealias Resolver = (_ host: String) -> [String]?

    public enum DestinationProblem: Error, Equatable, Sendable {
        case unresolvable, notPublic
    }

    /// Resolve once and require EVERY address to be public; fail closed on nil/empty/unparseable.
    public static func checkDestination(_ url: URL, resolver: Resolver) -> Result<Void, DestinationProblem> {
        guard let host = url.host, !host.isEmpty, let addresses = resolver(host), !addresses.isEmpty else {
            return .failure(.unresolvable)
        }
        for a in addresses {
            guard let kind = classify(address: a), kind == .publicAddress else { return .failure(.notPublic) }
        }
        return .success(())
    }

    public enum AddressClass: Equatable, Sendable { case publicAddress, notPublic }

    /// Classify a NUMERIC address string. nil = not a parseable address (callers fail closed).
    public static func classify(address raw: String) -> AddressClass? {
        let a = raw.split(separator: "%", maxSplits: 1).first.map(String.init) ?? raw   // drop a zone id
        var v4 = in_addr()
        if inet_pton(AF_INET, a, &v4) == 1 { return isPublicV4(UInt32(bigEndian: v4.s_addr)) ? .publicAddress : .notPublic }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, a, &v6) == 1 {
            let b = withUnsafeBytes(of: &v6) { Array($0) }
            return isPublicV6(b) ? .publicAddress : .notPublic
        }
        return nil
    }

    static func isPublicV4(_ a: UInt32) -> Bool {
        let b0 = a >> 24, b1 = (a >> 16) & 0xff, b2 = (a >> 8) & 0xff
        switch b0 {
        case 0, 10, 127: return false
        case 100: return !(64...127).contains(b1)                       // CGNAT 100.64/10
        case 169: return b1 != 254                                      // link-local
        case 172: return !(16...31).contains(b1)
        case 192:
            if b1 == 168 { return false }
            if b1 == 0 && (b2 == 0 || b2 == 2) { return false }         // 192.0.0/24, 192.0.2/24
            return true
        case 198:
            if b1 == 18 || b1 == 19 { return false }                    // benchmarking
            if b1 == 51 && b2 == 100 { return false }                   // documentation
            return true
        case 203: return !(b1 == 0 && b2 == 113)                        // documentation
        case 224...255: return false                                    // multicast, reserved, broadcast
        default: return true
        }
    }

    static func isPublicV6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        let v4 = { (o: Int) -> UInt32 in (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3]) }
        // ::ffff:a.b.c.d (mapped) and ::a.b.c.d (compatible): judged by the embedded IPv4 address.
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return isPublicV4(v4(12)) }
        if b[0..<12].allSatisfy({ $0 == 0 }) { return false }           // ::, ::1, ::/96 compatible
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b { return false }   // 64:ff9b::/96 NAT64: refuse all
        if b[0] == 0x20 && b[1] == 0x02 { return false }                // 2002::/16 6to4
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 { return false }   // documentation
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00 { return false }   // Teredo
        // Only global unicast 2000::/3 is allowed; everything else (ULA, link-local, multicast, ...) is not.
        return (b[0] & 0xe0) == 0x20
    }

    // MARK: redirects

    public enum RedirectDecision: Equatable, Sendable {
        case follow(URL)
        case refuse(String)
    }

    /// Decide whether to follow a redirect. `count` = redirects already followed. Applies THE SAME
    /// validator and destination check as the pasted URL: > 5 hops, a non-https / non-public-name /
    /// credentialed target, or a target whose name resolves to any non-public address is refused.
    public static func vetRedirect(from: URL, to target: URL?, count: Int, resolver: Resolver) -> RedirectDecision {
        guard count < maxRedirects else { return .refuse("too many redirects") }
        guard let target, case .success(let ok) = validate(target.absoluteString) else {
            return .refuse("the redirect target is not an acceptable address")
        }
        if case .failure = checkDestination(ok.url, resolver: resolver) {
            return .refuse("the redirect target is not a public internet address")
        }
        return .follow(ok.url)
    }

    /// Validate AND resolve-check a starting URL (pasted or from a feed) in one call.
    public static func vetStart(_ raw: String, resolver: Resolver) -> Result<URL, StartProblem> {
        switch validate(raw) {
        case .failure(let p): return .failure(.invalid(p))
        case .success(let ok):
            if case .failure(let d) = checkDestination(ok.url, resolver: resolver) { return .failure(.destination(d)) }
            return .success(ok.url)
        }
    }

    public enum StartProblem: Error, Equatable, Sendable {
        case invalid(Problem)
        case destination(DestinationProblem)
    }

    // MARK: response checks

    public enum ResponseKind: Equatable, Sendable { case media(fileName: String), feed }

    public enum ResponseProblem: Error, Equatable, Sendable {
        case badStatus(Int), tooLarge, unsupportedType
    }

    static let mimeExtensions: [String: String] = [
        "audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/m4a": "m4a",
        "audio/aac": "aac", "audio/wav": "wav", "audio/x-wav": "wav", "audio/wave": "wav", "audio/ogg": "ogg",
        "audio/opus": "opus", "audio/flac": "flac", "audio/x-flac": "flac", "audio/webm": "webm",
        "video/mp4": "mp4", "video/quicktime": "mov", "video/x-m4v": "m4v", "video/webm": "webm",
        "video/x-matroska": "mkv", "video/3gpp": "3gp",
    ]
    static let feedTypes: Set<String> = ["application/rss+xml", "application/atom+xml", "application/xml", "text/xml", "application/rdf+xml"]

    /// `type; params` -> lower-cased media type.
    static func mediaType(_ contentType: String?) -> String {
        (contentType ?? "").split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    /// Classify a response from its HEADERS, before any body byte is read. `declaredLength` is
    /// only a hint for early refusal; the real cap is enforced while streaming (`withinCap`).
    public static func classify(status: Int, contentType: String?, declaredLength: Int64?, url: URL)
        -> Result<ResponseKind, ResponseProblem> {
        guard status == 200 else { return .failure(.badStatus(status)) }
        let type = mediaType(contentType)
        if feedTypes.contains(type) { return .success(.feed) }
        if let n = declaredLength, n > maxDownloadBytes { return .failure(.tooLarge) }
        let urlExt = (url.path as NSString).pathExtension.lowercased()
        let urlHasMedia = QueuedFile.isSupportedMedia("x." + urlExt)
        let typeExt = mimeExtensions[type]
        let genericBinary = ["application/octet-stream", "binary/octet-stream", ""].contains(type)
        // Accept: a media content type, or a generic one when the URL's extension is a supported one.
        guard typeExt != nil || (genericBinary && urlHasMedia) else { return .failure(.unsupportedType) }
        let ext = urlHasMedia ? urlExt : (typeExt ?? "m4a")
        return .success(.media(fileName: fileName(for: url, fallbackExtension: ext)))
    }

    /// A safe file name from the URL path (NEVER from Content-Disposition), through the same
    /// sanitiser every queued file uses; guaranteed to end in a supported media extension.
    public static func fileName(for url: URL, fallbackExtension: String) -> String {
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        var name = QueuedFile.sanitizedName(last == "/" || last.isEmpty ? "download" : last)
        if !QueuedFile.isSupportedMedia(name) { name += "." + fallbackExtension }
        return QueuedFile.sanitizedName(name)
    }

    /// True while `received` bytes are within the cap (check on every chunk).
    public static func withinCap(received: Int64, limit: Int64 = maxDownloadBytes) -> Bool { received <= limit }
}

// MARK: - Feed parsing

public struct FeedEnclosure: Equatable, Sendable {
    public let title: String
    public let url: URL
    public let mimeType: String?
    public let bytes: Int64?
}

public enum FeedParser {
    public enum Failure: Error, Equatable, Sendable {
        case tooLarge, forbiddenConstruct, notAFeed, malformed
    }

    /// Parse an RSS 2.0 or Atom feed into its enclosures, FEED ORDER (newest first in practice).
    ///
    /// Hardening: size cap; any DTD / entity declaration is refused up front (RSS and Atom never
    /// need one, and without them XXE and entity-expansion "billion laughs" cannot start);
    /// NUL bytes are refused (UTF-16/32 would slip past the ASCII scan); external entities are
    /// also switched off in `XMLParser`; item count and element depth are capped; every
    /// enclosure URL must pass `ImportURLPolicy.validate`; titles are neutralised and bounded.
    public static func parse(_ data: Data, limit: Int = ImportURLPolicy.maxFeedItems) -> Result<[FeedEnclosure], Failure> {
        if data.count > ImportURLPolicy.maxFeedBytes { return .failure(.tooLarge) }
        if data.contains(0) { return .failure(.forbiddenConstruct) }
        let lower = String(decoding: data, as: UTF8.self).lowercased()
        if lower.contains("<!doctype") || lower.contains("<!entity") || lower.contains("<!element") || lower.contains("<!attlist") {
            return .failure(.forbiddenConstruct)
        }
        let delegate = Delegate(itemLimit: limit)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = delegate
        let ok = parser.parse()
        if let f = delegate.failure { return .failure(f) }
        if !ok && !delegate.stoppedOnPurpose { return .failure(.malformed) }
        guard delegate.sawFeedRoot else { return .failure(.notAFeed) }
        return .success(delegate.enclosures)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let itemLimit: Int
        var enclosures: [FeedEnclosure] = []
        var failure: Failure?
        var stoppedOnPurpose = false
        var sawFeedRoot = false
        private var depth = 0
        private var items = 0
        private var inItem = false
        private var titleBuffer = ""
        private var collectingTitle = false
        private var itemTitle = ""
        private var itemEnclosures: [(url: String, type: String?, length: Int64?)] = []

        init(itemLimit: Int) { self.itemLimit = itemLimit }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String] = [:]) {
            depth += 1
            if depth > 64 { failure = .forbiddenConstruct; parser.abortParsing(); return }
            switch name {
            case "rss", "feed", "rdf:RDF": sawFeedRoot = true
            case "item", "entry":
                inItem = true; items += 1; itemTitle = ""; itemEnclosures = []
                if items > itemLimit { stoppedOnPurpose = true; inItem = false; parser.abortParsing() }
            case "title" where inItem: collectingTitle = true; titleBuffer = ""
            case "enclosure" where inItem:
                if let u = a["url"] { itemEnclosures.append((u, a["type"], a["length"].flatMap { Int64($0) })) }
            case "link" where inItem && a["rel"] == "enclosure":
                if let u = a["href"] { itemEnclosures.append((u, a["type"], a["length"].flatMap { Int64($0) })) }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters s: String) {
            if collectingTitle, titleBuffer.count < 1000 { titleBuffer += s }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            depth -= 1
            switch name {
            case "title" where collectingTitle:
                collectingTitle = false
                if itemTitle.isEmpty { itemTitle = titleBuffer }
            case "item", "entry":
                guard inItem else { break }
                inItem = false
                let title = Self.clean(itemTitle)
                for e in itemEnclosures {
                    guard case .success(let ok) = ImportURLPolicy.validate(e.url) else { continue }
                    enclosures.append(FeedEnclosure(title: title.isEmpty ? "(untitled)" : title, url: ok.url,
                                                    mimeType: e.type.map { String($0.prefix(100)) }, bytes: e.length))
                }
            default: break
            }
        }

        /// Bounded, single-line, terminal-safe title.
        static func clean(_ s: String) -> String {
            let one = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            return TerminalSafe.neutralised(String(one.prefix(200)))
        }
    }
}

// MARK: - Streaming guard

/// Applied to every chunk of a download AS IT ARRIVES (decoded bytes: URLSession undoes any
/// gzip/deflate, so a compression bomb is capped at the same limit as a plain file). It enforces
/// the size cap regardless of Content-Length, and decides the file TYPE from its magic bytes, not
/// from the URL extension or Content-Type, which a hostile server controls.
public struct ImportStreamGuard {
    public enum Verdict: Equatable, Sendable { case ok, tooLarge, notMedia }

    public let limit: Int64
    public private(set) var received: Int64 = 0
    private var head = Data()
    private var typeChecked = false

    public init(limit: Int64 = ImportURLPolicy.maxDownloadBytes) { self.limit = limit }

    public mutating func accept(_ chunk: Data) -> Verdict {
        received += Int64(chunk.count)
        guard ImportURLPolicy.withinCap(received: received, limit: limit) else { return .tooLarge }
        if !typeChecked {
            head.append(chunk.prefix(32 - head.count))
            if head.count >= 12 { typeChecked = true; if !Self.looksLikeMedia(head) { return .notMedia } }
        }
        return .ok
    }

    /// Call when the body ends: a file shorter than 12 bytes never got its type check.
    public func finish() -> Verdict { typeChecked || Self.looksLikeMedia(head) ? .ok : .notMedia }

    /// Container signatures of the formats the app accepts (wav, mp3/aac, mp4/m4a/mov/3gp, ogg/opus, flac, webm/mkv).
    public static func looksLikeMedia(_ d: Data) -> Bool {
        let b = [UInt8](d.prefix(16))
        guard b.count >= 4 else { return false }
        func at(_ o: Int, _ s: String) -> Bool { b.count >= o + s.utf8.count && Array(b[o..<(o + s.utf8.count)]) == Array(s.utf8) }
        if at(0, "RIFF") && at(8, "WAVE") { return true }
        if at(0, "ID3") { return true }
        if b[0] == 0xff && (b[1] & 0xe0) == 0xe0 { return true }            // MPEG audio / ADTS AAC frame sync
        if at(4, "ftyp") { return true }                                    // ISO base media
        if at(0, "OggS") || at(0, "fLaC") { return true }
        if b[0] == 0x1a && b[1] == 0x45 && b[2] == 0xdf && b[3] == 0xa3 { return true }   // EBML
        return false
    }
}
