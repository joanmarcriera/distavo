// InPersonBoxPolicy.swift — when the end-of-recording sheet shows the "in the room / on a phone" box,
// and what it says (Vikunja #4023). Pure, so the decision is unit-tested; the sheet only renders it.
//
// The box only means something when no call audio was heard: with call audio the recording is plainly
// a call, so the box is hidden. The decision depends only on whether system audio was heard at all.
import Foundation

public struct InPersonBoxPolicy: Equatable, Sendable {
    public let visible: Bool
    public let title: String
    /// One line shown under the box.
    public let help: String
    /// Longer text for the tooltip: what ticking changes.
    public let tooltip: String

    public static func make(systemAudioHeard: Bool) -> InPersonBoxPolicy {
        let title = "In the room / on a phone (no call audio)"
        let help = "Distavo heard nothing from the other side of the call. Tick this if you were in the same room "
            + "or on a phone, so the recording isn't treated as a permission problem."
        let tip = "Ticking this: no permission warning is shown for this recording, and speakers are separated "
            + "from one microphone, so give the number of people who spoke."
        return InPersonBoxPolicy(visible: !systemAudioHeard, title: title, help: help, tooltip: tip)
    }
}
