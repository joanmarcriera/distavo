import Foundation

// "Ask Your Notes" (Vikunja #2948): answer a question from ONE note (+ its
// transcript) or, via retrieval over the full-text index (#2942), from ALL notes,
// citing the notes (and timestamps) the answer came from.
//
// Design in one paragraph. The question becomes search terms (stop-words dropped,
// OR-ed); the best passages are fetched, labelled [1], [2]… and packed into the
// backend's token budget (the 4096-token Apple window gets fewer/shorter
// excerpts); a prompt tells the model to answer ONLY from them, cite by number,
// and treat them as data; the reply's [n] markers are parsed back into citations
// (unknown numbers dropped). For ONE long recording we do NOT map-reduce: we rank
// its note/transcript sections by keyword overlap with the question and answer
// from the best-matching ones (the result says which it did). Nothing is
// persisted and nothing is indexed here: the chat lives in the caller's memory.
//
// Local-only: the backend is picked by the SAME rules as note summaries
// (`Pipeline.chooseSummariser`); an Ollama endpoint must be loopback or private
// LAN (`NetworkScope`) or Ask refuses; on-device engines are local by
// construction. A temporarily unavailable backend yields `.deferred` ("try again
// later") — never an error state, never a file written.
//
// Everything external is injected through `AskDeps` (same style as
// `PipelineDeps`), so the whole flow is unit-tested with fakes.

/// What to ask about.
public enum AskScope: Equatable, Sendable {
    /// One recording: its note plus its cached transcript (with timestamps when
    /// the segments sidecar exists).
    case note(base: String)
    /// Every note and transcript, via the search index.
    case allNotes
}

/// A source the answer (or the model) used, resolvable to something to open.
public struct AskCitation: Equatable, Sendable {
    public let key: Int
    public let title: String
    public let base: String
    public let kind: SearchKind
    /// The note to open (the `.md` when it exists, else the cited file).
    public let path: URL
    /// Seconds into the recording, when known.
    public let timestamp: Double?

    /// "12:34" or nil.
    public var timeLabel: String? { timestamp.map(AskPrompt.timeLabel) }
}

public struct AskAnswer: Equatable, Sendable {
    /// The model's answer, with markers of unknown excerpt numbers removed.
    public let text: String
    /// Excerpts the answer actually cites, in order of first mention.
    public let citations: [AskCitation]
    /// Everything the model was shown (shown when it cited nothing).
    public let consulted: [AskCitation]
    /// "Ollama (gemma4:26b)", "Apple Intelligence (built in)", …
    public let backend: String
    /// One line saying how the excerpts were chosen ("the whole note and transcript",
    /// "the best-matching sections …", "the 6 best-matching notes").
    public let method: String
}

public enum AskOutcome: Equatable, Sendable {
    case answered(AskAnswer)
    /// Retrieval found nothing; the model was not called.
    case noMatches(String)
    /// "All notes" without the search index being enabled.
    case needsIndex
    /// The backend is temporarily unavailable or busy: try again later.
    case deferred(String)
    /// Refused by policy (a public Ollama endpoint).
    case refused(String)
    case failed(String)
    case cancelled
}

/// Injectable effects (cf. `PipelineDeps`). The defaults are inert; use `live`.
public struct AskDeps {
    public var ollamaReachable: (String) async -> Bool
    public var embeddedReadiness: (String) async -> EmbeddedReadiness
    /// One generic text completion on `target` — NOT a note summary: the prompt is
    /// sent as given and the reply returned as is (no note validators or repair).
    public var complete: (_ prompt: String, _ target: SummariseTarget,
                          _ options: SummariseOptions, _ maxOutputTokens: Int) async throws -> String
    /// Best passages for space-separated search terms (OR-ed): `(terms, limit, words)`.
    public var retrieve: (_ terms: String, _ limit: Int, _ words: Int) async -> [SearchPassage]
    /// Whether the search index exists (opt-in gate).
    public var indexEnabled: () -> Bool
    /// Non-nil while an on-device engine must not be started because a recording is
    /// being processed (two concurrent on-device generations are not allowed).
    /// Evaluated right before the generation starts (not earlier), so a scan that began
    /// in the meantime is noticed.
    public var onDeviceBusy: () async -> String?
    public var resolver: NetworkScope.HostResolver

