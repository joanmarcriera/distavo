import Foundation

extension String {
    /// Equivalent of Python's `url.rstrip("/")`.
    func trimmedTrailingSlashes() -> String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

extension SummariseOptions {
    /// The Ollama `options` payload (snake_case keys, matching the Python app).
    public var asPayload: [String: Any] {
        [
            "num_ctx": numCtx,
            "temperature": temperature,
            "top_p": topP,
            "seed": seed,
            "num_predict": numPredict,
            "repeat_penalty": repeatPenalty,
            "repeat_last_n": repeatLastN,
        ]
    }
}
