import Foundation
import AppKit
import AudioToolbox
import DistavoCore

/// Meeting auto-detect (Vikunja #2945): once a second, while the feature is
/// enabled in Settings, notice that a listed meeting app (Zoom, Teams, FaceTime,
/// ...) is capturing from the microphone and offer to start the built-in
/// recorder. The decision is `MeetingDetector` (pure, in DistavoCore); this class
/// only gathers observations and shows the offer.
///
/// What it reads, all read-only metadata queries (no stream, tap, aggregate
/// device or capture, and - expected, UNVERIFIED in the sandbox - no TCC prompt):
///  - `NSWorkspace` running/frontmost applications (bundle ids only);
///  - Core Audio's per-process objects (macOS 14.2+): for each, its bundle id,
///    pid and `kAudioProcessPropertyIsRunningInput`. This identifies WHICH
///    process captures the mic; the device-level "running somewhere" flag is
///    not used because it is also true while output plays (headset music).
/// No private API, Accessibility or AppleScript. Nothing is recorded until the
/// user clicks Record.
///
/// Zero cost when off: `configure()` creates the timer only while
/// `config.meetingDetection.enabled` (and the recorder is supported), and
/// invalidates it otherwise - no timer, no observers, no polling.
@MainActor
final class MeetingDetectionController: ObservableObject {
    /// Non-nil while an offer is pending, e.g. "Zoom is using the microphone".
    /// Drives the menu-bar fallback (a transient "Record" / "Not now" item).
    @Published private(set) var pendingOffer: String?

    private let configProvider: () -> Config
    private let isRecording: () -> Bool
    private let startRecording: () -> Void
    private let notifyOffer: (String, String) -> Void
    private let clearNotification: () -> Void
    private let log: (String) -> Void

    private var detector: MeetingDetector?
    private var timer: Timer?
    /// Listed bundle id the pending offer is about (used for "Not now").
    private var offeredApp: String?
    /// The offer came from the mic-unknown fallback (no app is named).
    private var offerWasFallback = false

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

    /// Whether the feature is active for this config (hidden below macOS 14.4,
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
                let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                t.tolerance = 0.5   // lets macOS coalesce the wake-ups
                timer = t
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
        let recording = isRecording()
        let capturing = Self.capturingBundleIDs()
        // A pending offer is stale once a recording runs (started by any route)
        // or its app stopped capturing (the call/mic episode ended).
        if pendingOffer != nil {
            let stillCapturing = offeredApp.map { app in
                capturing?.contains { detector.policy.listedApp(forCapturing: $0) == app } ?? true
            } ?? false
            if recording || (!offerWasFallback && !stillCapturing) { dismissOffer() }
        }
        let event = detector.observe(MeetingObservation(
            runningBundleIDs: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)),
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            capturingBundleIDs: capturing, isRecording: recording,
            now: ProcessInfo.processInfo.systemUptime))
        self.detector = detector
        switch event {
        case .none: break
        case .offerRecording(let app): present(app: app, name: Self.name(for: app), fallback: false)
        case .offerPossibleCall(let frontmost): present(app: frontmost, name: nil, fallback: true)
        }
    }

    private static func name(for app: String) -> String {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == app }?.localizedName
            ?? MeetingDetectionConfig.displayName(forBundleID: app)
    }

    private func present(app: String, name: String?, fallback: Bool) {
        let headline = name.map { "\($0) is using the microphone" } ?? "A call may be in progress"
        offeredApp = app
        offerWasFallback = fallback
        pendingOffer = headline
        log("Meeting offer: \(headline) (\(app))")
        Task { [weak self] in
            // Notification when allowed; the menu item is the fallback.
            if await Notifier.notificationsAllowed(), self?.pendingOffer == headline {
                self?.notifyOffer(headline, "Record this call? Nothing is recorded unless you choose Record.")
            }
        }
    }

    /// "Record" (notification button or menu item): a start-only action.
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
            detector?.snooze(app: app, at: ProcessInfo.processInfo.systemUptime)
            log("Meeting offer declined - snoozed \(app) for \(configProvider().meetingDetection.snoozeMinutes) min")
        }
        dismissOffer()
    }

    /// Clear the menu item AND withdraw the delivered notification.
    private func dismissOffer() {
        pendingOffer = nil
        offeredApp = nil
        offerWasFallback = false
        clearNotification()
    }

    // MARK: Core Audio (per-process input state)

    /// Bundle ids of processes currently capturing input, Distavo excluded;
    /// `nil` when the per-process API is unavailable or errors. A process whose
    /// Core Audio bundle id is empty falls back to `NSRunningApplication` by pid.
    /// Helper processes (e.g. `com.microsoft.teams2.helper`) are mapped to their
    /// listed app by `MeetingDetectionPolicy.listedApp`.
    static func capturingBundleIDs() -> Set<String>? {
        guard #available(macOS 14.4, *) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(.system, &address, 0, nil, &size) == noErr else { return nil }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(.system, &address, 0, nil, &size, &objects) == noErr else { return nil }

        let me = ProcessInfo.processInfo.processIdentifier
        var ids = Set<String>()
        for object in objects where object.isValid {
            guard let running: UInt32 = try? object.read(kAudioProcessPropertyIsRunningInput, defaultValue: UInt32(0)),
                  running != 0 else { continue }
            let pid: pid_t? = try? object.read(kAudioProcessPropertyPID, defaultValue: pid_t(0))
            if pid == me { continue }
            var bundle = (try? object.read(kAudioProcessPropertyBundleID, defaultValue: "" as CFString)).map { $0 as String } ?? ""
            if bundle.isEmpty, let pid { bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "" }
            if !bundle.isEmpty { ids.insert(bundle) }
        }
        return ids
    }
}
