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

    /// Meeting auto-detect offer (Vikunja #2945): "Record" / "Not now".
    enum MeetingAction { case record, notNow }
    static let meetingCategory = "distavo.meeting"
    static let meetingIdentifier = "distavo.meeting"
    private static let recordActionID = "distavo.meeting.record"
    private static let notNowActionID = "distavo.meeting.notnow"
    /// Called on the main actor when the user taps a meeting action.
    @MainActor var onMeetingAction: ((MeetingAction) -> Void)?

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
            UNNotificationCategory(identifier: Self.meetingCategory,
                                   actions: [UNNotificationAction(identifier: Self.recordActionID,
                                                                  title: "Record", options: [.foreground]),
                                             UNNotificationAction(identifier: Self.notNowActionID,
                                                                  title: "Not now", options: [])],
                                   intentIdentifiers: [], options: []),
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

    /// Post (or replace) the "call detected - record it?" offer (Vikunja #2945).
    func notifyMeeting(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.meetingCategory
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: Self.meetingIdentifier, content: content, trigger: nil))
    }

    func removeMeetingNotification() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.meetingIdentifier])
        center.removePendingNotificationRequests(withIdentifiers: [Self.meetingIdentifier])
    }

    /// True when the user has allowed banners (so the offer can be a notification;
    /// otherwise the caller falls back to a menu-bar hint).
    static func notificationsAllowed() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        default: return false
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Distavo is a menu-bar app that is always "foreground": show banners anyway.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .list] }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let meeting: MeetingAction? = switch response.actionIdentifier {
        case Self.recordActionID: .record
        case Self.notNowActionID: .notNow
        default: nil
        }
        if let meeting {
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated { self?.onMeetingAction?(meeting) }
            }
            return
        }
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
