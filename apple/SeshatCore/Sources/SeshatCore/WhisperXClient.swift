import Foundation

public struct WhisperXError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Port of the WhisperX call in `meeting_pipeline/transcribe.py`: POST the WAV to
/// {url}/asr with query params + a multipart `audio_file` field, returning the
/// parsed JSON result (feed to `TranscriptCleaner.segments`).
///
/// The route/params mirror the working Python contract against Marc's
/// learnedmachine/whisperx-asr-service; the live harness confirms via /openapi.json.
public struct WhisperXClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    /// GET {url}/docs — reachable iff HTTP 200 (used by the settings Test button).
    public func reachable(_ url: String, timeout: TimeInterval = 4) async -> Bool {
        guard let endpoint = URL(string: url.trimmedTrailingSlashes() + "/docs") else { return false }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    public func transcribe(
        wavURL: URL, config: TranscribeConfig, timeout: TimeInterval = 3600
    ) async throws -> [String: Any] {
        var components = URLComponents(string: config.whisperxURL.trimmedTrailingSlashes() + "/asr")
        components?.queryItems = [
            URLQueryItem(name: "language", value: config.language),
            URLQueryItem(name: "model", value: config.model),
            URLQueryItem(name: "output_format", value: "json"),
            URLQueryItem(name: "diarize", value: config.diarize ? "true" : "false"),
            URLQueryItem(name: "num_speakers", value: String(config.numSpeakers)),
        ]
        guard let endpoint = components?.url else { throw WhisperXError("invalid WhisperX URL") }

        let boundary = "seshat-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let audio = try Data(contentsOf: wavURL)
        request.httpBody = Self.multipartBody(
            boundary: boundary, fieldName: "audio_file",
            filename: wavURL.lastPathComponent, mimeType: "audio/wav", fileData: audio)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WhisperXError(NetworkScope.friendlyError(
                error, service: "WhisperX", url: config.whisperxURL))
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WhisperXError("WhisperX request failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WhisperXError("WhisperX returned non-object JSON")
        }
        return json
    }

    /// Build a single-file `multipart/form-data` body (testable in isolation).
    static func multipartBody(
        boundary: String, fieldName: String, filename: String, mimeType: String, fileData: Data
    ) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(string.data(using: .utf8)!) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")
        return body
    }
}
