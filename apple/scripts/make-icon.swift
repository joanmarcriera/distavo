#!/usr/bin/env swift
import AppKit

// Generates apple/Resources/Assets.xcassets/AppIcon.appiconset (macOS sizes):
// a white "waveform" glyph on a rounded-rect indigo→teal gradient.
// Run: swift apple/scripts/make-icon.swift   (from the repo root or apple/)

func tint(_ image: NSImage, _ color: NSColor) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    color.set()
    let rect = NSRect(origin: .zero, size: image.size)
    image.draw(in: rect)
    rect.fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

func makeMaster(_ size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.2237
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.36, blue: 0.86, alpha: 1),
        NSColor(srgbRed: 0.13, green: 0.74, blue: 0.71, alpha: 1),
    ])!
    gradient.draw(in: rect, angle: -45)

    let config = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .semibold)
    if let base = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let glyph = tint(base, .white)
        let s = glyph.size
        glyph.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2,
                              width: s.width, height: s.height))
    }
    image.unlockFocus()
    return image
}

func pngData(_ image: NSImage, px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let appleDir = here.deletingLastPathComponent()  // scripts/ -> apple/
let outDir = appleDir.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let master = makeMaster(1024)

// (filename, pixel size, idiom-size string, scale)
let entries: [(String, Int, String, String)] = [
    ("icon_16.png", 16, "16x16", "1x"),
    ("icon_16@2x.png", 32, "16x16", "2x"),
    ("icon_32.png", 32, "32x32", "1x"),
    ("icon_32@2x.png", 64, "32x32", "2x"),
    ("icon_128.png", 128, "128x128", "1x"),
    ("icon_128@2x.png", 256, "128x128", "2x"),
    ("icon_256.png", 256, "256x256", "1x"),
    ("icon_256@2x.png", 512, "256x256", "2x"),
    ("icon_512.png", 512, "512x512", "1x"),
    ("icon_512@2x.png", 1024, "512x512", "2x"),
]

var images: [String] = []
for (name, px, sizeStr, scale) in entries {
    try! pngData(master, px: px).write(to: outDir.appendingPathComponent(name))
    images.append("""
        {"idiom":"mac","size":"\(sizeStr)","scale":"\(scale)","filename":"\(name)"}
    """.trimmingCharacters(in: .whitespaces))
}

let contents = """
{
  "images": [
    \(images.joined(separator: ",\n    "))
  ],
  "info": {"version": 1, "author": "xcode"}
}
"""
try! contents.write(to: outDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(entries.count) icon PNGs + Contents.json to \(outDir.path)")
