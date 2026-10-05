import Foundation

// "Regenerate a note with a different template, model or instruction"
// (Vikunja #2947).
//
// Re-runs ONLY the summarise step against the cleaned transcript the pipeline
// cached in the work dir (`<workDir>/<base>.transcript.clean.txt`, written by
// `Pipeline.processOne`). It never converts audio or transcribes
// (`deps.convertToWav` / `deps.transcribe` are not called, and only the
// `.summarising` phase is reported), and it is non-destructive:
//   * a missing transcript, an unreachable/unavailable summariser, or a summary
//     that fails validation leaves the existing note and every state marker
//     untouched and returns a clear message — never a `.failed` marker, which
//     `iterPending` would skip forever;
//   * on success the previous note is renamed to `<note>.prev-<yyyyMMdd-HHmmss>.md`
//     in the same folder (never overwriting an earlier backup) and the new note
//     takes its place. The recording stays `.done`.
//
// Not the same as the older "Re-summarise with a bigger model" when-done action
// (`ProcessVariant.summariseOverride`): that goes through `processOne` and so
// re-converts and re-transcribes, then writes a sibling `<base>@…md`.

/// What the user chose in the "Regenerate Note…" sheet. Every field nil = "as
/// configured in Settings".
public struct RegenerateOptions: Equatable, Sendable {
    /// Prompt template: `classic` or `facts_first`.
    public var promptStyle: Prompt.Style?
    /// Model for the chosen (or configured) backend: an Ollama model name for
    /// "server"/"local", an `EmbeddedSummaryModelCatalog` id for "embedded".
    public var model: String?
    /// "server" / "local" (Ollama) or "embedded" (on-device).
    public var backend: String?
    /// Free-text instruction appended to the prompt (capped, see
    /// `Prompt.maxCustomInstructionChars`).
    public var customInstruction: String?
    /// Opaque id of a user summary template (Vikunja #2940). Carried through
    /// untouched until that feature is merged and wired in.
    public var templateID: String?

    public init(promptStyle: Prompt.Style? = nil, model: String? = nil, backend: String? = nil,
                customInstruction: String? = nil, templateID: String? = nil) {
        self.promptStyle = promptStyle; self.model = model; self.backend = backend
        self.customInstruction = customInstruction; self.templateID = templateID
    }
}

/// Backup versions of a note, kept beside it as `<note>.prev-<stamp>.md`.
public enum NoteVersions {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// True for a regenerate backup file name (`demo.prev-20261005-143000.md`,
    /// optionally `…-2.md` when two land in the same second). Scanners that
    /// list the notes folder skip these so a backup never reads as a note or
    /// as a `@variant` run.
    public static func isBackupName(_ fileName: String) -> Bool {
        fileName.range(of: #"\.prev-\d{8}-\d{6}(-\d+)?\.md$"#, options: .regularExpression) != nil
    }

    /// Rename `note` to a fresh backup name beside it and return the new URL.
    /// `moveItem` fails rather than overwrites, so an existing backup is never
    /// clobbered; a counter is appended on a same-second collision.
    static func keepPrevious(note: URL, now: Date) throws -> URL {
        let fm = FileManager.default
        let stem = note.deletingPathExtension().lastPathComponent
        let dir = note.deletingLastPathComponent()
        let stamp = formatter.string(from: now)
        var attempt = 1
        while true {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let candidate = dir.appendingPathComponent("\(stem).prev-\(stamp)\(suffix).md")
            if !fm.fileExists(atPath: candidate.path) {
                do { try fm.moveItem(at: note, to: candidate); return candidate }
                catch let e as CocoaError where e.code == .fileWriteFileExists { /* raced: try the next name */ }
            }
            attempt += 1
            if attempt > 99 { throw CocoaError(.fileWriteFileExists) }
        }
    }
}

extension Pipeline {

