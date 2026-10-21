// DiscardPrompt.swift — the "Delete this recording?" confirmation (Vikunja #3929).
//
// The alert is built in the app target; the decision of WHICH button is the default
// lives here so a headless test can pin it: Return must never delete a take. The safe
// answer ("Keep recording") is the FIRST button (NSAlert's default, Return); the
// destructive one is second and is reached only by click or by Tab/Space.
import Foundation

public enum DiscardPrompt {
    /// Button titles in NSAlert order: index 0 is the default button (Return).
    public static let buttonTitles = ["Keep recording", "Delete recording"]
    /// Index of the destructive button.
    public static let destructiveIndex = 1

    /// `index` is the position of the pressed button (NSAlert: firstButtonReturn = 0).
    public static func shouldDelete(buttonIndex index: Int) -> Bool { index == destructiveIndex }

    /// What Return (the default button) does.
    public static var returnDeletes: Bool { shouldDelete(buttonIndex: 0) }
}
