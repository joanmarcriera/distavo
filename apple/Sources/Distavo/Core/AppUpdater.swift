import Foundation

/// Abstraction over the auto-updater so the menu and settings don't depend on
/// Sparkle directly. Only the Direct edition provides a real implementation;
/// the App Store and Setapp editions return nil (their stores handle updates),
/// which keeps the "Check for Updates" UI out of those builds.
@MainActor
protocol AppUpdater: AnyObject {
    func checkForUpdates()
    var automaticallyChecksForUpdates: Bool { get set }
}

enum AppUpdaterFactory {
    @MainActor
    static func make() -> AppUpdater? {
        #if EDITION_DIRECT
        return SparkleUpdater()
        #else
        return nil
        #endif
    }
}
