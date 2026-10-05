#if EDITION_DIRECT
import Foundation
import DistavoCore
import DistavoEmbedded

/// Live wiring of `CLIRunner` for `Distavo transcribe …` (Vikunja #2955, Direct edition
/// only; compiled out of the App Store and Setapp builds).
///
/// Called from `DistavoMain` BEFORE `DistavoApp.main()`, so no SwiftUI/AppKit UI, menu-bar
/// item, watcher, timer or notification is ever created in CLI mode. The process is a
/// plain tool: it reads the config file, converts and transcribes ONE file with the same
/// engine routing the app uses (`PipelineDeps.appLive()`), prints the result and exits.
///
/// Shares nothing writable with a running GUI app: it never saves the config, never
/// touches the work dir, markers, notes folder or search index, and uses its own private
/// temp folder. The one exception is the shared model folder: if the chosen built-in model
/// has not been downloaded yet, the engine downloads it there (same files the app uses).
/// All logic that can be tested lives in DistavoCore (`CLIArguments`, `CLIRunner`).
enum DistavoCLI {

    /// Temp folders of in-flight runs, removed on SIGINT/SIGTERM (`cleanupLock` guards it).
    private static let cleanupLock = NSLock()
    nonisolated(unsafe) private static var liveTempDirs: [URL] = []
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    static func runAndExit(_ args: [String]) -> Never {
        // A closed pipe (`… | head`) must end the write, not kill us mid-cleanup.
        signal(SIGPIPE, SIG_IGN)
        installInterruptCleanup()
        // Engine progress ("Using …", model download) is diagnostics: stderr only.
        Task { await ModelCoordinator.shared.setProgressHandler { writeStderr(TerminalSafe.neutralised($0) + "\n") } }
        Task {
            let code = await CLIRunner(env: liveEnvironment()).run(args: args)
            exit(code)
        }
        dispatchMain()
    }

    // MARK: environment

    static func liveEnvironment() -> CLIEnvironment {
        let deps = PipelineDeps.appLive()
        return CLIEnvironment(
            loadConfig: readOnlyConfig,
            fileInfo: fileInfo,
            convertToWav: deps.convertToWav,
            transcribe: deps.transcribe,
            makeTempDir: makeTempDir,
            removeDir: removeTempDir,
            writeStdout: { writeAll(STDOUT_FILENO, $0) },
            writeStderr: { writeAll(STDERR_FILENO, Data($0.utf8)) },
            writeFile: writeFile,
            version: versionString,
            stdoutIsTerminal: isatty(STDOUT_FILENO) != 0)
    }

    /// The user's config WITHOUT `Config.load`, which creates the file when missing. A
    /// missing or unreadable file means the defaults a fresh app install would write.
    static func readOnlyConfig() -> Config {
        var cfg: Config
        if let data = try? Data(contentsOf: Config.defaultConfigURL),
           let decoded = try? JSONDecoder().decode(Config.self, from: data) {
            cfg = decoded
        } else {
            cfg = .recommendedForThisMac()
        }
        // Same rule as WatcherController.init: "embedded" on an Intel Mac falls back to the server.
        if cfg.transcribe.backend == "embedded" && !HardwareProbe.supportsEmbeddedTranscription {
            cfg.transcribe.backend = "server"
        }
        cfg.applyEnvOverrides()
        return cfg
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (build \(build))"
    }

    static func fileInfo(_ path: String) -> CLIFileInfo? {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        return CLIFileInfo(isRegularFile: v?.isRegularFile ?? false, size: v?.fileSize ?? 0)
    }

    // MARK: temp folder

    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        cleanupLock.lock(); liveTempDirs.append(dir); cleanupLock.unlock()
        return dir
    }

    static func removeTempDir(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
        cleanupLock.lock(); liveTempDirs.removeAll { $0 == dir }; cleanupLock.unlock()
    }

    /// Ctrl-C / kill: remove the private temp folder (it can hold a large WAV), then exit 130.
    private static func installInterruptCleanup() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)   // let the dispatch source see it instead of the default action
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                cleanupLock.lock()
                let dirs = liveTempDirs
                cleanupLock.unlock()
                for d in dirs { try? FileManager.default.removeItem(at: d) }
                exit(130)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: output

    /// Write all of `data` to a descriptor, riding out partial writes and EINTR.
    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = write(fd, p, left)
                if n < 0 { if errno == EINTR { continue }; return }   // EPIPE etc.: stop quietly
                p += n; left -= n
            }
        }
    }

    private static func writeStderr(_ text: String) { writeAll(STDERR_FILENO, Data(text.utf8)) }

    /// `overwrite == false`: exclusive create (O_EXCL, which also refuses a symlink at the
    /// path), so a file that appeared since the runner's check is never clobbered; a failed
    /// partial write removes what it created. `overwrite == true`: atomic replace.
    static func writeFile(_ path: String, _ data: Data, _ overwrite: Bool) throws {
        let url = URL(fileURLWithPath: path)
        if overwrite {
            try data.write(to: url, options: .atomic)
            return
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var written = 0
        let ok: Bool = data.withUnsafeBytes { raw in
            while written < raw.count {
                let n = write(fd, raw.baseAddress! + written, raw.count - written)
                if n < 0 { if errno == EINTR { continue }; return false }
                written += n
            }
            return true
        }
        if !ok {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            unlink(url.path)
            throw POSIXError(code)
        }
    }
}
#endif
