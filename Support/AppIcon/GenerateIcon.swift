// Renders the MinStats app icon — a metallic hex nut with a thin cold→hot
// ring around the hole — into a macOS .iconset directory. Vector drawing,
// rendered natively at each size (no downscaling), so it's crisp at 16px
// and 1024px alike. Run: `swift GenerateIcon.swift <output-iconset-dir>`
//
// The warm-ring colors match the app's temperature gradient
// (StatusBarController.compactImage / DetailView.temperatureGradient).

import AppKit

func c(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

/// Flat-top hexagon centered at (cx, cy) with circumradius r.
func hexPath(cx: CGFloat, cy: CGFloat, r: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    for (i, deg) in [0.0, 60, 120, 180, 240, 300].enumerated() {
        let a = CGFloat(deg) * .pi / 180
        let pt = NSPoint(x: cx + r * cos(a), y: cy + r * sin(a))
        i == 0 ? path.move(to: pt) : path.line(to: pt)
    }
    path.close()
    return path
}

func renderIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(size)
    let cx = s / 2, cy = s / 2

    // Squircle background.
    let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                          xRadius: s * 0.2237, yRadius: s * 0.2237)
    bg.addClip()
    NSGradient(starting: c(0x56, 0x5B, 0x63), ending: c(0x24, 0x26, 0x2A))!
        .draw(in: NSRect(x: 0, y: 0, width: s, height: s), angle: -90)

    // Soft drop shadow under the nut.
    let hex = hexPath(cx: cx, cy: cy, r: s * 0.32)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = s * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()

    // Steel body.
    hex.addClip()
    let steel = NSGradient(colorsAndLocations:
        (c(0xF2, 0xF4, 0xF7), 0.0), (c(0xC4, 0xCA, 0xD2), 0.5), (c(0x7C, 0x85, 0x91), 1.0))!
    steel.draw(in: NSRect(x: 0, y: 0, width: s, height: s), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Top sheen: subtle light wash over the upper half of the nut.
    NSGraphicsContext.saveGraphicsState()
    hex.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.22), ending: NSColor.white.withAlphaComponent(0.0))!
        .draw(in: NSRect(x: 0, y: cy, width: s, height: cy), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Edge stroke for definition.
    c(0x3E, 0x43, 0x4B).setStroke()
    hex.lineWidth = max(1, s * 0.006)
    hex.stroke()

    // Warm cold→hot ring around the hole.
    let ringOuter = s * 0.150, ringInner = s * 0.125
    let ring = NSBezierPath()
    ring.appendOval(in: NSRect(x: cx - ringOuter, y: cy - ringOuter, width: 2 * ringOuter, height: 2 * ringOuter))
    ring.appendOval(in: NSRect(x: cx - ringInner, y: cy - ringInner, width: 2 * ringInner, height: 2 * ringInner))
    ring.windingRule = .evenOdd
    NSGraphicsContext.saveGraphicsState()
    ring.addClip()
    NSGradient(colorsAndLocations:
        (c(0x59, 0x9E, 0xEB), 0.0), (c(0xFA, 0xA8, 0x40), 0.5), (c(0xE6, 0x4D, 0x47), 1.0))!
        .draw(in: NSRect(x: cx - ringOuter, y: cy - ringOuter, width: 2 * ringOuter, height: 2 * ringOuter), angle: 0)
    NSGraphicsContext.restoreGraphicsState()

    // Hole: recessed dark circle.
    let holeRect = NSRect(x: cx - ringInner, y: cy - ringInner, width: 2 * ringInner, height: 2 * ringInner)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(ovalIn: holeRect).addClip()
    NSGradient(starting: c(0x24, 0x26, 0x2A), ending: c(0x0D, 0x0E, 0x10))!
        .draw(in: holeRect, relativeCenterPosition: NSPoint(x: 0, y: 0.25))
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// macOS iconset: (pixel size, filename).
let entries: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try! FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (size, name) in entries {
    let png = renderIcon(size: size).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
print("Wrote \(entries.count) icons to \(outDir)")
