import Foundation

// Command-line argument parsing for the Direct edition's CLI mode (Vikunja #2955).
//
//   Distavo.app/Contents/MacOS/Distavo transcribe <file> [--format srt|vtt|json|md]
//       [--output <path>] [--language <code>] [--model <id>] [--force] [--]
//   Distavo.app/Contents/MacOS/Distavo --help | --version
//
// Pure and UI-free so it is unit-tested headlessly. It does no I/O and never
// touches the file system: path *validation* (exists, supported type, overwrite)
// is `CLIRunner`'s job. This file is compiled into every edition but does nothing
// by itself; only the Direct app target ever calls it (`#if EDITION_DIRECT`).
//
// Why a strict "first argument is a known verb" rule (`isCLIInvocation`): macOS
// itself starts apps with arguments such as `-psn_0_12345`,
// `-NSDocumentRevisionsDebugMode YES` or `-ApplePersistenceIgnoreState YES`. None of
// those may ever be mistaken for a CLI request, so only an exact match on the
// FIRST argument switches the process into CLI mode.

/// Output formats of `distavo transcribe`.
public enum CLIFormat: String, CaseIterable, Sendable, Equatable {
    case srt, vtt, json, md
}

/// Everything `transcribe` needs, validated syntactically.
public struct CLITranscribeOptions: Equatable, Sendable {
    public var input: String
    public var format: CLIFormat
    /// Destination file; nil or "-" means standard output.
    public var output: String?
    public var language: String?
    public var model: String?
    /// Allow `--output` to replace an existing file.
    public var force: Bool

    public init(input: String, format: CLIFormat = .srt, output: String? = nil,
                language: String? = nil, model: String? = nil, force: Bool = false) {
        self.input = input; self.format = format; self.output = output
        self.language = language; self.model = model; self.force = force
    }

    /// True when the result goes to standard output.
    public var writesToStdout: Bool { output == nil || output == "-" }
}

public enum CLICommand: Equatable, Sendable {
    case help
    case version
    case transcribe(CLITranscribeOptions)
}

/// A usage error; `message` is shown on stderr followed by a hint, exit code 2.
public enum CLIParseError: Error, Equatable, Sendable {
    case noCommand
    case unknownCommand(String)
    case unknownFlag(String)
    case missingValue(String)
    case duplicateFlag(String)
    case invalidFormat(String)
    case invalidLanguage(String)
    case invalidModel(String)
    case missingInput
    case tooManyInputs
    case invalidPath(String)
    case unexpectedValue(String)

    public var message: String {
        switch self {
        case .noCommand: return "no command given"
        case .unknownCommand(let c): return "unknown command '\(CLIArguments.shown(c))'"
        case .unknownFlag(let f): return "unknown option '\(CLIArguments.shown(f))'"
        case .missingValue(let f): return "option \(f) needs a value"
        case .duplicateFlag(let f): return "option \(f) given more than once"
        case .invalidFormat(let v): return "unknown format '\(CLIArguments.shown(v))' (use srt, vtt, json or md)"
        case .invalidLanguage(let v): return "invalid language code '\(CLIArguments.shown(v))'"
        case .invalidModel(let v): return "invalid model id '\(CLIArguments.shown(v))'"
        case .missingInput: return "missing input file"
        case .tooManyInputs: return "only one input file is accepted (put '--' before names starting with '-')"
        case .invalidPath(let p): return "invalid path '\(CLIArguments.shown(p))'"
        case .unexpectedValue(let f): return "option \(f) does not take a value"
        }
    }
}

public enum CLIArguments {
    /// Verbs that switch the process into CLI mode when they are the FIRST argument.
    public static let verbs: Set<String> = ["transcribe", "help", "version", "--help", "-h", "--version"]

    /// `args` excludes the program name (`CommandLine.arguments.dropFirst()`).
    /// Exact match on the first argument only; see the file header for why.
    public static func isCLIInvocation(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        return verbs.contains(first)
    }

    /// Longest accepted path / value (bytes). Far above PATH_MAX; just a sanity cap.
    static let maxValueBytes = 4096

