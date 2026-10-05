import AppKit
import DistavoCore
import DistavoEmbedded

// "Ask Your Notes…" wiring (Vikunja #2948): builds the injectable `AskDeps` from
// the app's live dependencies (Ollama through `OllamaClient`; Apple Foundation
// Models and Gemma through DistavoEmbedded) and opens the chat window. The
// answering logic itself lives in DistavoCore (`AskNotes`).
extension WatcherController {

    /// Recent notes for the "This note" picker (newest first).
    private var askableNotes: [AskableNote] {
        let dir = Config.resolvePath(config.notesDir)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "md" && !NoteVersions.isBackupName($0.lastPathComponent) }
            .compactMap { url -> (URL, Date)? in
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let date = v.contentModificationDate else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(50)
            .map { url, _ in
                let base = url.deletingPathExtension().lastPathComponent
                return AskableNote(base: base, title: base)
            }
    }

    func showAskNotes() {
        AskWindowController.shared.show(
            notes: askableNotes,
            ask: { [weak self] question, scope, history in
                guard let self else { return .failed("Distavo is closing.") }
                return await self.answer(question, scope: scope, history: history)
            },
            enableIndex: { [weak self] in await self?.buildSearchIndexForAsk() })
    }

    /// The same opt-in the Search window performs: enable the gate, then build the index.
    private func buildSearchIndexForAsk() async {
        Self.searchGate.enable()
        let notes = Config.resolvePath(config.notesDir), work = Config.resolvePath(config.workDir)
        _ = await SearchWork.run { Self.searchIndex.reconcile(notesDir: notes, workDir: work) }
    }

    private func answer(_ question: String, scope: AskScope, history: [AskTurn]) async -> AskOutcome {
        // A running scan/regenerate may be using the on-device model; two concurrent
        // on-device generations are not allowed, so Ask asks the user to retry.
        // (Ollama is a separate process and is never blocked.)
        var deps = AskDeps.live(
            from: PipelineDeps.appLive(),
            retrieve: { terms, limit, words in
                await SearchWork.run {
                    Self.searchIndex.passages(matching: terms, limit: limit, words: words, matchAny: true)
                }
            },
            indexEnabled: { Self.searchGate.isEnabled })
        let ollamaComplete = deps.complete
        deps.complete = { prompt, target, options, maxOutputTokens in
            if case .embedded(let model) = target {
                // Gemma serialises on ModelCoordinator; Apple's model does not (see
                // EmbeddedSummariser.complete) and relies on the scan refusal above.
                if model == EmbeddedSummaryModelCatalog.appleID {
                    return try await EmbeddedSummariser.complete(prompt: prompt, maxOutputTokens: maxOutputTokens)
                }
                return try await GemmaSummariser.complete(prompt: prompt, modelID: model, maxOutputTokens: maxOutputTokens)
            }
            return try await ollamaComplete(prompt, target, options, maxOutputTokens)
        }
        // Read at the point of use (AskNotes calls this right before generating).
        deps.onDeviceBusy = { [weak self] in
            await MainActor.run {
                self?.isScanning == true
                    ? "Distavo is processing a recording and the on-device model is busy. Try again when it finishes." : nil
            }
        }
        return await AskNotes.ask(question: question, scope: scope, history: history, config: config, deps: deps)
    }
}
