import Foundation
import AppKit
import AudioToolbox
import DistavoCore

/// Meeting auto-detect (Vikunja #2945): once a second, while the feature is
/// enabled in Settings, notice that a listed meeting app (Zoom, Teams, FaceTime,
/// ...) is running AND some process is capturing from the default input device,
/// and offer to start the built-in recorder. The decision is `MeetingDetector`
/// (pure, in DistavoCore); this class only gathers observations and shows the
/// offer.
///
/// What it touches, all without a permission prompt or an entitlement:
///  - `NSWorkspace.shared.runningApplications` / `frontmostApplication`
///    (bundle ids only);
///  - Core Audio `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default
///    input device - a yes/no flag, it never opens the microphone, starts a
///    capture, or hears audio.
/// No private API, Accessibility or AppleScript. Nothing is recorded until the
/// user clicks Record, which goes through the same path as the menu's item.
///
/// Zero cost when off: `configure()` creates the timer only while
/// `config.meetingDetection.enabled` (and the recorder is supported), and
/// invalidates it otherwise - no timer, no observers, no polling.
@MainActor
final class MeetingDetectionController: ObservableObject {
    /// Non-nil while an offer is pending, e.g. "Zoom call detected". Drives the
    /// menu-bar fallback (a transient "Record" / "Not now" menu item) used
    /// whether or not the notification could be shown.
    @Published private(set) var pendingOffer: String?

    private let configProvider: () -> Config
    private let isRecording: () -> Bool
    private let startRecording: () -> Void
    private let notifyOffer: (String, String) -> Void
    private let clearNotification: () -> Void
    private let log: (String) -> Void

    private var detector: MeetingDetector?
    private var timer: Timer?
    private var offeredApp: String?
    private var wasMicInUse = false

    init(configProvider: @escaping () -> Config,
         isRecording: @escaping () -> Bool,
         startRecording: @escaping () -> Void,
         notifyOffer: @escaping (String, String) -> Void,
         clearNotification: @escaping () -> Void,
         log: @escaping (String) -> Void) {
        self.configProvider = configProvider
        self.isRecording = isRecording
        self.startRecording = startRecording
        self.notifyOffer = notifyOffer
        self.clearNotification = clearNotification
        self.log = log
    }

    /// Whether the feature is active for this config (also hidden below macOS 14.4,
    /// where there is no built-in recorder to offer).
    private var active: Bool {
        MeetingCaptureController.isSupported && configProvider().meetingDetection.enabled
    }

    /// Start or stop polling to match Settings. Call at launch and after every
    /// config change; idempotent.
    func configure() {
        if active {
            if timer == nil {
                detector = MeetingDetector(policy: MeetingDetectionPolicy(config: configProvider().meetingDetection))
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                log("Meeting detection on")
            }
        } else if timer != nil || pendingOffer != nil {
            timer?.invalidate()
            timer = nil
            detector = nil
            dismissOffer()
            log("Meeting detection off")
        }
    }

    private func tick() {
        guard var detector else { return }
        detector.policy = MeetingDetectionPolicy(config: configProvider().meetingDetection)
        let mic = Self.defaultInputIsRunningSomewhere()
        // The episode is over once the mic goes idle: withdraw a stale offer.
        if mic == false, wasMicInUse { dismissOffer() }
        wasMicInUse = mic == true
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let event = detector.observe(MeetingObservation(
            runningBundleIDs: Set(running),
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            micInUse: mic, isRecording: isRecording(), now: Date()))
        self.detector = detector
        if case .offerRecording(let app) = event { present(app: app) }
    }

    private func present(app: String) {
        let name = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == app }?.localizedName
            ?? MeetingDetectionConfig.displayName(forBundleID: app)
        offeredApp = app
        pendingOffer = "\(name) call detected"
        log("Meeting detected (\(app)) - offered to record")
        Task { [weak self] in
            // Notification when allowed; the menu item above is the fallback.
            if await Notifier.notificationsAllowed() {
                self?.notifyOffer("\(name) call detected — record it?",
                                  "Nothing is recorded unless you choose Record.")
            }
        }
    }

    /// "Record" (notification button or menu item).
    func accept() {
        guard pendingOffer != nil else { return }
        dismissOffer()
        guard !isRecording() else { return }
        log("Meeting recording started from a detection offer")
        startRecording()
    }

    /// "Not now": snooze that app for the configured time.
    func decline() {
        if let app = offeredApp {
            detector?.snooze(app: app, at: Date())
            log("Meeting offer declined - snoozed \(app) for \(configProvider().meetingDetection.snoozeMinutes) min")
        }
        dismissOffer()
    }

    private func dismissOffer() {
        pendingOffer = nil
        offeredApp = nil
        clearNotification()
    }

    // MARK: Core Audio

    /// Is any process capturing from the default input device? `nil` when it
    /// cannot be read (no input device, Core Audio error) - the policy then
    /// applies its mic-unknown rules. Read-only property query; no TCC prompt.
    static func defaultInputIsRunningSomewhere() -> Bool? {
        guard let device = try? AudioObjectID.readDefaultInputDevice(), device.isValid else { return nil }
        guard let running: UInt32 = try? device.read(
            kAudioDevicePropertyDeviceIsRunningSomewhere, defaultValue: UInt32(0)) else { return nil }
        return running != 0
    }
}
