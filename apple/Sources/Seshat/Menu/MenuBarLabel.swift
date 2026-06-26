import SwiftUI

/// The menu-bar item view. A waveform glyph with a small status bullet:
/// amber top-right while processing, green top-left when a new note is ready.
struct MenuBarLabel: View {
    let activity: WatcherController.Activity

    var body: some View {
        Image(systemName: "waveform")
            .overlay(alignment: .topLeading) {
                if activity == .done { dot(.green) }
            }
            .overlay(alignment: .topTrailing) {
                if activity == .processing { dot(.orange) }
            }
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            // Nudge the bullets to the icon's corners.
            .offset(x: activity == .done ? -2 : 2, y: -1)
    }
}
