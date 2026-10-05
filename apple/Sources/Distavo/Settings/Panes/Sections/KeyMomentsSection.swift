import SwiftUI
import AppKit
import DistavoCore

/// Recording pane, "Key moments" section (Vikunja #2950): the optional global
/// hotkey that drops a marker while recording, and how much audio an exported
/// clip keeps around a marker. The menu item "Mark Key Moment" works regardless.
/// Shown only where the built-in recorder exists (macOS 14.4+).
struct KeyMomentsSection: View {
    @ObservedObject var model: SettingsModel
    /// Set by the recorder when the last registration failed (combination taken).
    @AppStorage(KeyMomentsModel.hotkeyErrorKey) private var hotkeyError = ""

    var body: some View {
        Section("Key moments") {
            Toggle("Mark key moments with a keyboard shortcut",
                   isOn: $model.draft.recording.bookmarkHotkeyEnabled)
                .withHelp("While a recording runs, the shortcut drops a marker at that moment from any app, without switching windows. The note then lists each marker with its time and the sentence being spoken, and Export Key Moment Clips… in the menu cuts an audio clip around each one. It is only active during a recording and needs no extra permission. The menu item Mark Key Moment does the same without a shortcut.")
            if model.draft.recording.bookmarkHotkeyEnabled {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    HotkeyRecorderField(spec: $model.draft.recording.bookmarkHotkey)
                        .frame(width: 130, height: 24)
                    Button("Reset") { model.draft.recording.bookmarkHotkey = .default }
                        .disabled(model.draft.recording.bookmarkHotkey == .default)
                }
                SettingCaption("Click the box, then press the keys (include ⌃, ⌥ or ⌘). Applies to the next recording.")
                if !hotkeyError.isEmpty { SettingCaption("⚠︎ \(hotkeyError)") }
            }
            Stepper("Clip starts \(model.draft.recording.clipLeadSeconds) s before the marker",
                    value: $model.draft.recording.clipLeadSeconds, in: RecordingOptions.clipSecondsRange, step: 5)
            Stepper("Clip ends \(model.draft.recording.clipTailSeconds) s after the marker",
                    value: $model.draft.recording.clipTailSeconds, in: RecordingOptions.clipSecondsRange, step: 5)
        }
    }
}

/// A click-to-record shortcut field: click it, press a combination, it shows
/// e.g. "⌃⌥⌘M". Rejects combinations without ⌘/⌥/⌃ (they would steal typing).
private struct HotkeyRecorderField: NSViewRepresentable {
    @Binding var spec: HotkeySpec

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.onChange = { spec = $0 }
        v.spec = spec
        return v
    }

    func updateNSView(_ v: RecorderView, context: Context) { v.spec = spec }

    final class RecorderView: NSView {
        var spec = HotkeySpec.default { didSet { needsDisplay = true } }
        var onChange: ((HotkeySpec) -> Void)?
        private var recording = false { didSet { needsDisplay = true } }
        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); recording = true }
        override func resignFirstResponder() -> Bool { recording = false; return true }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == 53 { recording = false; return }   // Escape cancels
            let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var mods = 0
            if f.contains(.control) { mods |= HotkeySpec.control }
            if f.contains(.option) { mods |= HotkeySpec.option }
            if f.contains(.shift) { mods |= HotkeySpec.shift }
            if f.contains(.command) { mods |= HotkeySpec.cmd }
            let candidate = HotkeySpec(keyCode: Int(event.keyCode), modifiers: mods)
            guard candidate.isValid else { NSSound.beep(); return }   // in Settings, not during a meeting
            spec = candidate
            onChange?(candidate)
            recording = false
        }

        override func draw(_ dirtyRect: NSRect) {
            let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            box.stroke()
            let text = recording ? "Press keys…" : spec.displayName
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                                y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }
    }
}
