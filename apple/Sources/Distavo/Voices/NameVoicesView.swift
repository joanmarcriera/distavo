import SwiftUI
import AppKit
import AVFoundation
import DistavoCore

// "Name Voices…" (#2944 phase 2): the unnamed voices of past recordings, grouped across meetings. For each
// voice: play a stretch, read what they said, type or pick a name. Naming renames that speaker in every
// meeting of the voice and (when ticked) remembers the voice. What a voice is, how voices are grouped and
// what naming does is decided by `VoiceReview` (DistavoCore); the samples come from `VoiceEmbedder` through
// `WatcherController+Voices`. Samples live only in this window's memory; closing it discards them.

/// A flag a background scan can read: the window was closed.
final class VoiceScanCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var on: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

@MainActor
final class NameVoicesModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning(String), ready, failed(String) }
    @Published var phase: Phase = .idle
    @Published var voices: [VoiceReview.Voice] = []
    @Published var names: [Int: String] = [:]
    @Published var remember: [Int: Bool] = [:]
    @Published var results: [Int: String] = [:]
    @Published var playing: String?
    /// Voices already named in this window (their row is finished) or being named right now.
    @Published var named: Set<Int> = []
    @Published var working: Set<Int> = []
    let people: [String]
    let heading: String
    /// False inside the Voices window: listening starts when the owner asks, not when the window opens.
    var autoStart = true
    private let scan: (@escaping (String) -> Void, Bool) async -> ([VoiceReview.Voice], Int, Int)
    /// Recordings listened to, and how many have an unnamed voice and could be.
    @Published var listened = 0
    @Published var available = 0
    /// Set when the window closes: a scan still listening stops at the next recording and frees the scan lock.
    let cancelled: VoiceScanCancel
    private let apply: (VoiceReview.Voice, String, Bool, @escaping (String) -> Void) async -> String
    private let audio: (String) -> URL?
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    init(heading: String = "Name the voices in your recordings", people: [String], cancelled: VoiceScanCancel = VoiceScanCancel(), scan: @escaping (@escaping (String) -> Void, Bool) async -> ([VoiceReview.Voice], Int, Int),
         apply: @escaping (VoiceReview.Voice, String, Bool, @escaping (String) -> Void) async -> String, audio: @escaping (String) -> URL?) {
        self.heading = heading; self.people = people; self.cancelled = cancelled; self.scan = scan; self.apply = apply; self.audio = audio
    }

    func start(all: Bool = false) {
        // One scan at a time; "Listen to all" starts a second, complete one once the first is shown.
        guard phase == .idle || (all && phase == .ready && working.isEmpty) else { return }
        stop()
        phase = .scanning("Listening to past recordings…")
        Task {
            let (found, heard, total) = await scan({ [weak self] text in Task { @MainActor in if case .scanning = self?.phase { self?.phase = .scanning(text) } } }, all)
            voices = found
            listened = heard; available = total
            // A fresh scan numbers the voices again: what was typed or named for the old numbers does not carry over.
            if all { names = [:]; remember = [:]; results = [:]; named = [] }
            for v in found where names[v.id] == nil { names[v.id] = v.suggestedName ?? v.introduction?.name ?? "" }
            phase = .ready
        }
    }

    func play(_ o: VoiceReview.Occurrence) {
        stop()
        guard let url = audio(o.base), let p = try? AVAudioPlayer(contentsOf: url) else {
            results[-1] = "The recording of that meeting is no longer in the recordings folder."
            return
        }
        p.currentTime = o.sampleStart
        p.play()
        player = p
        playing = o.id
        let seconds = max(1, o.sampleEnd - o.sampleStart)
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.stop() }
        }
    }

    func stop() {
        stopTask?.cancel(); stopTask = nil
        player?.stop(); player = nil
        playing = nil
    }

    /// "Someone else": that meeting leaves the voice and gets a row of its own.
    func separate(_ o: VoiceReview.Occurrence, from voice: VoiceReview.Voice) {
        guard !named.contains(voice.id), !working.contains(voice.id) else { return }
        voices = VoiceReview.separating(o.id, from: voice.id, in: voices)
    }

    func name(_ voice: VoiceReview.Voice) {
        let name = (names[voice.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // One naming per voice: a second click would find the speakers already renamed and report nothing done.
        guard !name.isEmpty, !named.contains(voice.id), !working.contains(voice.id) else { return }
        working.insert(voice.id)
        results[voice.id] = "Working…"
        Task {
            let id = voice.id
            let line = await apply(voice, name, remember[voice.id] ?? (voice.suggestedName != nil)) { [weak self] text in
                Task { @MainActor in if self?.working.contains(id) == true { self?.results[id] = text } }
            }
            results[voice.id] = line
            working.remove(voice.id)
            if !line.hasPrefix("Named in 0 ") { named.insert(voice.id) }
        }
    }
}

struct NameVoicesView: View {
    @ObservedObject var model: NameVoicesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.heading).font(.headline)
            Text("Each row is one voice Distavo heard, with the meetings it is in. Play a stretch, then type who it is. If one of the meetings is a different person, press “Someone else” beside it. The name replaces the speaker label in every meeting listed (the previous notes are kept).\n\n“Recognise them automatically next time” ticked: Distavo keeps a voiceprint of this person on this Mac and puts their name in future notes without asking. It starts unticked for a new voice: tick it for people you meet again. Untick it for a one-off voice (a trainer, a video, a stranger) or someone who has not agreed: they are named in these meetings only. Voiceprints can be deleted in Settings > Transcription.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch model.phase {
            case .idle, .scanning:
                HStack {
                    ProgressView().controlSize(.small)
                    if case .scanning(let text) = model.phase { Text(text).foregroundStyle(.secondary) }
                }
                Spacer()
            case .failed(let why):
                Text(why).foregroundStyle(.orange)
                Spacer()
            case .ready:
                if model.available > model.listened {
                    HStack {
                        Text("Listened to the \(model.listened) most recent of \(model.available) recordings with an unnamed voice.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Listen to all \(model.available)") { model.start(all: true) }
                            .controlSize(.small).disabled(!model.working.isEmpty)
                            .help("Slower: the voice model runs over every recording. Voices you have already named here stay named.")
                    }
                }
                if model.voices.isEmpty {
                    Text("No unnamed voice found. Only recordings that are still in the recordings folder and have a timed transcript can be listened to.")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    if let note = model.results[-1] { Text(note).font(.caption).foregroundStyle(.orange) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(model.voices) { voice in row(voice) }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 460)
        .onAppear { if model.autoStart { model.start() } }
        .onDisappear { model.stop(); model.cancelled.on = true }
    }

    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    @ViewBuilder
    private func row(_ voice: VoiceReview.Voice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Voice \(voice.id)").bold()
                Text("in \(voice.meetings) meeting\(voice.meetings == 1 ? "" : "s")").foregroundStyle(.secondary)
                if let known = voice.suggestedName {
                    Text("sounds like \(known)").foregroundStyle(.secondary)
                } else if let said = voice.introduction {
                    Text("introduced as \(said.name)\(said.organisation.map { " (\($0))" } ?? "")").foregroundStyle(.secondary)
                }
            }
            ForEach(voice.occurrences) { o in
                HStack(alignment: .firstTextBaseline) {
                    Button(model.playing == o.id ? "Stop" : "Play") {
                        if model.playing == o.id { model.stop() } else { model.play(o) }
                    }
                    .controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Self.day.string(from: o.date)) · \(o.title)").font(.caption).lineLimit(1)
                        if !o.quote.isEmpty {
                            Text("“\(o.quote)”").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    if voice.meetings > 1, !model.named.contains(voice.id) {
                        Spacer()
                        Button("Someone else") { model.separate(o, from: voice) }
                            .controlSize(.small)
                            .help("This meeting is a different person: give it a row of its own.")
                    }
                }
            }
            HStack {
                TextField("Who is this?", text: Binding(get: { model.names[voice.id] ?? "" }, set: { model.names[voice.id] = $0 }))
                    .frame(width: 220)
                    .disabled(model.named.contains(voice.id))
                if !model.people.isEmpty {
                    Menu("People") {
                        ForEach(model.people, id: \.self) { p in Button(p) { model.names[voice.id] = p } }
                    }
                    .fixedSize()
                }
                Toggle("Recognise them automatically next time", isOn: Binding(get: { model.remember[voice.id] ?? (voice.suggestedName != nil) }, set: { model.remember[voice.id] = $0 }))
                Button(model.named.contains(voice.id) ? "Named" : "Name") { model.name(voice) }
                    .disabled((model.names[voice.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || model.named.contains(voice.id) || model.working.contains(voice.id))
            }
            if let r = model.results[voice.id] { Text(r).font(.caption).foregroundStyle(.secondary) }
            Divider()
        }
    }
}

@MainActor
final class NameVoicesWindowController: NSObject, NSWindowDelegate {
    static let shared = NameVoicesWindowController()
    private var window: NSWindow?

    var isOpen: Bool { window != nil }

    /// `activate: false` (the question after a meeting): the window comes to the front without taking the
    /// keyboard from whatever the owner is doing.
    func show(activate: Bool = true, model: @autoclosure () -> NameVoicesModel) {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: NameVoicesView(model: model())))
        w.title = "Name Voices"
        w.styleMask = [.titled, .closable, .resizable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        NSApp.setActivationPolicy(.regular)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        } else {
            w.orderFrontRegardless()
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil   // the model, and with it every voice sample, goes with the window
        AppActivation.windowClosed(notification.object as? NSWindow)
    }
}
