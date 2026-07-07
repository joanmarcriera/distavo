#if EDITION_DIRECT
import Foundation
import Sparkle

/// Direct-edition auto-updater backed by Sparkle 2. The feed URL and EdDSA
/// public key come from the Info.plist (SUFeedURL / SUPublicEDKey, set in
/// project.yml for the Direct target). Compiled only when EDITION_DIRECT is
/// defined, so the App Store / Setapp targets never import or link Sparkle.
@MainActor
final class SparkleUpdater: AppUpdater {
    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true schedules background checks per the user's
        // preference; nil delegates use Sparkle's standard UI.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
#endif
