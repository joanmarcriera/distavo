import Foundation

// The testable heart of `Distavo transcribe` (Vikunja #2955, Direct edition only).
//
// A PURE function of its inputs: it reads the user's config (read-only) for engine and
// model defaults, converts and transcribes the ONE file it is given through injected
// closures, renders the result and writes it to stdout or a new file. It never writes
// config, markers, the work dir, the notes folder or the search index, and it never
// summarises. Everything effectful arrives through `CLIEnvironment`, so the unit tests
// run it with fakes (no engine, no disk, no process exit).
//
// Exit codes (documented in docs/cli.md):
//   0 ok            2 usage error          3 input problem (missing/unsupported file,
//   1 unexpected    4 engine unavailable     output exists, unreadable audio)
//                     or no usable result
//
// Concurrency: the live environment (app target) gives every run its own temp directory
// and shares nothing writable with a running GUI app, so running both at once is safe.

public enum CLIExit: Int32, Sendable {
    case ok = 0, failure = 1, usage = 2, input = 3, engine = 4
}

public struct CLIFileInfo: Equatable, Sendable {
    public var isRegularFile: Bool
    public var size: Int
    public init(isRegularFile: Bool, size: Int) { self.isRegularFile = isRegularFile; self.size = size }
}

public struct CLIEnvironment {
    /// Read-only config load. Must NOT create the file when it is missing.
    public var loadConfig: () -> Config
    /// Stat of a path, nil when it does not exist.
    public var fileInfo: (String) -> CLIFileInfo?
    public var convertToWav: (URL, URL) async throws -> Void
    public var transcribe: (URL, TranscribeConfig) async throws -> [String: Any]
    public var makeTempDir: () throws -> URL
    public var removeDir: (URL) -> Void
    public var writeStdout: (Data) -> Void
    public var writeStderr: (String) -> Void
    /// Write `data` to `path`. With `overwrite == false` it must fail if the file exists
    /// (an exclusive create), so a race between the check and the write cannot clobber.
    public var writeFile: (_ path: String, _ data: Data, _ overwrite: Bool) throws -> Void
    public var version: String

    public init(loadConfig: @escaping () -> Config,
                fileInfo: @escaping (String) -> CLIFileInfo?,
                convertToWav: @escaping (URL, URL) async throws -> Void,
                transcribe: @escaping (URL, TranscribeConfig) async throws -> [String: Any],
                makeTempDir: @escaping () throws -> URL,
                removeDir: @escaping (URL) -> Void,
                writeStdout: @escaping (Data) -> Void,
                writeStderr: @escaping (String) -> Void,
                writeFile: @escaping (String, Data, Bool) throws -> Void,
                version: String) {
        self.loadConfig = loadConfig; self.fileInfo = fileInfo
        self.convertToWav = convertToWav; self.transcribe = transcribe
        self.makeTempDir = makeTempDir; self.removeDir = removeDir
        self.writeStdout = writeStdout; self.writeStderr = writeStderr
        self.writeFile = writeFile; self.version = version
    }
}

public struct CLIRunner {
    public let env: CLIEnvironment
    public init(env: CLIEnvironment) { self.env = env }

    public static let usage = """
    Usage:
      Distavo transcribe <file> [options]
      Distavo --help | --version

    Transcribes one audio or video file and prints the result. Nothing is summarised,
    and no note, marker or search-index entry is written.

    Options:
      -f, --format <srt|vtt|json|md>   output format (default: srt; md = speaker-grouped text)
      -o, --output <path>              write to a file instead of stdout ("-" = stdout);
                                       an existing file is never overwritten unless --force
      -l, --language <code>            language code such as en, ca, es, or auto
      -m, --model <id>                 engine model id (see Settings > Transcription)
          --force                      allow --output to replace an existing file
          --                           treat everything after it as the input file name

    Exit codes: 0 ok, 1 unexpected failure, 2 usage error, 3 input problem,
                4 engine unavailable or no usable result.
    """

    /// Run one invocation. `args` excludes the program name.
    public func run(args: [String]) async -> Int32 {
        switch CLIArguments.parse(args) {
        case .failure(let error):
            env.writeStderr("distavo: \(error.message)\nTry 'Distavo --help'.\n")
            return CLIExit.usage.rawValue
        case .success(.help):
            env.writeStdout(Data((Self.usage + "\n").utf8))
            return CLIExit.ok.rawValue
        case .success(.version):
            env.writeStdout(Data("Distavo \(env.version)\n".utf8))
            return CLIExit.ok.rawValue
        case .success(.transcribe(let options)):
            return await transcribe(options).rawValue
        }
    }

