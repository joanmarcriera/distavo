import SwiftUI

/// Small building blocks shared by the Settings panes (Vikunja #2957).
///
/// House style for a row: the control, then — only if it needs explaining — a one-line
/// `SettingCaption`, and the long explanation in a `HelpButton` popover (`.withHelp`).
/// Keep captions to one short sentence; put the detail in the popover, never drop it.

/// A short secondary-text line under a control.
struct SettingCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// Put a "?" popover button after this control, holding the detailed explanation.
    func withHelp(_ detail: String) -> some View {
        HStack {
            self
            HelpButton(text: detail)
        }
    }
}

/// An amber callout box (used for guidance and warnings in Connections).
struct SettingCallout<Content: View>: View {
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.orange)
            content
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}
