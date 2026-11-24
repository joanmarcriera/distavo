import Foundation

/// Frame for an `NSAlert` accessory form (the "Who was in this meeting?" sheet, #6982/#6983).
///
/// The sheet used to be a fixed 450 x 300 (350 with language detection). With every optional row
/// showing it needs about 430 pt, so rows overlapped. The size must follow the content and never
/// be smaller than it. Pure so a test pins the rule; the app target feeds it `fittingSize`.
public enum AccessoryFormSizing {
    public static let minimumWidth: Double = 450
    public static let minimumHeight: Double = 120

    public static func frame(fittingWidth: Double, fittingHeight: Double) -> (width: Double, height: Double) {
        let w = fittingWidth.isFinite ? fittingWidth : 0
        let h = fittingHeight.isFinite ? fittingHeight : 0
        return (max(minimumWidth, w.rounded(.up)), max(minimumHeight, h.rounded(.up)))
    }
}
