// SilenceNoticeAction.swift — what a button on the silence notification means (D027, tasks 6671/6760).
//
// The notification ("Still recording, no sound for N min") offers Keep recording / Stop and keep /
// Stop and discard. The identifiers and their meaning live here so they are unit-tested; `Notifier`
// registers the buttons and `MeetingCaptureController` carries them out ("Stop and discard" goes to the
// existing `discard()`, which asks for confirmation first, #3929). Anything unknown, including a plain tap
// on the banner, means keep recording: a notification can never stop or delete by accident.

import Foundation

public enum SilenceNoticeAction: Equatable, Sendable {
    case keepRecording
    case stopKeep
    case stopDiscard

    /// Shipped identifiers keep their values so a notice posted by the previous build still works.
    public static let keepID = "distavo.silence.keep"
    public static let stopKeepID = "distavo.silence.stop"
    public static let stopDiscardID = "distavo.silence.discard"

    public init(identifier: String) {
        switch identifier {
        case Self.stopKeepID: self = .stopKeep
        case Self.stopDiscardID: self = .stopDiscard
        default: self = .keepRecording
        }
    }

    /// Button titles, in display order.
    public static let buttons: [(id: String, title: String)] = [
        (stopKeepID, "Stop and keep"),
        (keepID, "Keep recording"),
        (stopDiscardID, "Stop and discard…"),
    ]
}
