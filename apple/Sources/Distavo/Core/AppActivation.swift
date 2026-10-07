import AppKit

/// Distavo is a menu-bar app (`.accessory`) that becomes a regular app while one
/// of its windows is open. Each window controller used to drop back to
/// `.accessory` on close on its own; since 1.18 the Notes window opens other
/// windows (Transcript, Compare, Ask), so closing one of those must not hide the
/// Dock icon while Notes is still open.
@MainActor
enum AppActivation {
    /// Call from `windowWillClose`: menu-bar-only again once no other window is left.
    static func windowClosed(_ closing: NSWindow?) {
        let othersOpen = NSApp.windows.contains {
            $0 !== closing && ($0.isVisible || $0.isMiniaturized) && $0.styleMask.contains(.titled) && !($0 is NSPanel)
        }
        if !othersOpen { NSApp.setActivationPolicy(.accessory) }
    }
}
