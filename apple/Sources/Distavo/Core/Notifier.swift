import Foundation
import UserNotifications

/// Thin wrapper over UserNotifications (replaces rumps.notification).
///
/// Also the `UNUserNotificationCenterDelegate`, needed for the actionable
/// silence notification (Vikunja #2665): "Stop recording" / "Keep recording"
/// buttons on a "still recording?" suggestion. Notification actions and the
/// delegate are sandbox-safe and need no extra entitlement, so this is the
/// same in every edition.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// The user's choice on a silence notification.
    enum SilenceAction { case stop, keep }

    static let silenceCategory = "distavo.silence"
    /// Fixed identifier so the suggestion never stacks and can be withdrawn.
    static let silenceIdentifier = "distavo.silence"
    private static let stopActionID = "distavo.silence.stop"
    private static let keepActionID = "distavo.silence.keep"

    /// Called on the main actor when the user taps a silence action.
    @MainActor var onSilenceAction: ((SilenceAction) -> Void)?

    /// Become the notification delegate and register the silence category.
    /// Call once at launch, before the first notification is posted.
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let stop = UNNotificationAction(identifier: Self.stopActionID,
                                        title: "Stop recording", options: [])
        let keep = UNNotificationAction(identifier: Self.keepActionID,
                                        title: "Keep recording", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.silenceCategory,
                                   actions: [stop, keep], intentIdentifiers: [], options: []),
        ])
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Post (or replace) the silence suggestion with its two actions.
    func notifySilence(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.silenceCategory
        let request = UNNotificationRequest(
            identifier: Self.silenceIdentifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Withdraw the silence suggestion (sound resumed, Keep, or any stop).
    func removeSilenceNotification() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.silenceIdentifier])
        center.removePendingNotificationRequests(withIdentifiers: [Self.silenceIdentifier])
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Distavo is a menu-bar app that is always "foreground": show banners anyway.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .list] }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let action: SilenceAction
        switch response.actionIdentifier {
        case Self.stopActionID: action = .stop
        case Self.keepActionID: action = .keep
        default: return   // a plain tap on the banner: nothing to do
        }
        // Deliver from a run-loop callout, not a main-queue job: "Stop" ends
        // in a modal dialog, and AppKit does not service main-queue work
        // while a modal loop started from a queued job is up.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.onSilenceAction?(action) }
        }
    }
}
