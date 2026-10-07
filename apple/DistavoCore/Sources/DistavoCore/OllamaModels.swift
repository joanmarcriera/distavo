import Foundation

// Installed Ollama models and how two of them compare in size (1.18). Settings >
// Summaries has a "Bigger model" used by "Re-summarise with a bigger model"; in
// 1.17 it was a free-text field, so nothing said whether the name typed there
// was installed or actually bigger than the normal model. `OllamaClient.models`
// lists what the server has; `ModelSize.compare` says bigger / smaller / same.

/// One model from `GET /api/tags`.
public struct OllamaModelInfo: Equatable, Sendable, Identifiable {
    public var name: String
    /// Size on disk; 0 when the server did not report it.
    public var sizeBytes: Int64
    /// e.g. "26.0B" / "4.3B", as the server reports it (may be empty).
    public var parameterSize: String

    public var id: String { name }

    public init(name: String, sizeBytes: Int64 = 0, parameterSize: String = "") {
        self.name = name; self.sizeBytes = sizeBytes; self.parameterSize = parameterSize
    }

    /// "17 GB" / "815 MB"; "" when unknown.
    public var sizeLabel: String {
        guard sizeBytes > 0 else { return "" }
        let gb = Double(sizeBytes) / 1_000_000_000
        if gb >= 10 { return "\(Int(gb.rounded())) GB" }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return "\(Int((Double(sizeBytes) / 1_000_000).rounded())) MB"
    }
}

public enum ModelSizeComparison: Equatable, Sendable {
    case bigger, smaller, same
    /// Neither the server's list nor the names say which is larger.
    case unknown
}

public enum ModelSize {

    /// Parameters in billions, from the server's "26.0B"/"270M" or a tag such as
    /// `gemma4:26b`, `qwen2.5:7b-instruct`, `gemma3n:e4b`, `llama3.2:1b`.
    static func billions(_ text: String) -> Double? {
        let pattern = #"(?:^|[:\-_ ])e?(\d+(?:\.\d+)?)\s*([bBmM])(?:$|[\-_ ])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let n = Range(m.range(at: 1), in: text).flatMap({ Double(text[$0]) }),
              let unit = Range(m.range(at: 2), in: text).map({ text[$0].lowercased() }) else { return nil }
        return unit == "m" ? n / 1000 : n
    }

    private static func find(_ name: String, in models: [OllamaModelInfo]) -> OllamaModelInfo? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return models.first { $0.name.lowercased() == wanted }
            ?? models.first { $0.name.lowercased() == wanted + ":latest" }
    }

    /// True when the server lists `name` (also matches an implicit `:latest`).
    public static func isInstalled(_ name: String, in models: [OllamaModelInfo]) -> Bool {
        find(name, in: models) != nil
    }

    /// How `candidate` compares with `reference`. Parameter counts decide when both
    /// are known (a quantised 26B file can be smaller on disk than an unquantised
    /// 12B one), then the size on disk; `.unknown` when neither is available.
    public static func compare(_ candidate: String, to reference: String,
                               installed models: [OllamaModelInfo] = []) -> ModelSizeComparison {
        let a = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return .unknown }
        if a.lowercased() == b.lowercased() { return .same }
        let ia = find(a, in: models), ib = find(b, in: models)
        let pa = ia.flatMap { billions($0.parameterSize) } ?? billions(a)
        let pb = ib.flatMap { billions($0.parameterSize) } ?? billions(b)
        if let pa, let pb, pa != pb { return pa > pb ? .bigger : .smaller }
        if let sa = ia?.sizeBytes, let sb = ib?.sizeBytes, sa > 0, sb > 0, sa != sb {
            return sa > sb ? .bigger : .smaller
        }
        if let pa, let pb, pa == pb { return .same }
        return .unknown
    }

    /// The line shown under the "Bigger model" field.
    public static func verdict(bigger candidate: String, normal reference: String,
                               installed models: [OllamaModelInfo], listed: Bool) -> (text: String, comparison: ModelSizeComparison) {
        let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = compare(name, to: reference, installed: models)
        let missing = listed && !isInstalled(name, in: models) ? " It is not installed on the server." : ""
        switch result {
        case .bigger: return ("Bigger than the server model (\(reference)).\(missing)", result)
        case .smaller: return ("Smaller than the server model (\(reference)), so re-summarising with it will not improve the note.\(missing)", result)
        case .same: return ("The same size as the server model (\(reference)).\(missing)", result)
        case .unknown: return ("Cannot tell whether this is bigger than the server model (\(reference)).\(missing)", result)
        }
    }
}

extension OllamaClient {
    /// GET {url}/api/tags: the models installed on that server, largest first.
    /// Throws when the server cannot be reached or answers with something else.
    public func models(_ url: String, timeout: TimeInterval = 6) async throws -> [OllamaModelInfo] {
        guard let endpoint = URL(string: url.trimmedTrailingSlashes() + "/api/tags") else {
            throw OllamaError("invalid Ollama URL")
        }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session(for: request)
        } catch {
            throw OllamaError(NetworkScope.friendlyError(error, service: "Ollama", url: url))
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError("Ollama request failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = json["models"] as? [[String: Any]] else {
            throw OllamaError("Ollama returned a model list that could not be read.")
        }
        return Self.parseModels(list)
    }

    static func parseModels(_ list: [[String: Any]]) -> [OllamaModelInfo] {
        list.compactMap { m -> OllamaModelInfo? in
            guard let name = (m["name"] as? String) ?? (m["model"] as? String), !name.isEmpty else { return nil }
            let details = m["details"] as? [String: Any]
            return OllamaModelInfo(name: name, sizeBytes: (m["size"] as? NSNumber)?.int64Value ?? 0,
                                   parameterSize: (details?["parameter_size"] as? String) ?? "")
        }
        .sorted { a, b in a.sizeBytes != b.sizeBytes ? a.sizeBytes > b.sizeBytes : a.name < b.name }
    }
}
