#if !EDITION_APPSTORE
import SwiftUI
import AppKit
import AVFoundation
import DistavoCore

// The Voices window ("Review Voices…" in Settings > Transcription, and the menu's "Name Voices…").
// Two lists: the voices Distavo remembers, each with a clip from the person's most recent meetings, and the
// voices nobody named yet. Everything shown and every button is decided by `VoiceCatalog` / `VoiceReview`
// (DistavoCore); `WatcherController+VoiceCatalog` does the work. A clip is played from the recording itself:
// nothing is cut out or stored, and a meeting whose recording is gone shows only what was said.

struct VoicesSnapshot {
    var people: [VoiceCatalog.Person] = []
    var unnamed: [VoiceCatalog.Clip] = []
    /// The meetings whose recording is still in the recordings folder (only those can be played).
    var recorded: Set<String> = []
    /// What "Undo" would undo; nil = nothing.
    var undo: String?
}

@MainActor
final class VoicesModel: ObservableObject {
    enum Tab: String { case remembered = "Remembered", unnamed = "Not yet named" }
    /// Clips read per voice; the row shows `VoiceCatalog.clipLimit` until "Show more".
    nonisolated static let loadedClips = 40

    @Published var tab: Tab
    @Published var snapshot = VoicesSnapshot()
    @Published var loaded = false
    @Published var busy = false
    @Published var status: String?
    @Published var playing: String?
    /// Per voice: the meetings ticked "not this person", who it is instead, and the two options.
    @Published var wrong: [String: Set<String>] = [:]
    @Published var otherName: [String: String] = [:]
    @Published var rememberOther: [String: Bool] = [:]
    @Published var correctNotes: [String: Bool] = [:]
    @Published var expanded: Set<String> = []
    let naming: NameVoicesModel

    private let load: () async -> VoicesSnapshot
    private let confirm: (VoiceCatalog.Clip) async -> Bool
    private let separate: (String, [String], String, Bool, Bool) async -> String
    private let merge: (String, String, Bool, [String]) async -> String
    private let undo: () async -> String
    private let audio: (String) -> URL?
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    init(tab: Tab, naming: NameVoicesModel, load: @escaping () async -> VoicesSnapshot,
         confirm: @escaping (VoiceCatalog.Clip) async -> Bool,
         separate: @escaping (String, [String], String, Bool, Bool) async -> String,
         merge: @escaping (String, String, Bool, [String]) async -> String,
         undo: @escaping () async -> String, audio: @escaping (String) -> URL?) {
        self.tab = tab; self.naming = naming; self.load = load; self.confirm = confirm
        self.separate = separate; self.merge = merge; self.undo = undo; self.audio = audio
    }

    func reload() {
        Task {
            snapshot = await load()
            loaded = true
            // A meeting that left a voice can no longer be ticked for it.
            for p in snapshot.people { wrong[p.id]?.formIntersection(p.bases) }
        }
    }

    func play(_ clip: VoiceCatalog.Clip) {
        stop()
        guard let url = audio(clip.base), let p = try? AVAudioPlayer(contentsOf: url) else {
            status = "The recording of that meeting is no longer in the recordings folder."
            return
        }
        p.currentTime = clip.start
        p.play()
        player = p
        playing = clip.id
        let seconds = max(1, clip.end - clip.start)
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

    private func run(_ what: String, _ work: @escaping () async -> String) {
        guard !busy else { return }
        busy = true
        status = what
        Task {
            status = await work()
            busy = false
            reload()
        }
    }

    func confirmClip(_ clip: VoiceCatalog.Clip) {
        run("Saving…") { [confirm] in await confirm(clip) ? "Confirmed: \(clip.speaker) in that meeting is no longer a guess." : "Nothing to change." }
    }

    func applyWrong(_ person: VoiceCatalog.Person) {
        let bases = person.bases.filter { wrong[person.id]?.contains($0) == true }
        guard !bases.isEmpty else { return }
        let to = (otherName[person.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let remember = !to.isEmpty && (rememberOther[person.id] ?? false)
        let notes = correctNotes[person.id] ?? true
        run("Working… (listening to \(bases.count) recording\(bases.count == 1 ? "" : "s"))") { [separate] in
            await separate(person.name, bases, to, remember, notes)
        }
        wrong[person.id] = []; otherName[person.id] = ""
    }

    /// "Rename or Merge…": asks for the name and whether the meetings follow.
    func renameOrMerge(_ person: VoiceCatalog.Person, preset: String? = nil) {
        let others = snapshot.people.map(\.name).filter { $0 != person.name }
        let alert = NSAlert()
        alert.messageText = preset.map { "Make \(person.name) and \($0) one voice?" } ?? "Rename the voice of \(person.name)"
        alert.informativeText = preset == nil
            ? "Type the right name. If another remembered voice already has that name, the two become one person."
            : "Their samples are kept together under \(preset!). You can undo this."
        let field = NSTextField(frame: NSRect(x: 0, y: 28, width: 340, height: 24))
        field.stringValue = preset ?? person.name
        field.isEnabled = preset == nil
        let n = person.bases.count
        let box = NSButton(checkboxWithTitle: "Also rename the speaker in the \(n) meeting\(n == 1 ? "" : "s") named \(person.name)", target: nil, action: nil)
        box.frame = NSRect(x: 0, y: 0, width: 340, height: 20)
        box.state = .on
        box.isHidden = n == 0
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 54))
        holder.addSubview(field); holder.addSubview(box)
        alert.accessoryView = holder
        alert.addButton(withTitle: preset == nil ? "Rename" : "Merge")
        alert.addButton(withTitle: "Cancel")
        if preset == nil { alert.window.initialFirstResponder = field }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let into = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !into.isEmpty else { return }
        let notes = n > 0 && box.state == .on
        _ = others
        run("Working…") { [merge] in await merge(person.name, into, notes, person.bases) }
    }

    func undoLast() { run("Undoing…") { [undo] in await undo() } }
}

struct VoicesView: View {
    @ObservedObject var model: VoicesModel
    @ObservedObject var naming: NameVoicesModel