    public init(
        ollamaReachable: @escaping (String) async -> Bool,
        embeddedReadiness: @escaping (String) async -> EmbeddedReadiness = { _ in .ready },
        complete: @escaping (String, SummariseTarget, SummariseOptions, Int) async throws -> String,
        retrieve: @escaping (String, Int, Int) async -> [SearchPassage] = { _, _, _ in [] },
        indexEnabled: @escaping () -> Bool = { false },
        onDeviceBusy: @escaping () async -> String? = { nil },
        resolver: @escaping NetworkScope.HostResolver = NetworkScope.systemResolver
    ) {
        self.ollamaReachable = ollamaReachable; self.embeddedReadiness = embeddedReadiness
        self.complete = complete; self.retrieve = retrieve; self.indexEnabled = indexEnabled
        self.onDeviceBusy = onDeviceBusy; self.resolver = resolver
    }

    /// Ollama through the existing `OllamaClient`; the app wraps `complete` to add
    /// the on-device engines (DistavoCore cannot import them).
    public static func live(
        from pipeline: PipelineDeps,
        retrieve: @escaping (String, Int, Int) async -> [SearchPassage],
        indexEnabled: @escaping () -> Bool
    ) -> AskDeps {
        // Never follow a redirect: a 307 keeps the POST body, so a LAN host redirecting to a
        // public URL would otherwise receive the question and excerpts.
        let ollama = OllamaClient(session: AskSession.noRedirect)
        return AskDeps(
            ollamaReachable: pipeline.ollamaReachable, embeddedReadiness: pipeline.embeddedReadiness,
            complete: { prompt, target, options, _ in
                guard case let .ollama(url, model) = target else {
                    throw OllamaError("On-device answering is not available in this build.")
                }
                // Re-check immediately before sending (the guard in `ask` ran earlier).
                if let why = AskBackend.localOnlyViolation(target) { throw OllamaError(why) }
                return try await ollama.generate(url: url, model: model, prompt: prompt, options: options)
            },
            retrieve: retrieve, indexEnabled: indexEnabled)
    }
}

/// Facts about the chosen backend that Ask needs.
public enum AskBackend {
    /// Apple's Foundation Models window (the catalogue has no cap for it).
    public static let appleContextSize = 4096

    public static func contextSize(_ target: SummariseTarget, options: SummariseOptions) -> Int {
        switch target {
        case .ollama: return options.numCtx
        case .embedded(let id):
            let model = EmbeddedSummaryModelCatalog.model(id: id)
            return model.contextCap ?? appleContextSize
        }
    }

    public static func label(_ target: SummariseTarget) -> String {
        switch target {
        case .ollama(_, let model): return "Ollama (\(model))"
        case .embedded(let id): return EmbeddedSummaryModelCatalog.model(id: id).displayName
        }
    }

    /// nil when the target is local. An Ollama endpoint must be loopback or on the
    /// private network (by name, or by resolving to a private address); a public
    /// one is refused so a question about private notes never leaves the LAN.
    public static func localOnlyViolation(
        _ target: SummariseTarget, resolver: NetworkScope.HostResolver = NetworkScope.systemResolver
    ) -> String? {
        guard case .ollama(let url, _) = target else { return nil }
        if isLocalEndpoint(url, resolver: resolver) { return nil }
        let host = URLComponents(string: url)?.host ?? url
        return "Ask Your Notes only works with a local model, but the configured Ollama server (\(host)) is not on this Mac or your local network. Point Settings → Summaries at a local or LAN Ollama, or pick an on-device model."
    }

