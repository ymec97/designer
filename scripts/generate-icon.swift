#!/usr/bin/env swift
// Generates App/AppIcon.iconset (run `iconutil -c icns` on it afterwards).
// The mark: a miniature system diagram — a gateway block fanning out to a
// service and a data store — on a Studio Graphite squircle.
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

    // Graphite ground, slightly lifted at the top.
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [hex("#252A38"), hex("#14171E")])!
        .draw(in: square, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    let indigo = hex("#7D97FF")
    let lineWidth = 26 * s

    // Layout (1024-space, y-up): gateway top-center, service bottom-left,
    // data store (ellipse) bottom-right.
    let gateway = NSRect(x: 392 * s, y: 610 * s, width: 240 * s, height: 160 * s)
    let service = NSRect(x: 196 * s, y: 254 * s, width: 240 * s, height: 160 * s)
    let store   = NSRect(x: 592 * s, y: 250 * s, width: 244 * s, height: 168 * s)

    // Connectors first (under the blocks): gateway → each child. The left
    // one is a recorded flow — teal, carrying a small packet (F5's identity).
    let teal = hex("#38D9A9")
    func connector(from: NSPoint, to: NSPoint, color: NSColor) {
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.move(to: from)
        path.line(to: to)
        color.setStroke()
        path.stroke()
    }
    connector(from: NSPoint(x: 468 * s, y: 640 * s), to: NSPoint(x: 344 * s, y: 396 * s),
              color: teal.withAlphaComponent(0.95))
    connector(from: NSPoint(x: 556 * s, y: 640 * s), to: NSPoint(x: 690 * s, y: 400 * s),
              color: indigo.withAlphaComponent(0.9))

    // The travelling packet, small and clearly riding the flow connector.
    let packetCenter = NSPoint(x: 406 * s, y: 518 * s)
    let packetR = 30 * s
    teal.setFill()
    NSBezierPath(ovalIn: NSRect(x: packetCenter.x - packetR, y: packetCenter.y - packetR,
                                width: packetR * 2, height: packetR * 2)).fill()
    NSColor.white.withAlphaComponent(0.92).setFill()
    let coreR = 12 * s
    NSBezierPath(ovalIn: NSRect(x: packetCenter.x - coreR, y: packetCenter.y - coreR,
                                width: coreR * 2, height: coreR * 2)).fill()

    // Blocks: filled panels with indigo outlines.
    func block(_ rect: NSRect, radius: CGFloat, fill: NSColor, ellipse: Bool = false) {
        let path = ellipse
            ? NSBezierPath(ovalIn: rect)
            : NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        path.lineWidth = 18 * s
        indigo.setStroke()
        path.stroke()
    }
    block(gateway, radius: 34 * s, fill: hex("#2C3560"))
    block(service, radius: 34 * s, fill: hex("#222839"))
    block(store, radius: 0, fill: hex("#222839"), ellipse: true)

    // Kind dots (teal on the gateway, muted on the children).
    func dot(_ center: NSPoint, _ color: NSColor) {
        let r = 20 * s
        let rect = NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
    dot(NSPoint(x: gateway.minX + 46 * s, y: gateway.maxY - 46 * s), hex("#38D9A9"))
    dot(NSPoint(x: service.minX + 46 * s, y: service.maxY - 46 * s), hex("#9AA0AD", alpha: 0.8))
    dot(NSPoint(x: store.midX, y: store.maxY - 40 * s), hex("#9AA0AD", alpha: 0.8))

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