    init(model: VoicesModel) { self.model = model; self.naming = model.naming }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $model.tab) {
                Text("Remembered (\(model.snapshot.people.count))").tag(VoicesModel.Tab.remembered)
                Text("Not yet named").tag(VoicesModel.Tab.unnamed)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
            // Both lists stay alive: leaving the second one must not stop a scan that is listening.
            ZStack(alignment: .topLeading) {
                remembered.opacity(model.tab == .remembered ? 1 : 0).allowsHitTesting(model.tab == .remembered)
                unnamed.opacity(model.tab == .unnamed ? 1 : 0).allowsHitTesting(model.tab == .unnamed)
            }
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let undo = model.snapshot.undo {
                    Button("Undo: \(undo)") { model.undoLast() }.disabled(model.busy)
                        .help("Puts the remembered voices and the renamed meetings back as they were before the last merge, rename or correction made here.")
                }
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { model.reload() }
        .onChange(of: model.tab) { _ in model.stop(); naming.stop(); model.reload() }
        .onDisappear { model.stop(); naming.stop(); naming.cancelled.on = true }
    }

    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    // MARK: Remembered

    @ViewBuilder private var remembered: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The voices Distavo recognises, with a stretch from each person’s most recent meetings. Play them to check Distavo is naming the right person. Tick “Not this person” on the ones that are someone else, then say who it is (or leave it empty). “Named by voice” means Distavo put the name there itself and you have not confirmed it yet.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.loaded {
                ProgressView().controlSize(.small)
                Spacer()
            } else if model.snapshot.people.isEmpty {
                Text("No voice remembered yet. Name one in “Not yet named” and tick “Recognise them automatically next time”.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(model.snapshot.people) { person in personRow(person) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func personRow(_ person: VoiceCatalog.Person) -> some View {
        let n = person.bases.count
        let shown = model.expanded.contains(person.id) ? person.clips : Array(person.clips.prefix(VoiceCatalog.clipLimit))
        let ticked = model.wrong[person.id] ?? []
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(person.name).bold()
                Text("in \(n) meeting\(n == 1 ? "" : "s") · \(person.samples) voice sample\(person.samples == 1 ? "" : "s")"
                     + (person.guessed > 0 ? " · \(person.guessed) named by voice, not confirmed" : ""))
                    .foregroundStyle(.secondary)
                Spacer()
                let others = model.snapshot.people.map(\.name).filter { $0 != person.name }
                if !others.isEmpty {
                    Menu("Same person as") {
                        ForEach(others, id: \.self) { o in Button(o) { model.renameOrMerge(person, preset: o) } }
                    }
                    .fixedSize().disabled(model.busy)
                    .help("Two remembered voices that are one person: merge this one into the other.")
                }
                Button("Rename…") { model.renameOrMerge(person) }.disabled(model.busy)
            }
            if person.clips.isEmpty {
                Text("No meeting has a speaker of this name, so there is nothing to play.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(shown) { clip in
                HStack(alignment: .firstTextBaseline) {
                    playButton(clip)
                    clipText(clip, badge: clip.guessed ? "named by voice" : nil)
                    Spacer()
                    if clip.guessed {
                        Button("That’s them") { model.confirmClip(clip) }.controlSize(.small).disabled(model.busy)
                            .help("The name is right: it stops being a guess.")
                    }
                    Toggle("Not this person", isOn: Binding(
                        get: { ticked.contains(clip.base) },
                        set: { on in
                            var set = model.wrong[person.id] ?? []
                            if on { set.insert(clip.base) } else { set.remove(clip.base) }
                            model.wrong[person.id] = set
                        }))
                        .toggleStyle(.checkbox).controlSize(.small)
                }
            }
            if person.clips.count > VoiceCatalog.clipLimit {
                Button(model.expanded.contains(person.id) ? "Show fewer" : "Show \(person.clips.count - VoiceCatalog.clipLimit) more meetings") {
                    if model.expanded.contains(person.id) { model.expanded.remove(person.id) } else { model.expanded.insert(person.id) }
                }
                .buttonStyle(.link).controlSize(.small)
            }
            if !ticked.isEmpty {
                let k = ticked.count
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(k) meeting\(k == 1 ? " is" : "s are") someone else:")
                        TextField("Who? (empty = not known)", text: Binding(get: { model.otherName[person.id] ?? "" }, set: { model.otherName[person.id] = $0 }))
                            .frame(width: 200)
                        if !naming.people.isEmpty {
                            Menu("People") { ForEach(naming.people, id: \.self) { p in Button(p) { model.otherName[person.id] = p } } }.fixedSize()
                        }
                        Button("Apply") { model.applyWrong(person) }.disabled(model.busy)
                    }
                    HStack {
                        Toggle("Correct the name in \(k == 1 ? "that meeting" : "those \(k) meetings")", isOn: Binding(get: { model.correctNotes[person.id] ?? true }, set: { model.correctNotes[person.id] = $0 }))
                            .help("On: the speaker gets the name you typed, or goes back to an unnamed label (the previous note is kept). Off: only what Distavo recognises from now on changes.")
                        Toggle("Recognise them automatically next time", isOn: Binding(get: { model.rememberOther[person.id] ?? false }, set: { model.rememberOther[person.id] = $0 }))
                            .disabled((model.otherName[person.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                            .help("Keeps a voiceprint of the person you named, which is what stops Distavo mixing the two up again. A voice you do not name is never stored.")
                    }
                    .toggleStyle(.checkbox)
                }
                .font(.callout).padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
            Divider()
        }
    }

    // MARK: Not yet named

    @ViewBuilder private var unnamed: some View {
        if case .idle = naming.phase {
            VStack(alignment: .leading, spacing: 8) {
                Text("Unnamed speakers who talked for a minute or more, newest meeting first. Play one to hear who it is. To name them, let Distavo listen: it groups the same voice across meetings so you name each person once.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Listen and Group the Voices") { naming.start() }
                    .help("Loads the voice model and listens to the most recent recordings. It waits for a transcription in progress to finish.")
                if model.loaded, model.snapshot.unnamed.isEmpty {
                    Text("No unnamed speaker talked for a minute or more. Shorter voices are still found by listening.").foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.snapshot.unnamed) { clip in
                            HStack(alignment: .firstTextBaseline) {
                                playButton(clip)
                                clipText(clip, badge: "\(Int((clip.talkSeconds / 60).rounded())) min")
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } else {
            NameVoicesView(model: naming).padding(-16)
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func playButton(_ clip: VoiceCatalog.Clip) -> some View {
        if model.snapshot.recorded.contains(LanguageOverride.sourceBase(from: clip.base)) {
            Button(model.playing == clip.id ? "Stop" : "Play") {
                if model.playing == clip.id { model.stop() } else { model.play(clip) }
            }
            .controlSize(.small)
        } else {
            Text("no recording").font(.caption).foregroundStyle(.tertiary)
                .help("The recording of this meeting is no longer in the recordings folder, so it cannot be played.")
        }
    }

    @ViewBuilder
    private func clipText(_ clip: VoiceCatalog.Clip, badge: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text("\(Self.day.string(from: clip.date)) · \(clip.title)").font(.caption).lineLimit(1)
                if let badge {
                    Text(badge).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
            if !clip.quote.isEmpty {
                Text("“\(clip.quote)”").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

@MainActor
final class VoicesWindowController: NSObject, NSWindowDelegate {
    static let shared = VoicesWindowController()
    private var window: NSWindow?
    private var model: VoicesModel?

    func show(tab: VoicesModel.Tab, model make: @autoclosure () -> VoicesModel) {
        if let w = window {
            model?.tab = tab
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            return
        }
        let m = make()
        let w = NSWindow(contentViewController: NSHostingController(rootView: VoicesView(model: m)))
        w.title = "Voices"
        w.styleMask = [.titled, .closable, .resizable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w; model = m
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil; model = nil   // the models, and with them every voice sample in memory, go with the window
        AppActivation.windowClosed(notification.object as? NSWindow)
    }
}
#endif