    /// Strict: an IP literal must be loopback or private; a hostname must be `localhost`,
    /// a bare single-label name or `*.local`, or EVERY address it resolves to must be
    /// loopback or private (an empty/failed resolution is not local).
    static func isLocalEndpoint(_ url: String, resolver: NetworkScope.HostResolver) -> Bool {
        guard let host = NetworkScope.hostOf(url), !host.isEmpty else { return false }
        func local(_ ip: String) -> Bool { NetworkScope.isLoopbackAddress(ip) || NetworkScope.isPrivateAddress(ip) }
        if NetworkScope.ipv4Bytes(host) != nil || NetworkScope.ipv6Bytes(host) != nil { return local(host) }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || !host.contains(".") {
            return true
        }
        let ips = resolver(host)
        return !ips.isEmpty && ips.allSatisfy(local)
    }
}

/// URLSession for Ask: refuses every redirect (the 3xx is returned as the response and
/// reported as a failure), so the prompt is only ever sent to the configured endpoint.
enum AskSession {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    static func make(_ configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }
    static let noRedirect = make()
}

public enum AskNotes {

    /// Longest question considered.
    static let maxQuestionChars = 1500
    /// Section size when a single note/transcript is cut up for ranking.
    static let sectionTokens = 250
    /// Section length when grouping timed segments (characters).
    static let sectionChars = 700

    /// Ask `question` about `scope`. `history` is the earlier turns of this chat
    /// (trimmed to the budget here). Never throws, never writes a file.
    public static func ask(
        question rawQuestion: String, scope: AskScope, history: [AskTurn] = [],
        config: Config, deps: AskDeps
    ) async -> AskOutcome {
        let question = String(rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuestionChars))
        guard !question.isEmpty else { return .failed("Type a question first.") }
        if scope == .allNotes, !deps.indexEnabled() { return .needsIndex }

        // 1. Backend: the same choice as a note summary, local-only.
        let target: SummariseTarget
        switch await Pipeline.chooseSummariser(config, reachable: deps.ollamaReachable,
                                               embeddedReadiness: deps.embeddedReadiness) {
        case .use(let t): target = t
        case .deferred(let why): return .deferred("\(why). Try again later.")
        case .unavailable(let why): return .failed(why)
        }
        if let why = AskBackend.localOnlyViolation(target, resolver: deps.resolver) { return .refused(why) }
        if case .embedded = target, let busy = await deps.onDeviceBusy() { return .deferred(busy) }

        // 2. Budget for this backend, then the excerpts.
        let window = AskPrompt.effectiveWindow(AskBackend.contextSize(target, options: config.summarise.options))
        let turns = AskPrompt.trimHistory(history, window: window, question: question)
        let budget = AskPrompt.excerptBudget(window: window, question: question, history: turns)
        guard budget >= 150 else {
            return .failed("The model's context window is too small to answer questions about notes.")
        }
        let notesDir = Config.resolvePath(config.notesDir), workDir = Config.resolvePath(config.workDir)
        let terms = AskPrompt.searchTerms(question)

        let excerpts: [AskExcerpt]
        let method: String
        switch scope {
        case .note(let base):
            let blocks = noteBlocks(base: base, notesDir: notesDir, workDir: workDir)
            guard !blocks.isEmpty else {
                return .noMatches("There is no saved note or transcript for \(base) to ask about.")
            }
            let picked = select(blocks, terms: terms, budget: budget)
            excerpts = picked.chosen
            method = picked.whole
                ? "the whole note and transcript"
                : "the \(picked.chosen.count) best-matching of \(blocks.count) sections of this note and transcript"
        case .allNotes:
            guard !terms.isEmpty else { return .noMatches("Ask about something specific — I found no searchable words in that question.") }
            let words = window <= 4096 ? 140 : 260
            let passages = await deps.retrieve(terms.joined(separator: " "), 12, words)
            if Task.isCancelled { return .cancelled }
            excerpts = pack(passages, budget: budget, notesDir: notesDir, workDir: workDir)
            guard !excerpts.isEmpty else {
                return .noMatches("I couldn't find any notes mentioning \(terms.joined(separator: ", ")).")
            }
            method = "the \(excerpts.count) best-matching note\(excerpts.count == 1 ? "" : "s")/transcript\(excerpts.count == 1 ? "" : "s") from the search index"
        }

