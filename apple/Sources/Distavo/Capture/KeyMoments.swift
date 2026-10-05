import SwiftUI
import AppKit
import Carbon.HIToolbox
import DistavoCore

/// Key-moment markers while the built-in recorder runs (Vikunja #2950).
///
/// `KeyMomentsModel` owns the markers of ONE recording and persists them after
/// every press straight into the final sidecar `<base>.bookmarks.json` (same
/// scheme and lifecycle as `QuickNotesModel`: the recorder knows the final
/// recording name up front, a cancelled recording deletes the sidecar, a crash
/// leaves it waiting for the recovered `.wav`). Offsets use the controller's
/// `startedAt`, the same recording-offset clock Quick Notes stamps lines with.
///
/// Ways to drop a marker: the "Mark Key Moment" menu item, the button in the
/// Quick Notes panel, and an optional GLOBAL hotkey (`KeyMomentHotkey`, Carbon
/// `RegisterEventHotKey`: needs no Accessibility / Input Monitoring permission
/// and no entitlement, so it behaves the same in the sandboxed App Store build).
/// The hotkey exists only while a recording runs.
///
/// Feedback is silent on purpose (a beep would be captured into the meeting
/// audio): the menu-bar icon flips to a green bookmark for ~1.2 s (`flash`).
@MainActor
final class KeyMomentsModel: ObservableObject {

    /// True for ~1.2 s after a marker was dropped; the menu-bar icon reads it.
    @Published private(set) var flash = false
    @Published private(set) var count = 0

    private var workDir: URL?
    private var base: String?
    private var startedAt: Date?
    private var marks = RecordingBookmarks()
    private let hotkey = KeyMomentHotkey()
    private var flashTask: Task<Void, Never>?

    /// A recording started. Returns a human message when the hotkey was
    /// requested but could not be registered (combination taken by another
    /// app); the menu item keeps working either way.
    @discardableResult
    func begin(workDir: URL, base: String, source: String?, startedAt: Date,
               hotkey spec: HotkeySpec?) -> String? {
        end()
        self.workDir = workDir; self.base = base; self.startedAt = startedAt
        marks = RecordingBookmarks(source: source); count = 0
        UserDefaults.standard.removeObject(forKey: Self.hotkeyErrorKey)
        guard let spec else { return nil }
        if let failure = hotkey.register(spec, onPress: { [weak self] in self?.mark() }) {
            UserDefaults.standard.set(failure, forKey: Self.hotkeyErrorKey)
            return failure
        }
        return nil
    }

    /// UserDefaults key the Settings section reads to show a registration failure.
    static let hotkeyErrorKey = "distavo.keyMoments.hotkeyError"

    /// The recording stopped (kept): the sidecar stays, the hotkey is released.
    func end() {
        hotkey.unregister()
        workDir = nil; base = nil; startedAt = nil; marks = RecordingBookmarks(); count = 0
    }

    /// The recording was thrown away: nothing may outlive it.
    func endAndDelete() {
        if let workDir, let base { RecordingBookmarks.delete(workDir: workDir, base: base) }
        end()
    }

    var isActive: Bool { startedAt != nil }

    /// Drop a marker at the current recording offset (de-bounced to 1 s).
    @discardableResult
    func mark() -> Bool {
        guard let startedAt, let workDir, let base else { return false }
        guard marks.add(offsetSeconds: Date().timeIntervalSince(startedAt)) else { return false }
        count = marks.marks.count
        // A failed write is only logged: losing a marker must never disturb the recording.
        do { try marks.save(workDir: workDir, base: base) }
        catch { print("[Distavo] could not save the key moments: \(error.localizedDescription)") }
        flashTask?.cancel()
        flash = true
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !Task.isCancelled { self?.flash = false }
        }
        return true
    }
}

/// One global hotkey through Carbon's `RegisterEventHotKey` (the only public API
/// that works sandboxed without extra permissions). Press events arrive on the
/// application event target; the C callback hops to the main actor.
@MainActor
final class KeyMomentHotkey {
    private var ref: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    private static var onPress: (@MainActor () -> Void)?

    /// Registers `spec`; returns a message on failure (nil = registered).
    func register(_ spec: HotkeySpec, onPress: @escaping @MainActor () -> Void) -> String? {
        unregister()
        guard spec.isValid else { return "The key-moment shortcut \(spec.displayName) is not valid (it needs ⌃, ⌥ or ⌘)." }
        if Self.handler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { KeyMomentHotkey.onPress?() } }
                return noErr
            }, 1, &eventType, nil, &Self.handler)
            guard status == noErr else { return "Could not listen for the key-moment shortcut (error \(status))." }
        }
        Self.onPress = onPress
        let id = EventHotKeyID(signature: OSType(0x444B4D4B), id: 1)   // 'DKMK'
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(spec.keyCode), UInt32(spec.modifiers), id,
                                         GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else {
            Self.onPress = nil
            return "The key-moment shortcut \(spec.displayName) could not be registered - another app probably uses it. Choose a different combination in Settings > Recording; the menu item still works."
        }
        ref = newRef
        return nil
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.onPress = nil
    }
}
