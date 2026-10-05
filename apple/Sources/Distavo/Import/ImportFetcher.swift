#if EDITION_DIRECT
import Foundation
import DistavoCore

/// The network half of "Import from URL..." (Vikunja #2955, Direct edition only). One instance
/// performs ONE user-initiated GET. Every rule lives in DistavoCore (`ImportURLPolicy`,
/// `FeedParser`); this class only applies them as the bytes arrive:
///  - ephemeral session: no cookies, no cache, no stored credentials; authentication
///    challenges other than TLS server trust are cancelled;
///  - the start URL and EVERY redirect target go through the same checks: `ImportURLPolicy.validate`
///    (https, public DNS name, no user info) and `checkDestination`, which resolves the name once and
///    requires EVERY address to be public (`ImportResolver` = getaddrinfo). <= 5 redirects. The URLSession
///    connection re-resolves the name (not pinned; https keeps the host name so TLS must match it, see
///    ImportURL.swift); the system proxy, if configured, is honoured;
///  - the response is classified from its headers BEFORE any body is kept;
///  - the size cap is enforced on every received (decoded) chunk by `ImportStreamGuard`, never trusted
///    from Content-Length, and `Accept-Encoding: identity` is sent so no compression is requested; the file
///    type is decided from its magic bytes, not the URL extension or Content-Type;
///  - a media file is written into a fresh private (0700) temp folder with an exclusive create,
///    under a name from the URL path (never Content-Disposition) via the shared sanitiser;
///  - timeouts: 30 s idle, 2 h overall; cancellable.
/// Nothing is uploaded: the request is a plain GET with no body and a fixed User-Agent.
final class ImportFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    enum Outcome {
        case feed([FeedEnclosure])
        case file(url: URL, name: String, directory: URL)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let queue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1; return q
    }()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Outcome, Error>?
    private var originalURL: URL?
    private var redirects = 0
    private var refusedRedirect: String?
    private var kind: ImportURLPolicy.ResponseKind?
    private var feedBuffer = Data()
    private var handle: FileHandle?
    private var directory: URL?
    private var fileURL: URL?
    private var received: Int64 = 0
    private var streamGuard = ImportStreamGuard()
    private var failure: Failure?
    private var onProgress: (@Sendable (Int64) -> Void)?

    /// Fetch `url` (already validated by the caller). Cancel the surrounding Task, or call `cancel()`.
    func fetch(_ url: URL, onProgress: (@Sendable (Int64) -> Void)? = nil) async throws -> Outcome {
        // The same validator + public-address check as every other hop, BEFORE any request is made.
        let vetted = await Task.detached { ImportURLPolicy.vetStart(url.absoluteString, resolver: ImportResolver.resolve) }.value
        guard case .success(let url) = vetted else {
            throw Failure(message: "That address is not a public internet address Distavo will download from.")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Outcome, Error>) in
                queue.addOperation { [self] in
                    continuation = c
                    originalURL = url
                    self.onProgress = onProgress
                    let cfg = URLSessionConfiguration.ephemeral
                    cfg.httpCookieStorage = nil
                    cfg.httpShouldSetCookies = false
                    cfg.urlCredentialStorage = nil
                    cfg.urlCache = nil
                    cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                    cfg.timeoutIntervalForRequest = 30
                    cfg.timeoutIntervalForResource = 7200
                    cfg.waitsForConnectivity = false
                    cfg.httpAdditionalHeaders = ["User-Agent": "Distavo URL import", "Accept-Encoding": "identity"]
                    let s = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
                    session = s
                    var req = URLRequest(url: url)
                    req.httpMethod = "GET"
                    let t = s.dataTask(with: req)
                    task = t
                    t.resume()
                }
            }
        } onCancel: { [self] in cancel() }
    }

    func cancel() { queue.addOperation { [self] in task?.cancel() } }

    // MARK: delegate (serial queue)

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let from = task.currentRequest?.url ?? originalURL ?? request.url!
        let count = redirects, target = request.url
        // Resolution blocks, so it runs off the session queue; the completion handler may be called from any thread.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            switch ImportURLPolicy.vetRedirect(from: from, to: target, count: count, resolver: ImportResolver.resolve) {
            case .follow(let url):
                queue.addOperation { redirects += 1 }
                completionHandler(URLRequest(url: url))   // rebuilt from the validated URL, headers not carried
            case .refuse(let why):
                queue.addOperation { refusedRedirect = why }
                completionHandler(nil)                    // the 3xx itself becomes the response -> classified as an error
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // TLS server-trust evaluation only; never answer a password challenge.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = http.url else {
            fail("The server sent an unexpected response."); completionHandler(.cancel); return
        }
        let declared = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        switch ImportURLPolicy.classify(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"),
                                        declaredLength: declared, url: url) {
        case .failure(let problem):
            switch problem {
            case .badStatus(let s):
                fail(refusedRedirect.map { "Download refused: \($0)." } ?? "The server answered with status \(s).")
            case .tooLarge: fail("The file is larger than the 2 GB limit.")
            case .unsupportedType: fail("That address is not an audio or video file or an RSS/Atom feed.")
            }
            completionHandler(.cancel)
        case .success(let k):
            kind = k
            if case .media(let name) = k {
                do { try openTemp(named: name) } catch { fail("Could not create a temporary file."); completionHandler(.cancel); return }
            }
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        received += Int64(data.count)
        switch kind {
        case .feed?:
            guard received <= Int64(ImportURLPolicy.maxFeedBytes) else { fail("The feed is too large."); dataTask.cancel(); return }
            feedBuffer.append(data)
        case .media?:
            // Cap and file type are judged on the bytes actually received, whatever the headers claimed.
            switch streamGuard.accept(data) {
            case .tooLarge: fail("The file is larger than the 2 GB limit."); dataTask.cancel(); return
            case .notMedia: fail("The download is not an audio or video file."); dataTask.cancel(); return
            case .ok: break
            }
            do { try handle?.write(contentsOf: data) } catch { fail("Could not write the download to disk."); dataTask.cancel(); return }
            onProgress?(received)
        case nil: break
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.invalidateAndCancel(); self.session = nil }
        if let failure { finish(.failure(failure)); return }
        if let error {
            let ns = error as NSError
            cleanup()
            finish(.failure(ns.code == NSURLErrorCancelled ? CancellationError() : Failure(message: ns.localizedDescription)))
            return
        }
        switch kind {
        case .feed?:
            switch FeedParser.parse(feedBuffer) {
            case .success(let items):
                finish(.success(.feed(items)))
            case .failure(.forbiddenConstruct): finish(.failure(Failure(message: "The feed uses features that Distavo refuses for safety.")))
            case .failure(.tooLarge): finish(.failure(Failure(message: "The feed is too large.")))
            case .failure: finish(.failure(Failure(message: "That is not a readable RSS or Atom feed.")))
            }
        case .media(let name)?:
            try? handle?.close(); handle = nil
            guard streamGuard.finish() == .ok else { cleanup(); finish(.failure(Failure(message: "The download is not an audio or video file."))); return }
            guard received > 0, let fileURL, let directory else { cleanup(); finish(.failure(Failure(message: "The download was empty."))); return }
            finish(.success(.file(url: fileURL, name: name, directory: directory)))
        case nil:
            cleanup()
            finish(.failure(Failure(message: "The server sent no usable response.")))
        }
    }

    // MARK: helpers

    private func openTemp(named name: String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        directory = dir
        let file = dir.appendingPathComponent(name)
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure(message: "open failed") }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        fileURL = file
    }

    private func fail(_ message: String) {
        if failure == nil { failure = Failure(message: TerminalSafe.neutralised(message)) }
        cleanup()
    }

    private func cleanup() {
        try? handle?.close(); handle = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil; fileURL = nil
    }

    private func finish(_ result: Swift.Result<Outcome, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: result)
    }
}

/// getaddrinfo, returning numeric address strings (nil on failure so callers fail closed).
enum ImportResolver {
    static func resolve(_ host: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(list) }
        var out: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cursor {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else {
                return nil   // an address we cannot read is a failure, not a skip
            }
            out.append(String(cString: buf))
            cursor = ai.pointee.ai_next
        }
        return out.isEmpty ? nil : out
    }
}
#endif