        // 3. Ask the model. Re-check the on-device busy state at the point of use.
        if case .embedded = target, let busy = await deps.onDeviceBusy() { return .deferred(busy) }
        let prompt = AskPrompt.build(question: question, excerpts: excerpts, history: turns)
        var options = config.summarise.options
        let answerTokens = AskPrompt.answerTokens(window: window)
        options.numPredict = answerTokens   // a short chat answer; leaves num_ctx alone (no model reload)
        let raw: String
        do {
            raw = try await deps.complete(prompt, target, options, answerTokens)
        } catch is CancellationError {
            return .cancelled
        } catch let retry as RetryableDependencyError {
            return .deferred("\(retry.localizedDescription) Try again later.")
        } catch {
            if Task.isCancelled { return .cancelled }
            return .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        if Task.isCancelled { return .cancelled }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failed("The model returned an empty answer.") }

        // 4. Citations the answer really made.
        func citation(_ e: AskExcerpt) -> AskCitation {
            AskCitation(key: e.key, title: e.title, base: e.base, kind: e.kind,
                        path: openTarget(base: e.base, kind: e.kind, notesDir: notesDir, workDir: workDir),
                        timestamp: e.timestamp)
        }
        let byKey = Dictionary(uniqueKeysWithValues: excerpts.map { ($0.key, $0) })
        let parsed = AskPrompt.parseCitations(text, validKeys: Set(byKey.keys))
        return .answered(AskAnswer(
            text: parsed.cleaned, citations: parsed.keys.compactMap { byKey[$0] }.map(citation),
            consulted: excerpts.map(citation), backend: AskBackend.label(target), method: method))
    }

    // MARK: Single note

    /// A candidate section before keys are assigned.
    struct Block { let title: String, base: String, kind: SearchKind, timestamp: Double?, text: String, order: Int }

    /// The note's and transcript's sections for `base` (none when neither exists).
    static func noteBlocks(base: String, notesDir: URL, workDir: URL) -> [Block] {
        var blocks: [Block] = []
        let noteText = (try? String(contentsOf: notesDir.appendingPathComponent("\(base).md"), encoding: .utf8)) ?? ""
        let title = SearchIndex.heading(inNote: noteText) ?? base
        for chunk in EmbeddedSummaryPlanner.chunks(transcript: noteText, budgetTokens: sectionTokens) {
            blocks.append(Block(title: title, base: base, kind: .note, timestamp: nil, text: chunk, order: blocks.count))
        }
        if let segs = TranscriptSegments.load(workDir: workDir, base: base) {
            var current = "", start = 0.0, speaker: String?
            func flush() {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { blocks.append(Block(title: title, base: base, kind: .transcript, timestamp: start, text: t, order: blocks.count)) }
                current = ""
            }
            for s in segs.segments {
                if current.count >= sectionChars { flush() }
                if current.isEmpty { start = s.start; speaker = nil }
                if let sp = s.speaker, sp != speaker {
                    current += (current.isEmpty ? "" : "\n") + "\(sp): "; speaker = sp
                }
                current += s.text.trimmingCharacters(in: .whitespaces) + " "
            }
            flush()
        } else if let text = try? String(contentsOf: Pipeline.cachedTranscriptURL(workDir: workDir, base: base), encoding: .utf8) {
            for chunk in EmbeddedSummaryPlanner.chunks(transcript: text, budgetTokens: sectionTokens) {
                blocks.append(Block(title: title, base: base, kind: .transcript, timestamp: nil, text: chunk, order: blocks.count))
            }
        }
        return blocks
    }

    /// Keep everything when it fits; otherwise the best keyword-overlap sections
    /// (the note's own sections get a small bonus: they are the dense summary),
    /// then chronological order. Sections that match nothing fill any space left,
    /// so "summarise the decisions" still gets context.
    static func select(_ blocks: [Block], terms: [String], budget: Int) -> (chosen: [AskExcerpt], whole: Bool) {
        func excerpt(_ b: Block, _ key: Int) -> AskExcerpt {
            AskExcerpt(key: key, title: b.title, base: b.base, kind: b.kind, timestamp: b.timestamp, text: b.text)
        }
        let allCost = blocks.reduce(0) { $0 + AskPrompt.cost(of: excerpt($1, 10)) }
        if allCost <= budget { return (blocks.enumerated().map { excerpt($1, $0 + 1) }, true) }

        func score(_ b: Block) -> Double {
            let folded = SearchIndex.fold(b.text)
            return Double(terms.filter { folded.contains($0) }.count) + (b.kind == .note ? 0.5 : 0)
        }
        let ranked = blocks.sorted { (score($0), -$0.order) > (score($1), -$1.order) }
        var chosen: [Block] = [], used = 0
        for b in ranked {
            let c = AskPrompt.cost(of: excerpt(b, 10))
            if used + c <= budget { chosen.append(b); used += c }
        }
        if chosen.isEmpty, let first = ranked.first {   // one section alone overflows: clip it
            let maxChars = Int(Double(budget - 40) * EmbeddedSummaryTokens.charsPerToken)
            chosen = [Block(title: first.title, base: first.base, kind: first.kind, timestamp: first.timestamp,
                            text: String(first.text.prefix(max(0, maxChars))), order: first.order)]
        }
        chosen.sort { $0.order < $1.order }
        return (chosen.enumerated().map { excerpt($1, $0 + 1) }, false)
    }

    // MARK: All notes

    /// Rank-ordered passages -> excerpts: at most two per recording (its note and
    /// its transcript), packed into `budget`; the first is clipped if it alone overflows.
    static func pack(_ passages: [SearchPassage], budget: Int, notesDir: URL, workDir: URL) -> [AskExcerpt] {
        var perBase: [String: Int] = [:], out: [AskExcerpt] = [], used = 0
        var segmentsCache: [String: TranscriptSegments?] = [:]
        for p in passages where perBase[p.base, default: 0] < 2 {
            var text = p.text
            var stamp: Double?
            if p.kind == .transcript {
                if segmentsCache[p.base] == nil { segmentsCache[p.base] = .some(TranscriptSegments.load(workDir: workDir, base: p.base)) }
                if let segs = segmentsCache[p.base] ?? nil { stamp = timestamp(of: text, in: segs) }
            }
            var e = AskExcerpt(key: out.count + 1, title: p.title, base: p.base, kind: p.kind, timestamp: stamp, text: text)
            var c = AskPrompt.cost(of: e)
            if used + c > budget {
                guard out.isEmpty else { continue }   // later ones simply do not fit
                let maxChars = Int(Double(budget - 40) * EmbeddedSummaryTokens.charsPerToken)
                text = String(text.prefix(max(0, maxChars)))
                e = AskExcerpt(key: 1, title: p.title, base: p.base, kind: p.kind, timestamp: stamp, text: text)
                c = AskPrompt.cost(of: e)
            }
            used += c; perBase[p.base, default: 0] += 1; out.append(e)
        }
        return out
    }

    /// Start time of the first timed segment whose text appears inside `passage`
    /// (the cleaned transcript is the segments' text regrouped by speaker); nil
    /// when none can be matched — best effort, never wrong-by-guessing.
    static func timestamp(of passage: String, in segments: TranscriptSegments) -> Double? {
        let hay = SearchIndex.fold(passage.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
        for s in segments.segments {
            let needle = SearchIndex.fold(s.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
            if needle.count >= 15, hay.contains(needle) { return s.start }
        }
        return nil
    }

    /// What clicking a citation opens: the note when it exists, else the cited file.
    static func openTarget(base: String, kind: SearchKind, notesDir: URL, workDir: URL) -> URL {
        let note = notesDir.appendingPathComponent("\(base).md")
        if FileManager.default.fileExists(atPath: note.path) { return note }
        return kind == .transcript ? Pipeline.cachedTranscriptURL(workDir: workDir, base: base) : note
    }
}
