#!/usr/bin/env swift
// Generates App/AppIcon.iconset (run `iconutil -c icns` on it afterwards).
// The mark: a freehand stroke morphing into a clean connector + block — the
// sketch-to-structure identity — on a Studio Graphite squircle.
import AppKit

func hex(_ value: String, alpha: CGFloat = 1) -> NSColor {
    var v = UInt64(); Scanner(string: String(value.dropFirst())).scanHexInt64(&v)
    return NSColor(
        srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
        green: CGFloat((v >> 8) & 0xFF) / 255,
        blue: CGFloat(v & 0xFF) / 255, alpha: alpha
    )
}

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }
    let s = size / 1024.0 // design in 1024-space

    // Big Sur-style squircle with standard margins.
    let margin = 100 * s
    let square = NSRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let squircle = NSBezierPath(roundedRect: square, xRadius: 185 * s, yRadius: 185 * s)

    // Graphite ground with a faint indigo bloom low in the tile.
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [hex("#232733"), hex("#151820")])!
        .draw(in: square, angle: -90)
    let bloom = NSGradient(colors: [hex("#3B5BDB", alpha: 0.32), hex("#3B5BDB", alpha: 0)])!
    bloom.draw(fromCenter: NSPoint(x: size * 0.62, y: size * 0.34), radius: 0,
               toCenter: NSPoint(x: size * 0.62, y: size * 0.34), radius: 520 * s, options: [])
    NSGraphicsContext.current?.restoreGraphicsState()

    // 1. The freehand sketch: a wobbly stroke wandering in from the left.
    let sketch = NSBezierPath()
    sketch.lineWidth = 30 * s
    sketch.lineCapStyle = .round
    sketch.lineJoinStyle = .round
    sketch.move(to: NSPoint(x: 200 * s, y: 655 * s))
    sketch.curve(to: NSPoint(x: 330 * s, y: 555 * s),
                 controlPoint1: NSPoint(x: 265 * s, y: 700 * s),
                 controlPoint2: NSPoint(x: 275 * s, y: 520 * s))
    sketch.curve(to: NSPoint(x: 445 * s, y: 512 * s),
                 controlPoint1: NSPoint(x: 385 * s, y: 590 * s),
                 controlPoint2: NSPoint(x: 405 * s, y: 512 * s))
    hex("#9AA0AD", alpha: 0.85).setStroke()
    sketch.stroke()

    // 2. …snapping into a clean connector…
    let wire = NSBezierPath()
    wire.lineWidth = 30 * s
    wire.lineCapStyle = .round
    wire.move(to: NSPoint(x: 445 * s, y: 512 * s))
    wire.line(to: NSPoint(x: 620 * s, y: 512 * s))
    hex("#7D97FF").setStroke()
    wire.stroke()

    // Arrowhead into the block.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 596 * s, y: 568 * s))
    arrow.line(to: NSPoint(x: 668 * s, y: 512 * s))
    arrow.line(to: NSPoint(x: 596 * s, y: 456 * s))
    arrow.close()
    hex("#7D97FF").setFill()
    arrow.fill()

    // 3. …into a clean block.
    let block = NSRect(x: 668 * s, y: 408 * s, width: 236 * s, height: 208 * s)
    let blockPath = NSBezierPath(roundedRect: block, xRadius: 36 * s, yRadius: 36 * s)
    hex("#26305A").setFill()
    blockPath.fill()
    blockPath.lineWidth = 16 * s
    hex("#7D97FF").setStroke()
    blockPath.stroke()

    // Kind dot on the block (teal, like the canvas).
    let dot = NSRect(x: 700 * s, y: 552 * s, width: 34 * s, height: 34 * s)
    hex("#38D9A9").setFill()
    NSBezierPath(ovalIn: dot).fill()

    // 4. The travelling packet (flows) riding the connector.
    let packet = NSRect(x: 505 * s, y: 477 * s, width: 70 * s, height: 70 * s)
    hex("#38D9A9").setFill()
    NSBezierPath(ovalIn: packet).fill()
    let core = NSRect(x: 526 * s, y: 498 * s, width: 28 * s, height: 28 * s)
    NSColor.white.withAlphaComponent(0.92).setFill()
    NSBezierPath(ovalIn: core).fill()

    return image
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "App/AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    try png(drawIcon(size: CGFloat(pixels)), pixels: pixels)
        .write(to: out.appendingPathComponent("\(name).png"))
}
print("iconset written to \(out.path)")
