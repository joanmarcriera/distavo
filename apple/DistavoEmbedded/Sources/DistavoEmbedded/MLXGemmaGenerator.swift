import Foundation
import DistavoCore
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

// Local Gemma 4 summaries via mlx-swift-lm (Vikunja #2198, slice S4).
//
// Runs Gemma on the GPU (Metal), macOS 14+ on Apple Silicon, from a local
// folder of weights that Distavo downloaded and verified (S5). Recipe from the
// spike (~/Development/_inbox/distavo-2198-spike, RESULTS.md S0b):
//   - thinking OFF via `additionalContext["enable_thinking"] = false`;
//   - temperature 0.3-0.5 (0.1 loops the facts ledger ~30% of runs);
//   - a streaming loop guard, one retry at +0.2, then fail;
//   - no system-turn tricks or few-shot: the language/role block is appended to
//     the user turn by the driver (`EndOfTurnBlock`).
// Like `EmbeddedTranscriber`, nothing stays resident: the container is loaded
// lazily for one summarisation run and `unload()` drops the weights and clears
// the GPU cache.

// MARK: - swift-transformers bridge

/// `MLXLMCommon.Tokenizer` over swift-transformers. This is a hand-written copy
/// of what MLXHuggingFace's `#huggingFaceTokenizerLoader()` macro expands to, so
/// the build needs no macro plugin (xcodebuild would otherwise ask to trust it)
/// and no swift-huggingface dependency.
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    // swift-transformers spells it `decode(tokens:)`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

// MARK: - Generator

/// The model failed to LOAD (as opposed to failing mid-generation). Kept apart
/// because an unrecognised load error means unreadable weights, which is
/// handled by deleting them so they are downloaded again.
struct GemmaLoadFailure: Error, LocalizedError {
    let underlying: Error
    var errorDescription: String? {
        (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription
    }
}

/// A `SummaryGenerator` backed by a Gemma model folder on disk.
public final class MLXGemmaGenerator: SummaryGenerator, @unchecked Sendable {
    public let contextSize: Int
    private let modelDirectory: URL
    private let modelID: String
    private let temperature: Double

    private let lock = NSLock()
    private var container: ModelContainer?

    /// - Parameters:
    ///   - contextSize: Distavo's cap (catalogue `contextCap`), not the model's.
    ///   - temperature: base sampler temperature; a loop retries at +0.2.
    public init(modelDirectory: URL, modelID: String, contextSize: Int,
                temperature: Double = LoopGuard.defaultTemperature) {
        self.modelDirectory = modelDirectory; self.modelID = modelID
        self.contextSize = contextSize; self.temperature = temperature
    }

    /// Nil: the driver falls back to its conservative 3.0 chars/token estimate
    /// (the spike measured 3.75-3.85 on Gemma's tokenizer).
    public func tokenCount(_ text: String) async -> Int? { nil }

    /// Throws raw engine errors (a load failure wrapped in `GemmaLoadFailure`,
    /// a collapsed stream as `LocalSummaryError`); the defer-versus-fail
    /// decision is `GemmaSummariser`'s, via `LocalSummaryFailurePolicy`.
    public func generate(_ prompt: String, maxOutputTokens: Int) async throws -> String {
        let loaded: ModelContainer
        do { loaded = try await loadedContainer() } catch is CancellationError {
            throw CancellationError()
        } catch { throw GemmaLoadFailure(underlying: error) }
        return try await LoopGuard.runWithRetry(temperature: temperature) { t in
            try await self.streamOnce(loaded, prompt: prompt, maxTokens: maxOutputTokens, temperature: t)
        }
    }

    /// Drop the weights and clear MLX's GPU cache so the menu-bar app holds no
    /// model between meetings.
    public func unload() {
        // Only touch MLX when weights were actually loaded: with none, there is
        // no GPU state to clear, and calling into MLX needs a compiled metallib
        // (absent under plain `swift test`, where it aborts the process).
        let hadModel = lock.withLock { () -> Bool in
            let had = container != nil; container = nil; return had
        }
        if hadModel { MLX.Memory.clearCache() }
    }

    private func loadedContainer() async throws -> ModelContainer {
        if let existing = lock.withLock({ container }) { return existing }
        // A missing folder is a plain load failure; check it before any MLX call
        // (MLX aborts without a metallib, which also keeps non-live tests off MLX).
        guard FileManager.default.fileExists(
            atPath: modelDirectory.appendingPathComponent("config.json").path) else {
            throw RetryableDependencyError("Model files not found at \(modelDirectory.path).")
        }
        // Keep MLX's buffer cache small: the app is idle between meetings.
        MLX.Memory.cacheLimit = 256 * 1024 * 1024
        let fresh = try await loadModelContainer(
            from: modelDirectory, using: TransformersTokenizerLoader())
        lock.withLock { container = fresh }
        return fresh
    }

    /// One generation. A fresh `ChatSession` per call: no history carries over,
    /// and thinking is switched off in the Gemma chat template.
    private func streamOnce(
        _ container: ModelContainer, prompt: String, maxTokens: Int, temperature: Double
    ) async throws -> (text: String, looped: Bool) {
        let parameters = GenerateParameters(
            maxTokens: maxTokens, temperature: Float(temperature), topP: 1.0)
        let session = ChatSession(
            container, generateParameters: parameters,
            additionalContext: ["enable_thinking": false])
        let chunks = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await part in session.streamDetails(to: prompt) {
                        if case .chunk(let s) = part { continuation.yield(s) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return try await LoopGuard.collect(chunks)
    }
}