    /// Printable, truncated form of an untrusted argument for error messages.
    static func shown(_ s: String) -> String {
        let clean = TerminalSafe.neutralised(s)
        return clean.count > 60 ? String(clean.prefix(60)) + "…" : clean
    }

    /// Parse the argument list (without the program name).
    public static func parse(_ args: [String]) -> Result<CLICommand, CLIParseError> {
        guard let verb = args.first else { return .failure(.noCommand) }
        let rest = Array(args.dropFirst())
        switch verb {
        case "help", "--help", "-h": return .success(.help)
        case "version", "--version": return .success(.version)
        case "transcribe": return parseTranscribe(rest)
        default: return .failure(.unknownCommand(verb))
        }
    }

    // MARK: transcribe

    private static func parseTranscribe(_ args: [String]) -> Result<CLICommand, CLIParseError> {
        var input: String?
        var format: CLIFormat?
        var output: String?, language: String?, model: String?
        var force = false
        var seen = Set<String>()
        var onlyPositionals = false

        // Canonical long name for each accepted spelling.
        let aliases = ["-f": "--format", "-o": "--output", "-l": "--language", "-m": "--model"]
        let valued: Set<String> = ["--format", "--output", "--language", "--model"]

        func positional(_ value: String) -> CLIParseError? {
            if input != nil { return .tooManyInputs }
            guard validPath(value) else { return .invalidPath(value) }
            input = value
            return nil
        }

        var i = 0
        while i < args.count {
            let arg = args[i]; i += 1
            if onlyPositionals { if let e = positional(arg) { return .failure(e) }; continue }
            if arg == "--" { onlyPositionals = true; continue }
            // "-" alone is a positional (stdin is not supported; the runner rejects it as a missing file).
            guard arg.hasPrefix("-"), arg != "-" else {
                if let e = positional(arg) { return .failure(e) }
                continue
            }
            // --flag=value
            var name = arg, inline: String?
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                name = String(arg[..<eq]); inline = String(arg[arg.index(after: eq)...])
            }
            name = aliases[name] ?? name
            if name == "--force" {
                if inline != nil { return .failure(.unexpectedValue(name)) }
                if !seen.insert(name).inserted { return .failure(.duplicateFlag(name)) }
                force = true
                continue
            }
            guard valued.contains(name) else { return .failure(.unknownFlag(arg)) }
            if !seen.insert(name).inserted { return .failure(.duplicateFlag(name)) }
            let value: String
            if let inline {
                value = inline
            } else {
                // The next token is the value, unless it is missing or looks like another
                // flag ("-" alone, meaning stdout, is allowed after --output).
                guard i < args.count, !(args[i].hasPrefix("-") && args[i] != "-") else {
                    return .failure(.missingValue(name))
                }
                value = args[i]; i += 1
            }
            if value.isEmpty { return .failure(.missingValue(name)) }
            switch name {
            case "--format":
                guard let f = CLIFormat(rawValue: value.lowercased()) else { return .failure(.invalidFormat(value)) }
                format = f
            case "--output":
                guard validPath(value) else { return .failure(.invalidPath(value)) }
                output = value
            case "--language":
                guard validLanguage(value) else { return .failure(.invalidLanguage(value)) }
                language = value
            default:
                guard validModel(value) else { return .failure(.invalidModel(value)) }
                model = value
            }
        }
        guard let input else { return .failure(.missingInput) }
        return .success(.transcribe(CLITranscribeOptions(
            input: input, format: format ?? .srt, output: output,
            language: language, model: model, force: force)))
    }

    // MARK: value rules

    /// Non-empty, no NUL, bounded. Spaces and any other characters are fine.
    static func validPath(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= maxValueBytes && !s.contains("\0")
    }

    /// `en`, `ca`, `pt-BR`, `auto`: ASCII letters, digits, `-`, `_`, up to 16.
    static func validLanguage(_ s: String) -> Bool {
        guard (1...16).contains(s.utf8.count) else { return false }
        return s.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
        }
    }

    /// Model ids: catalog ids and WhisperX model names (`large-v3-turbo`, `openai_whisper-base`).
    static func validModel(_ s: String) -> Bool {
        guard (1...120).contains(s.utf8.count) else { return false }
        return s.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "." || $0 == "/")
        }
    }
}
