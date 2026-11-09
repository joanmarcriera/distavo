import Foundation

// MicDiagnosis.swift — which message goes with "the microphone gave no sound" (Vikunja #3930).
//
// `MicLevelCheck` decides WHEN to warn; this decides WHAT to say, from facts the app reads from
// AVFoundation / Core Audio (permission, default input name, muted/zero gain). Pure so the wording
// choice is unit-tested; the app target only gathers the inputs and renders the actions. Nothing
// here opens System Settings: `.openMicrophoneSettings` is an action the user clicks (#4022).

public enum MicDiagnosis {
    public enum Permission: Sendable { case granted, denied, undetermined, restricted }
    public enum Cause: Equatable, Sendable { case permissionDenied, permissionNotAsked, permissionRestricted, inputMuted, noInputDevice, unknown }
    public enum Action: Equatable, Sendable { case openMicrophoneSettings, switchInput, ignore }

    public struct Result: Equatable, Sendable {
        public let cause: Cause
        public let message: String
        public let actions: [Action]
    }

    public static func diagnose(permission: Permission, inputName: String?, inputMuted: Bool) -> Result {
        let name = inputName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = (name?.isEmpty == false) ? name : nil
        if permission == .denied {
            return Result(cause: .permissionDenied,
                          message: "Distavo may not use the microphone. Allow it in System Settings, then restart the recording.",
                          actions: [.openMicrophoneSettings, .ignore])
        }
        if permission == .restricted {
            return Result(cause: .permissionRestricted,
                          message: "Microphone access is restricted on this Mac (parental controls or a managed profile), so Distavo cannot use it.",
                          actions: [.ignore])
        }
        if permission == .undetermined {
            return Result(cause: .permissionNotAsked,
                          message: "Microphone access has not been answered yet. Allow it when macOS asks, or in System Settings.",
                          actions: [.openMicrophoneSettings, .ignore])
        }
        guard let device else {
            return Result(cause: .noInputDevice,
                          message: "No microphone is selected as the input. Pick one to record your side.",
                          actions: [.switchInput, .ignore])
        }
        if inputMuted {
            return Result(cause: .inputMuted,
                          message: "\u{201C}\(device)\u{201D} is muted or its input volume is zero.",
                          actions: [.switchInput, .ignore])
        }
        return Result(cause: .unknown,
                      message: "Nothing is coming in from \u{201C}\(device)\u{201D}. Is it muted, switched on, or is another input meant?",
                      actions: [.switchInput, .openMicrophoneSettings, .ignore])
    }
}
