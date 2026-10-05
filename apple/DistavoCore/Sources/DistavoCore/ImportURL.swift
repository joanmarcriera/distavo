import Foundation
import Darwin

// Pure rules for "Import from URL..." (Vikunja #2955, Direct edition): URL validation,
// download policy (size cap, redirects, content types, file naming) and a hardened RSS/Atom
// enclosure parser. No networking and no file I/O here, so every rule is unit-tested with
// hostile inputs. The Direct app target (`Import/`) performs the actual, user-initiated
// download and calls these rules at each step. Compiled into every edition; used only by Direct.
//
// This is the one place Distavo fetches from the internet, and only because the user pasted
// an address and pressed Download. Nothing is uploaded.

public enum ImportURLPolicy {
    public static let maxURLLength = 2048
    /// Hard cap on a downloaded media file, enforced while streaming.
    public static let maxDownloadBytes: Int64 = 2 * 1024 * 1024 * 1024
    public static let maxFeedBytes = 5 * 1024 * 1024
    public static let maxRedirects = 5
    public static let maxFeedItems = 200
    /// How many newest enclosures the picker offers.
    public static let pickerCount = 15

    public enum Problem: Error, Equatable, Sendable {
        case empty, tooLong, malformed, notHTTPS, hasCredentials, noHost, insecureNotLocal
    }

    public struct Validated: Equatable, Sendable {
        public let url: URL
        /// Plain http to a loopback / LAN host: allowed, but the UI must warn.
        public let isInsecureLocal: Bool
    }

    /// Validate a pasted or feed-supplied address. https only; http only for loopback/LAN hosts.
    /// The returned `url` is rebuilt from the PARSED components (never the original string).
    public static func validate(_ raw: String) -> Result<Validated, Problem> {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .failure(.empty) }
        if s.utf8.count > maxURLLength { return .failure(.tooLong) }
        if s.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7f || $0.value > 0x7e }) {
            return .failure(.malformed)   // whitespace, controls and non-ASCII (use the percent-encoded form)
        }
        guard let comps = URLComponents(string: s), let scheme = comps.scheme?.lowercased() else { return .failure(.malformed) }
        guard scheme == "https" || scheme == "http" else { return .failure(.notHTTPS) }
        guard comps.user == nil, comps.password == nil else { return .failure(.hasCredentials) }
        guard let host = comps.host, !host.isEmpty else { return .failure(.noHost) }
        if let port = comps.port, !(1...65535).contains(port) { return .failure(.malformed) }
        var insecure = false
        if scheme == "http" {
            guard isLoopbackOrLAN(host: host) else { return .failure(.insecureNotLocal) }
            insecure = true
        }
        var rebuilt = URLComponents()
        rebuilt.scheme = scheme
        rebuilt.host = host.lowercased()
        rebuilt.port = comps.port
        rebuilt.percentEncodedPath = comps.percentEncodedPath.isEmpty ? "/" : comps.percentEncodedPath
        rebuilt.percentEncodedQuery = comps.percentEncodedQuery
        guard let url = rebuilt.url else { return .failure(.malformed) }
        return .success(Validated(url: url, isInsecureLocal: insecure))
    }

    /// Host is `localhost`, a `.local` name, or a loopback / private / link-local IP LITERAL.
    /// No DNS is done here: a name that merely resolves to a LAN address is NOT trusted.
    public static func isLoopbackOrLAN(host rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let a = UInt32(bigEndian: v4.s_addr)
            let b0 = a >> 24, b1 = (a >> 16) & 0xff
            return b0 == 127 || b0 == 10 || (b0 == 172 && (16...31).contains(b1))
                || (b0 == 192 && b1 == 168) || (b0 == 169 && b1 == 254)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            let isLoop = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            return isLoop || (bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
        }
        return false
    }

    // MARK: redirects

    public enum RedirectDecision: Equatable, Sendable {
        case follow(URL)
        case refuse(String)
    }

    /// Decide whether to follow a redirect. `count` = redirects already followed.
    /// Refuses: more than 5 hops, https -> http downgrade, an invalid target, and a PUBLIC
    /// origin redirecting into loopback / LAN space (SSRF-style pivot).
    public static func redirect(from: URL, to target: URL?, count: Int) -> RedirectDecision {
        guard count < maxRedirects else { return .refuse("too many redirects") }
        guard let target, case .success(let ok) = validate(target.absoluteString) else {
            return .refuse("the redirect target is not an acceptable address")
        }
        if from.scheme?.lowercased() == "https", ok.url.scheme == "http" { return .refuse("refused a redirect from https to http") }
        let fromLocal = isLoopbackOrLAN(host: from.host ?? "")
        if !fromLocal, ok.isInsecureLocal || isLoopbackOrLAN(host: ok.url.host ?? "") {
            return .refuse("refused a redirect from a public address to this network")
        }
        return .follow(ok.url)
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
