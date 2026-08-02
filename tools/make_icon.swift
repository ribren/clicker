// Renders the app icon: a macOS-style squircle drawn as the remote itself —
// light gray body, dark clickpad with dots, two buttons below.
// Usage: swift tools/make_icon.swift <output.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
}

// Body squircle (Apple icon grid: 824pt content box in 1024).
let body = NSBezierPath(
    roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
    xRadius: 186, yRadius: 186
)
NSGradient(
    starting: color(0.886, 0.886, 0.902),
    ending: color(0.769, 0.769, 0.796)
)!.draw(in: body, angle: -90)
color(0.60, 0.60, 0.62).setStroke()
body.lineWidth = 3
body.stroke()

let charcoal = color(0.180, 0.180, 0.204)
let charcoalDark = color(0.129, 0.129, 0.149)

func circle(cx: CGFloat, cy: CGFloat, r: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)).fill()
}

// Clickpad + select.
circle(cx: 512, cy: 628, r: 234, fill: charcoal)
circle(cx: 512, cy: 628, r: 110, fill: charcoalDark)

// Direction dots.
NSColor.white.withAlphaComponent(0.45).setFill()
for (dx, dy) in [(0.0, 172.0), (0.0, -172.0), (172.0, 0.0), (-172.0, 0.0)] {
    NSBezierPath(ovalIn: NSRect(x: 512 + dx - 13, y: 628 + dy - 13, width: 26, height: 26)).fill()
}

// Two buttons below the pad.
circle(cx: 400, cy: 288, r: 80, fill: charcoal)
circle(cx: 624, cy: 288, r: 80, fill: charcoal)

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
