import Foundation

public struct OllamaError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Port of the Ollama calls in `meeting_pipeline/summarise.py`.
/// NOTE: `url` is always a user-controlled endpoint — Seshat has no cloud path.
public struct OllamaClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    /// GET {url}/api/tags — reachable iff HTTP 200 (errors swallowed → false).
    public func reachable(_ url: String, timeout: TimeInterval = 4) async -> Bool {
        guard let endpoint = URL(string: url.trimmedTrailingSlashes() + "/api/tags") else { return false }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// POST {url}/api/generate — returns the trimmed `response` text or throws.
    public func generate(
        url: String, model: String, prompt: String,
        options: SummariseOptions, timeout: TimeInterval = 3600
    ) async throws -> String {
        guard let endpoint = URL(string: url.trimmedTrailingSlashes() + "/api/generate") else {
            throw OllamaError("invalid Ollama URL")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model, "prompt": prompt, "stream": false, "options": options.asPayload,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OllamaError(NetworkScope.friendlyError(error, service: "Ollama", url: url))
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OllamaError("Ollama request failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let preview = String(decoding: data.prefix(200), as: UTF8.self)
            throw OllamaError("Ollama returned a response that isn't valid JSON: \(preview)")
        }
        let text = ((json["response"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw OllamaError("Ollama returned an empty response.") }
        return text
    }
}
