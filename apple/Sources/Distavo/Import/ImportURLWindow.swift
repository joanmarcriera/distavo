#if EDITION_DIRECT
import SwiftUI
import AppKit
import DistavoCore

/// "Import from URL..." (Vikunja #2955, Direct edition only): paste an https address of an
/// audio/video file or an RSS/Atom feed; for a feed pick one of the newest episodes. The chosen
/// file is downloaded into a private temp folder and handed to the existing
/// `queueForTranscription`, which copies it into the recordings folder under a sanitised name;
/// the temp folder is then removed. This is the one place Distavo fetches from the internet,
/// and only for an address you typed: "Downloads the file from the address you paste; nothing
/// is uploaded." Rules: `ImportURLPolicy` / `FeedParser` in DistavoCore; network: `ImportFetcher`.
@MainActor
final class ImportURLModel: ObservableObject {
    enum Phase: Equatable {
        case idle, fetching, choosing, downloading(bytes: Int64), done(String), failed(String)
    }

    @Published var urlText = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var episodes: [FeedEnclosure] = []
    @Published var selected: Int = 0
    private var task: Task<Void, Never>?

    var busy: Bool { if case .fetching = phase { return true }; if case .downloading = phase { return true }; return false }

    func start() {
        guard !busy else { return }
        switch ImportURLPolicy.validate(urlText) {
        case .failure(let p): phase = .failed(Self.describe(p)); return
        case .success(let v):
            phase = .fetching; episodes = []
            run(v.url, fromFeed: false)   // the fetcher re-vets it (validator + public-address check) before any request
        }
    }

    func downloadSelected() {
        guard !busy, episodes.indices.contains(selected) else { return }
        run(episodes[selected].url, fromFeed: true)
    }

    func cancel() { task?.cancel(); task = nil; if busy { phase = .idle } }

    private func run(_ url: URL, fromFeed: Bool) {
        let fetcher = ImportFetcher()
        task = Task { [weak self] in
            do {
                if fromFeed { self?.phase = .downloading(bytes: 0) }
                let outcome = try await fetcher.fetch(url) { bytes in
                    Task { @MainActor in if case .downloading? = self.map(\.phase) { self?.phase = .downloading(bytes: bytes) } }
                }
                guard let self else { return }
                switch outcome {
                case .feed(let items):
                    if fromFeed { self.phase = .failed("The episode link led to another feed, not an audio file."); return }
                    let newest = Array(items.prefix(ImportURLPolicy.pickerCount))
                    if newest.isEmpty { self.phase = .failed("The feed has no audio or video enclosures."); return }
                    self.episodes = newest; self.selected = 0; self.phase = .choosing
                case .file(let file, let name, let directory):
                    defer { try? FileManager.default.removeItem(at: directory) }
                    guard let controller = AutomationHub.shared.controller else { self.phase = .failed("Distavo is still starting."); return }
                    do {
                        let queued = try await controller.queueForTranscription(source: file, data: nil, name: name)
                        self.phase = .done("Queued “\(TerminalSafe.neutralised(queued))” for transcription.")
                    } catch {
                        self.phase = .failed(String(localized: (error as? AutomationError)?.localizedStringResource
                                                    ?? "The file could not be added to the recordings folder."))
                    }
                }
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                self?.phase = .failed(TerminalSafe.neutralised((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
    }

    static func describe(_ p: ImportURLPolicy.Problem) -> String {
        switch p {
        case .empty: return "Paste an address first."
        case .tooLong: return "That address is too long."
        case .malformed: return "That does not look like a web address."
        case .notHTTPS: return "Only https addresses are supported."
        case .notAPublicName: return "Only public internet addresses (a normal web site name) are supported, not this Mac, your network or numeric addresses."
        case .hasCredentials: return "Addresses with a user name or password are not supported."
        case .noHost: return "That address has no host name."
        }
    }
}

struct ImportURLView: View {
    @ObservedObject var model: ImportURLModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from URL").font(.headline)
            Text("Downloads the file from the address you paste; nothing is uploaded. Paste a link to an audio or video file, or to a podcast (RSS or Atom) feed. Files up to 2 GB.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("https://…", text: $model.urlText)
                .textFieldStyle(.roundedBorder)
                .disabled(model.busy)
                .onSubmit { model.start() }
            if case .choosing = model.phase {
                Picker("Episode", selection: $model.selected) {
                    ForEach(Array(model.episodes.enumerated()), id: \.offset) { i, e in Text(e.title).tag(i) }
                }
                Text("Newest \(model.episodes.count) episodes with audio or video.").font(.caption).foregroundStyle(.secondary)
            }
            statusLine
            HStack {
                Spacer()
                if model.busy { Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction) }
                if case .choosing = model.phase {
                    Button("Download and transcribe") { model.downloadSelected() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Fetch") { model.start() }.keyboardShortcut(.defaultAction).disabled(model.busy)
                }
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    @ViewBuilder private var statusLine: some View {
        switch model.phase {
        case .idle, .choosing: EmptyView()
        case .fetching: HStack { ProgressView().controlSize(.small); Text("Contacting the server…") }
        case .downloading(let bytes):
            HStack { ProgressView().controlSize(.small)
                Text("Downloading… \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of at most 2 GB") }
        case .done(let m): Label(m, systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failed(let m): Label(m, systemImage: "xmark.octagon").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
final class ImportURLWindowController {
    static let shared = ImportURLWindowController()
    private var window: NSWindow?
    private let model = ImportURLModel()

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ImportURLView(model: model)))
            w.title = "Import from URL"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
#endif