    // MARK: transcribe

    private func transcribe(_ o: CLITranscribeOptions) async -> CLIExit {
        // 1. The input: a non-empty regular file of a type the app accepts.
        guard let info = env.fileInfo(o.input) else {
            return fail(.input, "no such file: \(CLIArguments.shown(o.input))")
        }
        guard info.isRegularFile else { return fail(.input, "not a regular file: \(CLIArguments.shown(o.input))") }
        guard info.size > 0 else { return fail(.input, "the file is empty: \(CLIArguments.shown(o.input))") }
        guard QueuedFile.isSupportedMedia(o.input) else {
            return fail(.input, "unsupported file type (expected audio or video such as .wav .m4a .mp3 .mp4 .mov)")
        }

        // 2. The output, checked BEFORE the slow transcription so a typo costs nothing.
        if !o.writesToStdout, let out = o.output {
            if Self.samePath(out, o.input) { return fail(.input, "the output would replace the input file") }
            if env.fileInfo(out) != nil, !o.force {
                return fail(.input, "\(CLIArguments.shown(out)) already exists (use --force to replace it)")
            }
        }

        // 3. Config: read-only, with the flags applied to this run's COPY only.
        var cfg = env.loadConfig().transcribe
        if let language = o.language { cfg.language = language }
        if let model = o.model {
            if cfg.backend == "embedded" {
                guard Self.knownEmbeddedModel(model) else {
                    return fail(.usage, "unknown model '\(CLIArguments.shown(model))' for the built-in engine")
                }
                cfg.embeddedModel = model
            } else {
                cfg.model = model
            }
        }

        // 4. Convert and transcribe in a private temp dir that is always removed.
        let tmp: URL
        do { tmp = try env.makeTempDir() } catch {
            return fail(.failure, "could not create a temporary folder: \(error.localizedDescription)")
        }
        defer { env.removeDir(tmp) }
        let wav = tmp.appendingPathComponent("audio.wav")
        do {
            try await env.convertToWav(URL(fileURLWithPath: o.input), wav)
        } catch {
            return fail(.input, "could not read the audio: \(Self.describe(error))")
        }
        let result: [String: Any]
        do {
            result = try await env.transcribe(wav, cfg)
        } catch {
            return fail(.engine, "transcription is unavailable: \(Self.describe(error))")
        }

        // 5. Render.
        let data: Data
        switch o.format {
        case .md:
            let clean = TranscriptCleaner.clean(
                TranscriptCleaner.segments(from: result), replacements: cfg.replacements)
            guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return fail(.engine, "the engine returned an empty transcript")
            }
            data = Data((clean + "\n").utf8)
        case .srt, .vtt, .json:
            guard let timed = TranscriptSegments(whisperXResult: result) else {
                return fail(.engine, "the engine returned no timed segments, so \(o.format.rawValue) cannot be produced (try --format md)")
            }
            let format: TranscriptExportFormat = o.format == .srt ? .srt : (o.format == .vtt ? .vtt : .json)
            do { data = try format.render(timed, title: "") } catch {
                return fail(.failure, "could not render \(o.format.rawValue): \(Self.describe(error))")
            }
        }

        // 6. Deliver.
        if o.writesToStdout {
            env.writeStdout(data)
        } else if let out = o.output {
            do { try env.writeFile(out, data, o.force) } catch {
                return fail(.input, "could not write \(CLIArguments.shown(out)): \(Self.describe(error))")
            }
        }
        return .ok
    }

    // MARK: helpers

    private func fail(_ code: CLIExit, _ message: String) -> CLIExit {
        env.writeStderr("distavo: \(message)\n")
        return code
    }

    /// Single-line, bounded error text for stderr.
    static func describe(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 300 ? String(oneLine.prefix(300)) + "…" : oneLine
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().standardizedFileURL.path
            == URL(fileURLWithPath: b).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func knownEmbeddedModel(_ id: String) -> Bool {
        id == EmbeddedModelCatalog.automaticID
            || EmbeddedModelCatalog.models.contains { $0.id == id }
            || EmbeddedModelCatalog.packModelIDs.contains(id)
    }
}
