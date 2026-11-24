// Usage: swiftc -o "$TMPDIR/chk" apple/scripts/stop-sheet-layout-check.swift && "$TMPDIR/chk"
// Headless NSAlert probe for #6982/#6983 (the "Who was in this meeting?" sheet with every row showing).
// fixed350 = the old fixed frame: the stack overflows the alert's container, the people-count field sits outside it
// and over the alert's own selectable message text, so a click on it hits the wrong view (expected: FAIL).
// fitted   = the fix (frame from fittingSize): a click on the field reaches the field. Exit 1 if fitted fails.
import AppKit
_ = NSApplication.shared
func row(_ label: String, _ field: NSView, width: CGFloat) -> NSView {
    let text = NSTextField(labelWithString: label); text.alignment = .right
    text.widthAnchor.constraint(equalToConstant: 140).isActive = true
    field.widthAnchor.constraint(equalToConstant: width).isActive = true
    let s = NSStackView(views: [text, field]); s.orientation = .horizontal; s.alignment = .firstBaseline; return s
}
var fittedOK = true
for mode in ["fixed350", "fitted"] {
    let count = NSTextField(string: "2")
    let help = NSTextField(wrappingLabelWithString: "Speaker separation needs the number of people; with one microphone Distavo cannot tell voices apart by channel, so enter how many people spoke.")
    let src = NSTextField(wrappingLabelWithString: "Suggested from the calendar event and your last three meetings with these people.")
    var rows = [row("People who spoke:", count, width: 60), row("", NSTextField(labelWithString: "warn"), width: 300),
                row("Your role (me):", NSTextField(string: ""), width: 300), row("Other participants:", NSTextField(string: "A, B"), width: 300)]
    rows.append(row("", NSPopUpButton(frame: .zero, pullsDown: false), width: 300))
    rows.append(row("Terms for this meeting:", NSTextField(string: ""), width: 300))
    rows.append(row("", src, width: 300))
    rows.append(row("", NSButton(checkboxWithTitle: "In person", target: nil, action: nil), width: 300))
    rows.append(row("", help, width: 300))
    rows.append(row("Meeting language:", NSPopUpButton(frame: .zero, pullsDown: false), width: 200))
    rows.append(NSStackView(views: [NSTextField(labelWithString: ""), NSTextField(labelWithString: "Detecting")]))
    rows.append(row("Write notes in:", NSPopUpButton(frame: .zero, pullsDown: false), width: 200))
    rows.append(row("Note template:", NSPopUpButton(frame: .zero, pullsDown: false), width: 200))
    let form = NSStackView(views: rows); form.orientation = .vertical; form.alignment = .trailing; form.spacing = 8
    if mode == "fixed350" { form.frame = NSRect(x: 0, y: 0, width: 450, height: 350) }
    else { form.layoutSubtreeIfNeeded(); let s = form.fittingSize; form.frame = NSRect(x: 0, y: 0, width: max(450, s.width.rounded(.up)), height: max(120, s.height.rounded(.up))) }
    let alert = NSAlert()
    alert.messageText = "Who was in this meeting?"
    alert.informativeText = "Distavo uses this to name the speakers and write the notes and follow-up email from your side. Leave it blank to skip. (Turn this question off in Settings.)"
    alert.accessoryView = form
    alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Skip")
    alert.layout()
    alert.window.contentView?.layoutSubtreeIfNeeded()
    let cv = alert.window.contentView!
    let formInWin = form.convert(form.bounds, to: cv)
    let countInWin = count.convert(count.bounds, to: cv)
    let helpInWin = help.convert(help.bounds, to: cv)
    let center = NSPoint(x: countInWin.midX, y: countInWin.midY)
    let hit = cv.hitTest(center)
    if mode == "fitted" { fittedOK = hit === count || hit?.isDescendant(of: count) == true }
    func desc(_ v: NSView?) -> String { guard let v else { return "nil" }; if let t = v as? NSTextField { return "NSTextField(\"\(t.stringValue.prefix(30))\", selectable=\(t.isSelectable), editable=\(t.isEditable))" }; return String(describing: type(of: v)) }
    print("\(mode): form=\(formInWin.integral) count=\(countInWin.integral) help=\(helpInWin.integral) formFrameH=\(form.frame.height) fitting=\(form.fittingSize.height)")
    print("   hit at count centre -> \(desc(hit)); hit is count or its editor: \(hit === count || hit?.isDescendant(of: count) == true)")
    print("   clipsToBounds form=\(form.clipsToBounds) superview=\(String(describing: type(of: form.superview!))) superFrame=\(form.superview!.convert(form.superview!.bounds, to: cv).integral) contentH=\(cv.bounds.height)")
    func walk(_ v: NSView) { for s in v.subviews { if let t = s as? NSTextField, !t.stringValue.isEmpty, !t.isDescendant(of: form) { print("   alert text: \(t.stringValue.prefix(25)) frame=\(t.convert(t.bounds, to: cv).integral) selectable=\(t.isSelectable)") }; walk(s) } }
    walk(cv)
}
print("fitted hit-test ok: \(fittedOK)")
exit(fittedOK ? 0 : 1)
