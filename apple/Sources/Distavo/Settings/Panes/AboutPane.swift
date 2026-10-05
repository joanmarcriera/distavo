import SwiftUI
import Foundation

/// About: version and the privacy promise. Read-only; no settings and no
/// edition-specific links (donate/support live in the menu, gated there).
struct AboutPane: View {
    @ObservedObject var model: SettingsModel

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (build \(build))"
    }

    var body: some View {
        Section("Distavo") {
            LabeledContent("Version", value: versionLabel)
            SettingCaption("Distavo turns recordings into Markdown meeting notes on your own hardware. Nothing is ever sent to a cloud service.")
        }
    }
}