    /// Where `processOne` caches the cleaned transcript for `base`.
    public static func cachedTranscriptURL(workDir: URL, base: String) -> URL {
        workDir.appendingPathComponent("\(base).transcript.clean.txt")
    }

    /// The config a regenerate run summarises with: `config` with the user's
    /// backend / model / style choices applied. Pure, so it is unit-tested.
    static func regenerateConfig(_ config: Config, options: RegenerateOptions) -> Config {
        var cfg = config
        if let backend = options.backend, !backend.isEmpty { cfg.summarise.backend = backend }
        if let model = options.model, !model.isEmpty {
            switch cfg.summarise.backend {
            case "embedded": cfg.summarise.embeddedModel = model
            case "local": cfg.summarise.local.model = model
            default: cfg.summarise.server.model = model
            }
        }
        if let style = options.promptStyle { cfg.summarise.promptStyle = style }
        return cfg
    }

    /// Regenerate the note for `base` from its cached transcript.
    ///
    /// - Parameters:
    ///   - base: the recording's base (or `<base>@<suffix>` of a variant note).
    ///   - sourcePath: the recording file, only used for the meeting date in the
    ///     prompt; nil leaves it unknown.
    /// - Returns: `.done` with the new `notePath` (message names the kept
    ///   backup); otherwise a non-`.done` result that left the note and all
    ///   markers untouched — `.failed` here means "could not regenerate", NOT a
    ///   failed-recording marker. `.deferredNeedLocal` = summariser temporarily
    ///   unavailable.
    public static func regenerate(
        base: String, options: RegenerateOptions, config: Config, deps: PipelineDeps,
        sourcePath: URL? = nil, now: Date = Date()
    ) async -> ProcessResult {
        let notesDir = Config.resolvePath(config.notesDir)
        let workDir = Config.resolvePath(config.workDir)

        let state: DistavoState.Store
        do {
            state = try DistavoState.Store(
                stateDir: workDir.appendingPathComponent(".state"), notesDir: notesDir)
        } catch {
            return ProcessResult(status: .failed, base: base,
                                 message: "state init failed: \(error.localizedDescription)")
        }
        if state.isProcessing(base) {
            return ProcessResult(status: .skipped, base: base, message: "already being processed")
        }

        // 1. The cached transcript. Absent for notes made before it was kept, or
        //    after the work folder was cleared: say so, change nothing.
        let transcriptPath = cachedTranscriptURL(workDir: workDir, base: base)
        let transcript = ((try? String(contentsOf: transcriptPath, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            return ProcessResult(
                status: .failed, base: base,
                message: "no saved transcript for \(base) (expected \(transcriptPath.lastPathComponent) in the work folder) — the note was left as it is")
        }

        // 2. The summariser, through the normal defer/unavailable rules.
        let cfg = regenerateConfig(config, options: options)
        if cfg.summarise.backend == "embedded" && !cfg.summarise.embeddedEnabled {
            return ProcessResult(status: .failed, base: base,
                                 message: "on-device summaries are switched off in Settings — the note was left as it is")
        }
        let target: SummariseTarget
        switch await chooseSummariser(cfg, reachable: deps.ollamaReachable,
                                      embeddedReadiness: deps.embeddedReadiness) {
        case .use(let chosen): target = chosen
        case .deferred(let why):
            return ProcessResult(status: .deferredNeedLocal, base: base,
                                 message: "\(why) — the note was left as it is; try again later")
        case .unavailable(let why):
            return ProcessResult(status: .failed, base: base,
                                 message: "\(why) — the note was left as it is")
        }

        // 3. The prompt context, as `processOne` builds it (minus detections,
        //    which are not cached).
        let sourceBase = LanguageOverride.sourceBase(from: base)
        let hints = SpeakerHints.load(workDir: workDir, base: sourceBase)
        let participants = hints?.participants?.trimmingCharacters(in: .whitespacesAndNewlines)
        let languageSidecar = LanguageOverride.load(workDir: workDir, base: sourceBase)
        let spokenLanguage = EmbeddedModelCatalog.isAutomatic(cfg.transcribe.language)
            ? (languageSidecar.flatMap { $0.code.isEmpty ? nil : $0.code } ?? cfg.transcribe.language)
            : cfg.transcribe.language
        let noteLanguage = NoteLanguage.resolve(
            setting: cfg.summarise.noteLanguage, perRecording: languageSidecar?.noteLanguage,
            detected: spokenLanguage)
        // TODO(#2940): apply template — when summary templates land, resolve
        // `options.templateID` here and fold the template's prompt into `context`.
        let context = NoteContext(
            noteOwner: cfg.noteOwner, userSpeaker: cfg.userSpeaker, participants: participants,
            meetingDate: sourcePath.flatMap { meetingDate(for: $0) },
            promptStyle: cfg.summarise.promptStyle, noteLanguage: noteLanguage,
            customInstruction: options.customInstruction)

        // The old note's "Transcribed on this Mac with …" footer describes the
        // transcription, which did not change: carry it over.
        let notePath = state.notePath(base)
        let previousText = try? String(contentsOf: notePath, encoding: .utf8)
        let footer = previousText.flatMap(provenanceFooter(in:)) ?? ""

        // 4. Summarise (one retry on a truncated answer, like `processOne`) and validate.
        deps.onPhase?(.summarising)
        do {
            func attempt() async throws -> (text: String, failures: [String]) {
                let raw = try await deps.summarise(transcript, target, cfg.summarise.options, context)
                let cleaned = SummaryCleaner.stripLeakedWorkingSteps(raw) { print("[Distavo] \($0)") }
                let text = cleaned + footer
                return (text, SummaryValidator.validate(text))
            }
            var (noteText, failures) = try await attempt()
            if isRetryableTruncation(failures) { (noteText, failures) = try await attempt() }
            if !failures.isEmpty {
                // Keep the rejected text for inspection; the existing note and
                // the recording's markers are NOT touched.
                let rejected = workDir.appendingPathComponent("\(base).regenerate-rejected.md")
                try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                try? noteText.write(to: rejected, atomically: true, encoding: .utf8)
                return ProcessResult(
                    status: .failed, base: base,
                    message: "regenerated summary rejected: \(failures.joined(separator: "; ")) (kept at \(rejected.path)) — the note was left as it is",
                    transcriptPath: transcriptPath)
            }

            // 5. Keep the old version, then write the new one.
            try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
            var backup: URL?
            if FileManager.default.fileExists(atPath: notePath.path) {
                backup = try NoteVersions.keepPrevious(note: notePath, now: now)
            }
            do {
                try noteText.write(to: notePath, atomically: true, encoding: .utf8)
            } catch {
                if let backup { try? FileManager.default.moveItem(at: backup, to: notePath) }
                throw error
            }
            state.markDone(base)
            let kept = backup.map { "; previous version kept as \($0.lastPathComponent)" } ?? ""
            return ProcessResult(status: .done, base: base, message: "note regenerated\(kept)",
                                 notePath: notePath, transcriptPath: transcriptPath)
        } catch let retry as RetryableDependencyError {
            return ProcessResult(status: .deferredNeedLocal, base: base,
                                 message: "\(retry.message) — the note was left as it is; try again later")
        } catch {
            return ProcessResult(status: .failed, base: base,
                                 message: "\(cleanMessage(error)) — the note was left as it is")
        }
    }

    /// The trailing "Transcribed on this Mac with …" block of a written note,
    /// or nil when the note has none (WhisperX path).
    static func provenanceFooter(in note: String) -> String? {
        guard let range = note.range(of: "\n\n---\n_Transcribed on this Mac with", options: .backwards)
        else { return nil }
        let tail = String(note[range.lowerBound...])
        return tail.contains("\n#") ? nil : tail   // a heading after it = not our footer
    }
}
