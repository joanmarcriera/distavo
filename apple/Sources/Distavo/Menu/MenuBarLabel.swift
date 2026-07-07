import SwiftUI

/// The menu-bar item view. A glyph whose shape + tint reflect the app state:
/// idle, recording, loading, transcribing, or a new note ready to read.
/// Distinct symbols (not colour alone) keep the states legible for everyone.
struct MenuBarLabel: View {
    let state: WatcherController.IconState

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(tint)
    }

    private var symbol: String {
        switch state {
        case .idle:         return "waveform"
        case .recording:    return "record.circle"
        case .loading:      return "waveform.badge.plus"
        case .transcribing: return "waveform.badge.magnifyingglass"
        case .done:         return "waveform.badge.checkmark"
        }
    }

    private var tint: Color {
        switch state {
        case .idle:         return .primary
        case .recording:    return .red
        case .loading:      return .secondary
        case .transcribing: return .orange
        case .done:         return .green
        }
    }
}
