import AppKit
import DesignerModel

/// Draws board content into a CGContext. Stateless apart from a text-layout
/// cache; the view decides *what* is visible (culling) and *where* (viewport).
final class BoardRenderer {
    /// Below this scale, text is unreadable anyway — skip it entirely. This
    /// is both an LOD optimization and better visual noise behavior.
    static let textVisibilityScale: Double = 0.35

    /// Must match `CanvasView.dimmedAlpha` — the focus-mode dim strength. Used
    /// to fold dimming into image draws that don't inherit the context alpha.
    static let dimmedFraction: CGFloat = 0.22
    /// Legibility floor for a dimmed node's label: the rest of the element
    /// recedes at `dimmedFraction`, but the text stays readable.
    static let dimmedLabelFloor: CGFloat = 0.6

    private struct TextCacheKey: Hashable {
        let text: String
        let fontSize: CGFloat
        let colorSeed: Int
    }

    private var textCache: [TextCacheKey: NSAttributedString] = [:]
    /// Dynamic NSColor → CGColor resolution is too slow to do 2,000×/frame;
    /// resolved values are stable until the appearance changes.
    private var fillCache: [String: CGColor] = [:]

    /// Call when the effective appearance changes: cached CGColors and
    /// attributed strings were resolved under the old appearance.
    func invalidateCaches() {
        textCache.removeAll()
        fillCache.removeAll()
    }

    func resolvedNodeFill(for kind: NodeKind) -> CGColor {
        if let cached = fillCache[kind.rawValue] { return cached }
        let resolved = Palette.nodeFill(for: kind).cgColor
        fillCache[kind.rawValue] = resolved
        return resolved
    }

    // MARK: Elements

    /// Whether nodes get a soft drop shadow this pass. Elevation is set false
    /// when many nodes are visible (CoreGraphics shadows are per-node and
    /// costly) — imperceptible on a dense board, and it keeps the frame budget.
    var elevateNodes = true

    /// P3 — hand-drawn style: outlines wobble (two overlaid jittered passes),
    /// text goes handwritten. Mirrors `board.isSketchy`; set by the canvas
    /// and snapshotters. Invalidate text caches when it flips.
    var sketchy = false {
        didSet { if sketchy != oldValue { textCache.removeAll() } }
    }

    /// Board-wide connector caption visibility. `.onFocus` draws a caption
    /// only for edges the view marks `emphasized` (selected / hovered / flow).
    /// Mirrors `board.captionMode`; set by the canvas each pass.
    var captionMode: Board.CaptionMode = .always

    /// Whether an edge's caption should paint this pass, given the mode and
    /// whether the view considers the edge focused.
    private func shouldDrawCaption(emphasized: Bool) -> Bool {
        switch captionMode {
        case .always: return true
        case .onFocus: return emphasized
        case .off: return false
        }
    }

    /// Collision registry for connector captions — call once before each
    /// full edge pass so labels placed earlier repel the ones after.
    private var captionPlacer = EdgeGeometry.CaptionPlacer()
    /// Resolved world centers per edge, kept between frames so captions stay
    /// pinned (and just scale) during a zoom instead of re-solving — and
    /// jittering — every frame (B2). Re-solved only on a settled viewport.
    private(set) var captionCenters: [ElementID: Point] = [:]
    private var captionsResolve = true
    /// `resolve == true` runs the collision-avoiding placement this pass and
    /// updates `captionCenters`; `false` reuses the cached centers (used while
    /// a zoom/animation is in flight).
    func beginCaptionPass(resolve: Bool = true) {
        captionsResolve = resolve
        if resolve { captionPlacer = EdgeGeometry.CaptionPlacer() }
    }

    /// World-space caption pill size measured at scale 1 — stable across zoom,
    /// so a placement solve doesn't shift as the font rounds at different zooms
    /// (rendering still measures at the live zoom). B2.
    private func worldCaptionPillSize(for edge: Edge) -> Size? {
        guard let content = captionContent(for: edge, viewport: CanvasViewport(scale: 1)) else { return nil }
        return Size(width: Double(content.pillSize.width), height: Double(content.pillSize.height))
    }

    /// Strokes a jittered two-pass version of `viewPoints` (already in view
    /// space; `closed` re-joins the shape). Stroke state must be set by the
    /// caller — this only replaces the geometry.
    private func strokeSketchy(
        _ viewPoints: [CGPoint], closed: Bool, seed: UInt64,
        viewport: CanvasViewport, in context: CGContext
    ) {
        let worldish = viewPoints.map { Point(x: Double($0.x), y: Double($0.y)) }
        // World-attached wobble: constant in world units, scales with zoom.
        let roughness = 1.7 * viewport.scale
        let step = 30 * viewport.scale
        for pass in 0..<2 {
            let jittered = closed
                ? Sketch.roughPolygon(worldish, seed: seed, roughness: roughness, step: step, pass: pass)
                : Sketch.roughPolyline(worldish, seed: seed, roughness: roughness, step: step, pass: pass)
            guard jittered.count >= 2 else { continue }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: jittered[0].x, y: jittered[0].y))
            for point in jittered.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            if closed { path.closeSubpath() }
            context.addPath(path)
            context.strokePath()
        }
    }

    /// Deterministic per-shape wobble seed. Size-based (not position-based)
    /// so dragging a node doesn't make its outline shimmer.
    private func sketchSeed(width: Double, height: Double, salt: UInt64) -> UInt64 {
        UInt64(bitPattern: Int64(width * 8)) &* 31
            &+ UInt64(bitPattern: Int64(height * 8)) &* 17
            &+ salt
    }

    /// Straight-segment corners of a simple polygon CGPath (diamond/triangle).
    private func polygonCorners(of path: CGPath) -> [CGPoint] {
        var corners: [CGPoint] = []
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint:
                corners.append(element.pointee.points[0])
            default:
                break
            }
        }
        return corners
    }

    func draw(
        _ element: Element,
        in context: CGContext,
        viewport: CanvasViewport,
        frameOverride: Rect? = nil,
        isSelected: Bool,
        suppressText: Bool = false,
        dimmed: Bool = false
    ) {
        switch element.content {
        case .node(let node):
            drawNode(
                node, frame: frameOverride ?? node.frame,
                in: context, viewport: viewport,
                isSelected: isSelected, suppressText: suppressText, dimmed: dimmed
            )
        case .note(let note):
            drawNote(
                note, frame: frameOverride ?? note.frame,
                in: context, viewport: viewport,
                isSelected: isSelected, suppressText: suppressText
            )
        case .ink(let ink):
            // Ink has no frame, so a live move arrives as a `frameOverride`
            // (the transient bounding box). Translate the stroke by the delta
            // from its current bounding-box origin so a dragged drawing visibly
            // follows the cursor at ALL zooms, not just far zoom (I4 / B13).
            var drawn = ink
            if let frameOverride, let first = ink.points.first {
                var minX = first.x, minY = first.y
                for point in ink.points { minX = min(minX, point.x); minY = min(minY, point.y) }
                let dx = frameOverride.x - minX, dy = frameOverride.y - minY
                if dx != 0 || dy != 0 {
                    drawn.points = ink.points.map {
                        StrokePoint(x: $0.x + dx, y: $0.y + dy, pressure: $0.pressure, time: $0.time)
                    }
                }
            }
            drawInk(drawn, in: context, viewport: viewport, isSelected: isSelected)
        case .boundary(let boundary):
            drawBoundary(
                boundary, frame: frameOverride ?? boundary.frame,
                in: context, viewport: viewport,
                isSelected: isSelected, suppressText: suppressText
            )
        case .edge:
            break // M2
        }
    }

    /// A subsystem/trust-zone container: dashed hairline rounded rect with a
    /// faint tint and a bold label top-left. Drawn behind nodes (z-order is
    /// the caller's job — boundaries get bottom sort keys).
    private func drawBoundary(
        _ boundary: Note, frame: Rect,
        in context: CGContext, viewport: CanvasViewport,
        isSelected: Bool, suppressText: Bool
    ) {
        let rect = viewport.toView(frame)
        let radius = min(14 * viewport.scale, rect.width / 4, rect.height / 4)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        context.saveGState()
        context.setFillColor(Graphite.accentSoft.withAlphaComponent(0.16).cgColor)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor((isSelected ? Graphite.accent : Graphite.hairlineStrong).cgColor)
        context.setLineWidth((isSelected ? 1.8 : 1.2) * viewport.scale)
        context.setLineDash(phase: 0, lengths: [7 * viewport.scale, 5 * viewport.scale])
        context.addPath(path)
        context.strokePath()
        context.restoreGState()

        if !suppressText, !boundary.text.isEmpty, viewport.scale >= Self.textVisibilityScale {
            let fontSize = max(9, 12 * viewport.scale)
            draw(
                attributedString(boundary.text, fontSize: fontSize, color: Graphite.inkDim),
                at: CGPoint(x: rect.minX + 12 * viewport.scale, y: rect.minY + 8 * viewport.scale),
                maxWidth: rect.width - 24 * viewport.scale,
                context: context
            )
        }
    }

    private func drawNode(
        _ node: Node, frame: Rect,
        in context: CGContext, viewport: CanvasViewport,
        isSelected: Bool, suppressText: Bool, dimmed: Bool = false
    ) {
        let rect = viewport.toView(frame)
        let path: CGPath
        switch node.shape {
        case .ellipse:
            path = CGPath(ellipseIn: rect, transform: nil)
        case .diamond:
            let diamond = CGMutablePath()
            diamond.move(to: CGPoint(x: rect.midX, y: rect.minY))
            diamond.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            diamond.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            diamond.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            diamond.closeSubpath()
            path = diamond
        case .triangle:
            // Apex vertex + the two base corners, per orientation.
            let apex: CGPoint
            let base: (CGPoint, CGPoint)
            switch node.orientation {
            case .down:
                apex = CGPoint(x: rect.midX, y: rect.maxY)
                base = (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY))
            case .left:
                apex = CGPoint(x: rect.minX, y: rect.midY)
                base = (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY))
            case .right:
                apex = CGPoint(x: rect.maxX, y: rect.midY)
                base = (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY))
            default: // up
                apex = CGPoint(x: rect.midX, y: rect.minY)
                base = (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY))
            }
            let triangle = CGMutablePath()
            triangle.move(to: apex)
            triangle.addLine(to: base.0)
            triangle.addLine(to: base.1)
            triangle.closeSubpath()
            path = triangle
        case .cylinder:
            path = Self.cylinderPath(in: rect)
        case .cloud:
            path = Self.cloudPath(in: rect)
        default:
            let cornerRadius = min(8 * viewport.scale, rect.width / 4, rect.height / 4)
            path = CGPath(
                roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                transform: nil
            )
        }

        // Whole-element opacity: fill, stroke, and label fade as ONE via a
        // transparency layer (bare setAlpha would double-composite where the
        // stroke overlaps the fill edge).
        let opacity = node.style.effectiveOpacity
        if opacity < 1 {
            context.saveGState()
            context.setAlpha(CGFloat(opacity))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }

        // Soft elevation (Studio Graphite): a quiet drop shadow lifts the node
        // off the graphite ground. Skipped on dense boards (elevateNodes) to
        // protect the frame budget. `fill: "none"` shapes (grouping outlines)
        // paint no background and cast no shadow.
        if node.style.hasFill {
            let fillColor: CGColor
            if let hex = node.style.fill, let parsed = NSColor(hexString: hex) {
                fillColor = parsed.cgColor
            } else {
                fillColor = resolvedNodeFill(for: node.semantic.kind)
            }
            if elevateNodes {
                context.saveGState()
                context.setShadow(
                    offset: CGSize(width: 0, height: 1.5),
                    blur: 5 * viewport.scale,
                    color: Graphite.shadowColor.cgColor
                )
                context.setFillColor(fillColor)
                context.addPath(path)
                context.fillPath()
                context.restoreGState()
            } else {
                context.setFillColor(fillColor)
                context.addPath(path)
                context.fillPath()
            }
            // Diagonal-stripe hatching over the solid fill. Clipped to the
            // shape path so it works for any geometry; at far zoom the stripes
            // simply become invisible (spacing scales with the viewport).
            if node.style.isStriped {
                context.saveGState()
                context.addPath(path)
                context.clip()
                context.setStrokeColor(color(hex: node.style.stroke, fallback: Palette.nodeStroke)
                    .copy(alpha: 0.45) ?? color(hex: node.style.stroke, fallback: Palette.nodeStroke))
                context.setLineWidth(1.2 * viewport.scale)
                let spacing = max(7 * viewport.scale, 3)
                let h = rect.height
                var x = rect.minX - h
                while x < rect.maxX {
                    context.move(to: CGPoint(x: x, y: rect.minY))
                    context.addLine(to: CGPoint(x: x + h, y: rect.maxY))
                    x += spacing
                }
                context.strokePath()
                context.restoreGState()
            }
        }

        context.setStrokeColor(color(hex: node.style.stroke, fallback: Palette.nodeStroke))
        context.setLineWidth(CGFloat(node.style.strokeWidth ?? 1.25) * viewport.scale)
        if node.style.isDashed, !sketchy {
            context.setLineDash(phase: 0, lengths: [6 * viewport.scale, 4 * viewport.scale])
        }
        if sketchy {
            // Hand-drawn outline: two wobbly passes instead of the clean path
            // (the fill stays clean underneath — tidy color, rough ink).
            context.setLineWidth(CGFloat(node.style.strokeWidth ?? 1.0) * viewport.scale)
            let corners: [CGPoint]
            switch node.shape {
            case .ellipse, .cloud:
                corners = Sketch.ellipsePolygon(
                    in: Rect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
                ).map { CGPoint(x: $0.x, y: $0.y) }
            case .diamond, .triangle:
                corners = polygonCorners(of: path)
            default:
                corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            }
            strokeSketchy(
                corners, closed: true,
                seed: sketchSeed(width: frame.width, height: frame.height, salt: UInt64(node.shape.rawValue.count)),
                viewport: viewport, in: context
            )
        } else {
            context.addPath(path)
            context.strokePath()
            context.setLineDash(phase: 0, lengths: []) // clear before rim / next element
            // The cylinder's lid rim is stroke-only decoration — putting it
            // in the fill path punched a winding hole over the label.
            if node.shape == .cylinder {
                context.addPath(Self.cylinderRimPath(in: rect))
                context.strokePath()
            }
        }

        // Embedded image (imported diagrams): aspect-fit inside the frame,
        // leaving a strip at the bottom for the name when there is one.
        var textRect = rect
        if let dataURI = node.style.image, let image = Self.decodedImage(dataURI) {
            let labelStrip: CGFloat = node.semantic.name.isEmpty ? 0 : min(20 * viewport.scale, rect.height * 0.3)
            let box = CGRect(x: rect.minX, y: rect.minY,
                             width: rect.width, height: rect.height - labelStrip)
                .insetBy(dx: 4 * viewport.scale, dy: 4 * viewport.scale)
            if box.width > 2, box.height > 2 {
                let scale = min(box.width / image.size.width, box.height / image.size.height)
                let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let drawRect = CGRect(
                    x: box.midX - drawSize.width / 2, y: box.midY - drawSize.height / 2,
                    width: drawSize.width, height: drawSize.height
                )
                // `NSImage.draw` paints through a FRESH NSGraphicsContext, which
                // does NOT inherit the CGContext's focus-dim `setAlpha` — so an
                // SVG/raster node would stay full-strength while everything else
                // dims. Fold the dim into the draw `fraction` explicitly.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                image.draw(in: drawRect, from: .zero, operation: .sourceOver,
                           fraction: dimmed ? Self.dimmedFraction : 1,
                           respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
                NSGraphicsContext.restoreGraphicsState()
                textRect = CGRect(x: rect.minX, y: rect.maxY - max(labelStrip, 1),
                                  width: rect.width, height: max(labelStrip, 1))
            }
        }

        if !suppressText, viewport.scale >= Self.textVisibilityScale, !node.semantic.name.isEmpty {
            // A cylinder's label lives in the drum, below the lid rim.
            if node.shape == .cylinder, textRect == rect {
                let lid = Self.cylinderLid(for: rect) * 1.6
                textRect = CGRect(x: rect.minX, y: rect.minY + lid,
                                  width: rect.width, height: rect.height - lid)
            }
            // Focus dimming is a blanket 22% alpha over the whole element, so a
            // filled node's background collapses toward the canvas ground. The
            // on-fill contrast colour (dark ink on a light-ish fill) then goes
            // dark-on-dark and the label vanishes — the reported bug on the
            // rightmost `#8B95A5` swatch. When dimmed, colour the label against
            // the GROUND instead and give it a legibility floor so it stays
            // readable while the rest of the node recedes.
            let labelColor = dimmed
                ? Palette.nodeText
                : (node.style.hasFill ? Self.textColor(onFill: node.style.fill) : Palette.nodeText)
            if dimmed {
                context.saveGState()
                context.setAlpha(Self.dimmedLabelFloor)
            }
            drawText(
                node.semantic.name,
                fontSize: clampedLabelFontSize(
                    base: 13, multiplier: node.style.effectiveTextMultiplier,
                    text: node.semantic.name, frameView: textRect, viewport: viewport),
                color: labelColor,
                centeredIn: textRect,
                context: context
            )
            if dimmed { context.restoreGState() }
        }

        if opacity < 1 {
            context.endTransparencyLayer()
            context.restoreGState()
        }

        // Selection stays crisp OUTSIDE the opacity fade — a ghosted
        // selection ring would look broken.
        if isSelected {
            strokeSelection(path: path, in: context, viewport: viewport)
        }
    }

    // MARK: - Imported-diagram support (shapes, images, contrast)

    /// Database drum BODY: elliptical lid, straight walls, elliptical foot.
    /// Fill-safe — the visible front rim lives in `cylinderRimPath` and is
    /// only ever stroked (inside the fill path its winding cut a hole that
    /// blacked out the top of the label).
    static func cylinderPath(in rect: CGRect) -> CGPath {
        let lid = Self.cylinderLid(for: rect)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + lid))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + lid),
                          control: CGPoint(x: rect.midX, y: rect.minY - lid * 0.6))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - lid))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - lid),
                          control: CGPoint(x: rect.midX, y: rect.maxY + lid * 0.6))
        path.closeSubpath()
        return path
    }

    /// The lid's visible front rim — stroke only, never fill.
    static func cylinderRimPath(in rect: CGRect) -> CGPath {
        let lid = Self.cylinderLid(for: rect)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + lid))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + lid),
                          control: CGPoint(x: rect.midX, y: rect.minY + lid * 2.2))
        return path
    }

    private static func cylinderLid(for rect: CGRect) -> CGFloat {
        min(rect.height * 0.16, rect.width * 0.4)
    }

    /// Cloud blob: four overlapping arcs over a flat-ish base.
    static func cloudPath(in rect: CGRect) -> CGPath {
        let w = rect.width, h = rect.height
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + w * 0.18, y: rect.minY + h * 0.82))
        path.addCurve(to: CGPoint(x: rect.minX + w * 0.10, y: rect.minY + h * 0.44),
                      control1: CGPoint(x: rect.minX - w * 0.06, y: rect.minY + h * 0.78),
                      control2: CGPoint(x: rect.minX - w * 0.04, y: rect.minY + h * 0.48))
        path.addCurve(to: CGPoint(x: rect.minX + w * 0.38, y: rect.minY + h * 0.20),
                      control1: CGPoint(x: rect.minX + w * 0.14, y: rect.minY + h * 0.14),
                      control2: CGPoint(x: rect.minX + w * 0.28, y: rect.minY + h * 0.10))
        path.addCurve(to: CGPoint(x: rect.minX + w * 0.70, y: rect.minY + h * 0.22),
                      control1: CGPoint(x: rect.minX + w * 0.48, y: rect.minY + h * 0.02),
                      control2: CGPoint(x: rect.minX + w * 0.64, y: rect.minY + h * 0.04))
        path.addCurve(to: CGPoint(x: rect.minX + w * 0.90, y: rect.minY + h * 0.50),
                      control1: CGPoint(x: rect.minX + w * 0.84, y: rect.minY + h * 0.14),
                      control2: CGPoint(x: rect.minX + w * 1.00, y: rect.minY + h * 0.30))
        path.addCurve(to: CGPoint(x: rect.minX + w * 0.82, y: rect.minY + h * 0.82),
                      control1: CGPoint(x: rect.minX + w * 1.06, y: rect.minY + h * 0.56),
                      control2: CGPoint(x: rect.minX + w * 1.02, y: rect.minY + h * 0.80))
        path.addCurve(to: CGPoint(x: rect.minX + w * 0.18, y: rect.minY + h * 0.82),
                      control1: CGPoint(x: rect.minX + w * 0.66, y: rect.minY + h * 0.96),
                      control2: CGPoint(x: rect.minX + w * 0.32, y: rect.minY + h * 0.96))
        path.closeSubpath()
        return path
    }

    /// Custom fills come from imports and can be any brightness — pick ink
    /// that stays readable instead of the theme text color.
    static func textColor(onFill hex: String?) -> NSColor {
        guard let hex, let fill = NSColor(hexString: hex),
              let rgb = fill.usingColorSpace(.sRGB) else { return Palette.nodeText }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.55
            ? NSColor(calibratedWhite: 0.13, alpha: 1)
            : NSColor(calibratedWhite: 0.96, alpha: 1)
    }

    /// data: URI → NSImage, cached (boards redraw every frame; decoding SVG
    /// or PNG each time would wreck the budget).
    private static let imageCache = NSCache<NSString, NSImage>()
    static func decodedImage(_ dataURI: String) -> NSImage? {
        let key = dataURI as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let comma = dataURI.firstIndex(of: ",") else { return nil }
        let header = dataURI[..<comma]
        let payload = String(dataURI[dataURI.index(after: comma)...])
        let data: Data?
        if header.contains("base64") {
            data = Data(base64Encoded: payload)
        } else {
            data = payload.removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let data, let image = NSImage(data: data), image.size.width > 0 else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }


    private func drawNote(
        _ note: Note, frame: Rect,
        in context: CGContext, viewport: CanvasViewport,
        isSelected: Bool, suppressText: Bool
    ) {
        let rect = viewport.toView(frame)
        // A text box shows NO outline/box — not even a selection ring (I3); the
        // resize handles (drawn separately when selected) are the only chrome,
        // so it reads as pure text you click into and type.
        if !suppressText, viewport.scale >= Self.textVisibilityScale, !note.text.isEmpty {
            drawText(
                note.text,
                // The font tracks the box HEIGHT, so drag-resizing a text box
                // scales the text itself (I2); S/M/L/XL still nudges via the
                // multiplier, and clampedLabelFontSize shrinks to fit the width.
                fontSize: clampedLabelFontSize(
                    base: CGFloat(max(frame.height * 0.55, 6)), multiplier: note.style.effectiveTextMultiplier,
                    text: note.text, frameView: rect, viewport: viewport),
                color: Palette.noteText,
                in: rect,
                context: context
            )
        }
    }

    func drawInk(
        _ ink: Ink, in context: CGContext, viewport: CanvasViewport, isSelected: Bool
    ) {
        guard ink.points.count > 1 else { return }
        let baseWidth = CGFloat(ink.style.strokeWidth ?? 2) * viewport.scale
        let strokeColor = color(hex: ink.style.stroke, fallback: Palette.inkStroke)
        context.setStrokeColor(strokeColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Stroke opacity via a transparency layer — the per-segment strokes
        // overlap at joints and would double-darken under bare setAlpha.
        let opacity = ink.style.effectiveOpacity
        if opacity < 1 {
            context.saveGState()
            context.setAlpha(CGFloat(opacity))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }

        // Pressure-varying width: stroke per segment, width interpolated from
        // the endpoint pressures (0.5 = neutral for non-pressure devices).
        // Ink counts are small; per-segment stroking is fine.
        var previous = ink.points[0]
        for point in ink.points.dropFirst() {
            let pressure = (previous.pressure + point.pressure) / 2
            context.setLineWidth(baseWidth * CGFloat(0.5 + pressure))
            context.beginPath()
            context.move(to: viewport.toView(Point(x: previous.x, y: previous.y)))
            context.addLine(to: viewport.toView(Point(x: point.x, y: point.y)))
            context.strokePath()
            previous = point
        }
        if opacity < 1 {
            context.endTransparencyLayer()
            context.restoreGState()
        }

        if isSelected, let bounds = SpatialIndex.boundingRect(of: Element(
            layerIDs: [], sortKey: "i", content: .ink(ink)
        )) {
            let rect = viewport.toView(bounds).insetBy(dx: -4, dy: -4)
            strokeSelection(path: CGPath(rect: rect, transform: nil), in: context, viewport: viewport)
        }
    }

    // MARK: Edges

    func drawEdge(
        _ edge: Edge,
        route: EdgeGeometry.Route,
        in context: CGContext,
        viewport: CanvasViewport,
        isSelected: Bool,
        isDangling: Bool = false,
        simplified: Bool = false,
        emphasized: Bool = true,
        captionFraction: Double = 0.5,
        captionObstacles: ((Rect) -> [Rect])? = nil,
        edgeID: ElementID? = nil
    ) {
        // Connector opacity: fade the whole edge (line, arrowheads, caption)
        // as one; the body has early returns, so wrap it here. Selection
        // stays full-strength so a faded edge is still findable.
        let opacity = edge.style.effectiveOpacity
        if opacity < 1, !isSelected {
            context.saveGState()
            context.setAlpha(CGFloat(opacity))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawEdgeContent(edge, route: route, in: context, viewport: viewport,
                            isSelected: isSelected, isDangling: isDangling,
                            simplified: simplified, emphasized: emphasized,
                            captionFraction: captionFraction,
                            captionObstacles: captionObstacles, edgeID: edgeID)
            context.endTransparencyLayer()
            context.restoreGState()
        } else {
            drawEdgeContent(edge, route: route, in: context, viewport: viewport,
                            isSelected: isSelected, isDangling: isDangling,
                            simplified: simplified, emphasized: emphasized,
                            captionFraction: captionFraction,
                            captionObstacles: captionObstacles, edgeID: edgeID)
        }
    }

    private func drawEdgeContent(
        _ edge: Edge,
        route: EdgeGeometry.Route,
        in context: CGContext,
        viewport: CanvasViewport,
        isSelected: Bool,
        isDangling: Bool,
        simplified: Bool,
        emphasized: Bool,
        captionFraction: Double,
        captionObstacles: ((Rect) -> [Rect])?,
        edgeID: ElementID?
    ) {
        let viewPoints = route.points.map { viewport.toView($0) }
        guard viewPoints.count >= 2 else { return }

        let strokeColor = isDangling
            ? Palette.danglingEdge.cgColor
            : color(hex: edge.style.stroke, fallback: Palette.edgeStroke)
        let lineWidth = max(CGFloat(edge.style.strokeWidth ?? 1.5) * viewport.scale, simplified ? 0.5 : 1)

        if isSelected {
            context.setStrokeColor(Palette.selection.withAlphaComponent(0.35).cgColor)
            context.setLineWidth(lineWidth + 4)
            strokePolyline(viewPoints, in: context)
        }

        context.setStrokeColor(isSelected ? Palette.selection.cgColor : strokeColor)
        context.setLineWidth(lineWidth)
        if isDangling {
            context.setLineDash(phase: 0, lengths: [max(5 * viewport.scale, 3), max(4 * viewport.scale, 2.5)])
        }
        if sketchy, !simplified, !isDangling {
            context.setLineWidth(max(lineWidth * 0.75, 0.8))
            strokeSketchy(
                viewPoints, closed: false,
                seed: sketchSeed(
                    width: route.points[0].x + route.points[route.points.count - 1].x,
                    height: route.points[0].y + route.points[route.points.count - 1].y,
                    salt: UInt64(route.points.count)),
                viewport: viewport, in: context
            )
        } else {
            strokePolyline(viewPoints, in: context)
        }
        if isDangling {
            context.setLineDash(phase: 0, lengths: [])
            // Open circle at each unattached endpoint: "plug me back in".
            let radius = max(3.5 * viewport.scale, 2.5)
            context.setFillColor(Palette.canvasBackground.cgColor)
            context.setLineWidth(max(1.5 * viewport.scale, 1))
            for (anchor, point) in [(edge.from, viewPoints[0]), (edge.to, viewPoints[viewPoints.count - 1])] {
                if case .free = anchor {
                    let circle = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                    context.fillEllipse(in: circle)
                    context.strokeEllipse(in: circle)
                }
            }
        }

        guard !simplified else { return }

        // Arrowheads by direction.
        let arrowColor = isSelected ? Palette.selection.cgColor : strokeColor
        let direction = edge.semantic.direction
        if direction == .forward || direction == .both {
            drawArrowhead(
                at: viewPoints[viewPoints.count - 1], from: viewPoints[viewPoints.count - 2],
                color: arrowColor, scale: viewport.scale, in: context
            )
        }
        if direction == .backward || direction == .both {
            drawArrowhead(
                at: viewPoints[0], from: viewPoints[1],
                color: arrowColor, scale: viewport.scale, in: context
            )
        }

        // Label pill + well-known-key badges along the route. Placement is
        // collision-aware: pills dodge blocks AND each other, sliding along
        // the route and nudging perpendicular on dense boards. The caption
        // mode can suppress it (Off) or restrict it to focused edges (On Focus).
        if viewport.scale >= Self.textVisibilityScale, shouldDrawCaption(emphasized: emphasized) {
            var center = route.point(atFraction: captionFraction)
            if let edgeID {
                // Settled: solve collision-avoided placement (scale-independent
                // pill size) and cache it. In flight: reuse the cached world
                // center so the caption just scales instead of jittering (B2).
                if captionsResolve, let obstacles = captionObstacles, let pillWorld = worldCaptionPillSize(for: edge) {
                    center = captionPlacer.place(
                        preferred: captionFraction, route: route,
                        pillSize: pillWorld, obstacles: obstacles)
                    captionCenters[edgeID] = center
                } else if let cached = captionCenters[edgeID] {
                    center = cached
                }
            } else if let captionObstacles, let pillView = captionPillSize(for: edge, viewport: viewport) {
                center = captionPlacer.place(
                    preferred: captionFraction,
                    route: route,
                    pillSize: Size(width: Double(pillView.width) / viewport.scale,
                                   height: Double(pillView.height) / viewport.scale),
                    obstacles: captionObstacles
                )
            }
            // Selected connectors expand to show every field; unselected ones
            // (including hovered / flow-focused in On-Focus mode) show only the
            // label.
            drawEdgeCaption(edge, at: viewport.toView(center), viewport: viewport, in: context,
                            showAllFields: isSelected)
        }
    }

    /// Draws a connector's full caption (all fields) with a colored ring,
    /// regardless of the board caption mode — used by the flow overlay so an
    /// active connector reveals everything while a packet crosses it (F5/B).
    /// Returns the world caption center so the caller can place it consistently.
    func drawActiveEdgeCaption(
        _ edge: Edge, route: EdgeGeometry.Route, edgeID: ElementID,
        color: NSColor, viewport: CanvasViewport, in context: CGContext
    ) {
        guard viewport.scale >= Self.textVisibilityScale else { return }
        let center = captionCenters[edgeID] ?? route.point(atFraction: 0.5)
        drawEdgeCaption(edge, at: viewport.toView(center), viewport: viewport, in: context,
                        showAllFields: true, spotlightColor: color)
    }

    /// The caption pill's rendered size, or nil when the edge has no caption.
    private func captionPillSize(for edge: Edge, viewport: CanvasViewport) -> CGSize? {
        guard let content = captionContent(for: edge, viewport: viewport) else { return nil }
        return content.pillSize
    }

    /// Builds a connector's caption. By default only the label paints; the
    /// property badges (protocol/data/condition) appear only when `showAllFields`
    /// (the edge is selected, or a packet is flowing through it). The label is
    /// sized by the edge's own `textSize`; the badges scale proportionally.
    private func captionContent(
        for edge: Edge, viewport: CanvasViewport, showAllFields: Bool = false
    ) -> (lines: [NSAttributedString], sizes: [CGSize], pillSize: CGSize)? {
        let label = edge.semantic.label ?? ""
        let badgeKeys = [
            WellKnownEdgeProperty.protocolKey,
            WellKnownEdgeProperty.data,
            WellKnownEdgeProperty.condition,
        ]
        let badges = showAllFields ? badgeKeys.compactMap { key in
            edge.semantic.properties[key].map { "\(key): \($0)" }
        } : []
        guard !label.isEmpty || !badges.isEmpty else { return nil }
        func truncated(_ text: String, to limit: Int) -> String {
            text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
        }
        let mult = CGFloat(edge.style.effectiveTextMultiplier)

        var lines: [NSAttributedString] = []
        if !label.isEmpty {
            lines.append(attributedString(truncated(label, to: 42), fontSize: 12 * mult * viewport.scale, color: Palette.nodeText))
        }
        if !badges.isEmpty {
            lines.append(attributedString(
                truncated(badges.joined(separator: "  ·  "), to: 56),
                fontSize: 10 * mult * viewport.scale,
                color: Palette.noteText
            ))
        }
        let sizes = lines.map { $0.size() }
        let width = sizes.map(\.width).max() ?? 0
        let height = sizes.map(\.height).reduce(0, +)
        let padding = 5 * viewport.scale
        return (lines, sizes, CGSize(width: width + padding * 2, height: height + padding * 2))
    }

    private func strokePolyline(_ points: [CGPoint], in context: CGContext) {
        context.beginPath()
        context.move(to: points[0])
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
    }

    private func drawArrowhead(
        at tip: CGPoint, from previous: CGPoint,
        color: CGColor, scale: Double, in context: CGContext
    ) {
        let angle = atan2(tip.y - previous.y, tip.x - previous.x)
        let length = 9 * scale
        let spread = 0.46
        let left = CGPoint(
            x: tip.x - length * cos(angle - spread),
            y: tip.y - length * sin(angle - spread)
        )
        let right = CGPoint(
            x: tip.x - length * cos(angle + spread),
            y: tip.y - length * sin(angle + spread)
        )
        context.setFillColor(color)
        context.beginPath()
        context.move(to: tip)
        context.addLine(to: left)
        context.addLine(to: right)
        context.closePath()
        context.fillPath()
    }

    private func drawEdgeCaption(
        _ edge: Edge, at center: CGPoint, viewport: CanvasViewport, in context: CGContext,
        showAllFields: Bool = false, spotlightColor: NSColor? = nil
    ) {
        guard let content = captionContent(for: edge, viewport: viewport, showAllFields: showAllFields) else { return }
        let (lines, sizes, pillSize) = content
        let padding = 5 * viewport.scale
        let pill = CGRect(
            x: center.x - pillSize.width / 2,
            y: center.y - pillSize.height / 2,
            width: pillSize.width,
            height: pillSize.height
        )
        let path = CGPath(
            roundedRect: pill,
            cornerWidth: min(6 * viewport.scale, pill.height / 2),
            cornerHeight: min(6 * viewport.scale, pill.height / 2),
            transform: nil
        )
        context.setFillColor(Palette.captionBackground.cgColor)
        context.addPath(path)
        context.fillPath()
        // A packet flowing through paints a colored ring so the live caption
        // reads as "this connector is active right now".
        if let spotlightColor {
            context.setStrokeColor(spotlightColor.cgColor)
            context.setLineWidth(max(1.5 * viewport.scale, 1))
            context.addPath(path)
            context.strokePath()
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        var y = pill.minY + padding
        for (line, size) in zip(lines, sizes) {
            line.draw(at: CGPoint(x: center.x - size.width / 2, y: y))
            y += size.height
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Live preview while dragging a new connection.
    func drawConnectPreview(from: CGPoint, to: CGPoint, in context: CGContext) {
        context.setStrokeColor(Palette.selection.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [6, 4])
        strokePolyline([from, to], in: context)
        context.setLineDash(phase: 0, lengths: [])
        drawArrowhead(at: to, from: from, color: Palette.selection.cgColor, scale: 1, in: context)
    }

    func highlightConnectTarget(_ viewRect: CGRect, in context: CGContext) {
        context.setStrokeColor(Palette.selection.cgColor)
        context.setLineWidth(2.5)
        let path = CGPath(
            roundedRect: viewRect.insetBy(dx: -3, dy: -3),
            cornerWidth: 8, cornerHeight: 8, transform: nil
        )
        context.addPath(path)
        context.strokePath()
    }

    /// Fills pre-built world-space node paths (one per fill color) through
    /// the CTM — the far-zoom node pass is a handful of CG calls with zero
    /// per-node Swift work.
    func fillNodeBatch(
        _ paths: [(color: CGColor, path: CGPath)],
        in context: CGContext,
        viewport: CanvasViewport,
        alpha: CGFloat = 1
    ) {
        guard !paths.isEmpty else { return }
        context.saveGState()
        context.setAlpha(alpha)
        context.translateBy(
            x: -viewport.origin.x * viewport.scale,
            y: -viewport.origin.y * viewport.scale
        )
        context.scaleBy(x: viewport.scale, y: viewport.scale)
        for (color, path) in paths {
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath()
        }
        context.restoreGState()
    }

    /// Strokes a pre-built world-space path holding every edge in ONE call,
    /// mapped through the CTM instead of transforming 15k points on the CPU.
    /// Antialiasing off: at these scales edges are ~1px lines and AA is the
    /// dominant rasterization cost.
    func strokeEdgeBatch(
        _ worldPath: CGPath, in context: CGContext, viewport: CanvasViewport, alpha: CGFloat = 1
    ) {
        guard !worldPath.isEmpty else { return }
        context.saveGState()
        context.setAlpha(alpha)
        context.setShouldAntialias(false)
        context.translateBy(
            x: -viewport.origin.x * viewport.scale,
            y: -viewport.origin.y * viewport.scale
        )
        context.scaleBy(x: viewport.scale, y: viewport.scale)
        context.setStrokeColor(Palette.edgeStroke.cgColor)
        context.setLineWidth(max(1.5, 0.75 / viewport.scale)) // ≥0.75px on screen
        context.addPath(worldPath)
        context.strokePath()
        context.restoreGState()
    }

    /// Far-zoom rendering of an individual node outside the cached batch
    /// (in-flight drags, selection): a plain rect, visually consistent with
    /// the batched fill.
    func drawSimplifiedNode(
        _ node: Node, frame: Rect,
        in context: CGContext, viewport: CanvasViewport, isSelected: Bool
    ) {
        let rect = viewport.toView(frame)
        let fill: CGColor
        if let hex = node.style.fill, let parsed = NSColor(hexString: hex) {
            fill = parsed.cgColor
        } else {
            fill = resolvedNodeFill(for: node.semantic.kind)
        }
        context.setFillColor(fill)
        context.fill(rect)
        if isSelected {
            context.setStrokeColor(Palette.selection.cgColor)
            context.setLineWidth(1.5)
            context.stroke(rect)
        }
    }

    /// Centered affordance hint for an empty board — the whole onboarding a
    /// blank canvas needs (D17): what to do, in one line, gone once you do it.
    func drawEmptyHint(in context: CGContext, bounds: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        let title = NSAttributedString(string: "Start with a block", attributes: [
            .font: NSFont.systemFont(ofSize: 19, weight: .semibold),
            .foregroundColor: Graphite.inkDim,
        ])
        let hintStyle = NSMutableParagraphStyle()
        hintStyle.alignment = .center
        let hint = NSAttributedString(
            string: "Double-click to create   ·   D to draw   ·   scroll to pan   ·   ⌘K for commands",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: Palette.hintText,
                .paragraphStyle: hintStyle,
            ]
        )
        let titleSize = title.size()
        let hintSize = hint.size()
        let centerY = bounds.midY
        title.draw(at: CGPoint(x: bounds.midX - titleSize.width / 2, y: centerY - titleSize.height - 4))
        hint.draw(at: CGPoint(x: bounds.midX - hintSize.width / 2, y: centerY + 6))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A small floating caption pill in view space (transient gesture hints).
    func drawHintCaption(_ text: String, at point: CGPoint, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let caption = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: Graphite.ink,
        ])
        let size = caption.size()
        let pill = CGRect(
            x: point.x - size.width / 2 - 9, y: point.y - size.height - 22,
            width: size.width + 18, height: size.height + 10
        )
        let path = CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil)
        context.setFillColor(Graphite.panel.withAlphaComponent(0.95).cgColor)
        context.addPath(path); context.fillPath()
        context.setStrokeColor(Graphite.hairlineStrong.cgColor)
        context.setLineWidth(1)
        context.addPath(path); context.strokePath()
        caption.draw(at: CGPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Adornments

    private func strokeSelection(path: CGPath, in context: CGContext, viewport: CanvasViewport) {
        // A soft accent halo under a crisp accent outline — reads as "selected"
        // without the heavy 2px ring the system default would give.
        context.setStrokeColor(Palette.selection.withAlphaComponent(0.22).cgColor)
        context.setLineWidth(4)
        context.addPath(path)
        context.strokePath()
        context.setStrokeColor(Palette.selection.cgColor)
        context.setLineWidth(1.5)
        context.addPath(path)
        context.strokePath()
    }

    /// Candidate anchor dots shown on a node while a connector endpoint is
    /// dragged over it. The `selected` index (the slot the endpoint would snap
    /// to) gets a filled highlight; the rest are small open dots.
    func drawAnchorSlots(_ viewPoints: [CGPoint], selected: Int?, in context: CGContext) {
        context.setStrokeColor(Palette.selection.cgColor)
        context.setLineWidth(1.5)
        for (index, point) in viewPoints.enumerated() {
            let isSelected = index == selected
            let radius: CGFloat = isSelected ? 5 : 3.5
            let rect = CGRect(
                x: point.x - radius, y: point.y - radius,
                width: radius * 2, height: radius * 2)
            context.setFillColor(isSelected ? Palette.selection.cgColor : Graphite.panel.cgColor)
            context.fillEllipse(in: rect)
            context.strokeEllipse(in: rect)
        }
    }

    /// The grab dot on a selected connector (P5 bend affordance).
    func drawBendHandle(at point: CGPoint, in context: CGContext) {
        let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        context.setFillColor(Graphite.panel.cgColor)
        context.setStrokeColor(Palette.selection.cgColor)
        context.setLineWidth(1.5)
        context.fillEllipse(in: rect)
        context.strokeEllipse(in: rect)
    }

    func drawResizeHandles(around viewRect: CGRect, in context: CGContext) {
        context.setFillColor(Graphite.panel.cgColor)
        context.setStrokeColor(Palette.selection.cgColor)
        context.setLineWidth(1.5)
        for handle in ResizeHandle.allCases {
            let rect = handle.rect(around: viewRect)
            let path = CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil)
            context.addPath(path); context.fillPath()
            context.addPath(path); context.strokePath()
        }
    }

    // MARK: Traffic simulation

    /// A translucent scrim that quiets the board so the flowing path pops.
    func drawSimulationScrim(_ bounds: CGRect, in context: CGContext) {
        context.setFillColor(Graphite.canvas.withAlphaComponent(0.62).cgColor)
        context.fill(bounds)
    }

    /// A lit node: a colored glow halo, brighter when it has just been reached.
    func drawSimulationNodeGlow(
        _ path: CGPath, in context: CGContext, viewport: CanvasViewport, intensity: CGFloat,
        color: NSColor = Graphite.accent
    ) {
        context.saveGState()
        context.setShadow(
            offset: .zero, blur: 14 * viewport.scale,
            color: color.withAlphaComponent(0.55 * intensity).cgColor
        )
        context.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(2 * viewport.scale)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// An edge the flow has used: a bright colored overlay on its route.
    func drawSimulationEdge(
        _ viewPoints: [CGPoint], in context: CGContext, viewport: CanvasViewport, active: Bool,
        color: NSColor = Graphite.accent
    ) {
        guard viewPoints.count >= 2 else { return }
        context.setStrokeColor(color.withAlphaComponent(active ? 0.95 : 0.7).cgColor)
        context.setLineWidth((active ? 2.4 : 1.8) * viewport.scale)
        context.setLineCap(.round)
        strokePolyline(viewPoints, in: context)
    }

    /// The travelling packet — a glowing colored dot at the head of the flow.
    func drawSimulationPacket(
        at point: CGPoint, in context: CGContext, viewport: CanvasViewport,
        color: NSColor = Graphite.accent
    ) {
        let r = 5 * viewport.scale
        context.saveGState()
        context.setShadow(offset: .zero, blur: 8 * viewport.scale, color: color.cgColor)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
        context.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        let ri = r * 0.4
        context.fillEllipse(in: CGRect(x: point.x - ri, y: point.y - ri, width: ri * 2, height: ri * 2))
        context.restoreGState()
    }

    /// A proposed-addition marker: dashed outline around a ghost node.
    /// Accent by default (flow-recording candidate rings); the proposal
    /// overlay passes `Graphite.proposalAdd` so green consistently means
    /// "will be added".
    func drawProposalAddedOutline(
        _ rect: CGRect, in context: CGContext, viewport: CanvasViewport,
        color: NSColor = Graphite.accent
    ) {
        let r = min(8 * viewport.scale, rect.width / 4, rect.height / 4)
        let path = CGPath(roundedRect: rect.insetBy(dx: -3, dy: -3), cornerWidth: r, cornerHeight: r, transform: nil)
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.8 * viewport.scale)
        context.setLineDash(phase: 0, lengths: [5 * viewport.scale, 4 * viewport.scale])
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// A proposed-addition marker along a connector's route (green dashed).
    func drawProposalAddedRoute(_ viewPoints: [CGPoint], in context: CGContext, viewport: CanvasViewport) {
        guard viewPoints.count >= 2 else { return }
        context.saveGState()
        context.setStrokeColor(Graphite.proposalAdd.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(2.2 * viewport.scale)
        context.setLineCap(.round)
        context.setLineDash(phase: 0, lengths: [6 * viewport.scale, 5 * viewport.scale])
        strokePolyline(viewPoints, in: context)
        context.restoreGState()
    }

    /// A proposed-removal marker: dashed red outline on a current node.
    func drawProposalRemovedOutline(_ rect: CGRect, in context: CGContext, viewport: CanvasViewport) {
        let red = Graphite.proposalRemove
        let r = min(8 * viewport.scale, rect.width / 4, rect.height / 4)
        let path = CGPath(roundedRect: rect.insetBy(dx: -3, dy: -3), cornerWidth: r, cornerHeight: r, transform: nil)
        context.saveGState()
        context.setFillColor(red.withAlphaComponent(0.14).cgColor)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(red.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1.8 * viewport.scale)
        context.setLineDash(phase: 0, lengths: [5 * viewport.scale, 4 * viewport.scale])
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// The unmistakable "this gets deleted": a diagonal ✕ across the block.
    func drawProposalRemovedStrike(_ rect: CGRect, in context: CGContext, viewport: CanvasViewport) {
        let inset = rect.insetBy(dx: rect.width * 0.18, dy: rect.height * 0.18)
        context.saveGState()
        context.setStrokeColor(Graphite.proposalRemove.withAlphaComponent(0.75).cgColor)
        context.setLineWidth(2.2 * viewport.scale)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: inset.minX, y: inset.minY))
        context.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
        context.move(to: CGPoint(x: inset.maxX, y: inset.minY))
        context.addLine(to: CGPoint(x: inset.minX, y: inset.maxY))
        context.strokePath()
        context.restoreGState()
    }

    /// A proposed-removal marker along a connector's route.
    func drawProposalRemovedRoute(_ viewPoints: [CGPoint], in context: CGContext, viewport: CanvasViewport) {
        guard viewPoints.count >= 2 else { return }
        context.saveGState()
        context.setStrokeColor(Graphite.proposalRemove.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(2.2 * viewport.scale)
        context.setLineCap(.round)
        context.setLineDash(phase: 0, lengths: [5 * viewport.scale, 4 * viewport.scale])
        strokePolyline(viewPoints, in: context)
        context.restoreGState()
    }

    enum GhostBadgeKind {
        case added, removed, changed
    }

    /// A small +/−/~ chip at a ghosted block's corner — legible even where
    /// dashes and tints blend into a busy board.
    func drawGhostBadge(kind: GhostBadgeKind, at corner: CGPoint, in context: CGContext, viewport: CanvasViewport) {
        let radius = max(7 * viewport.scale, 5)
        let center = CGPoint(x: corner.x, y: corner.y)
        let color: NSColor
        switch kind {
        case .added: color = Graphite.proposalAdd
        case .removed: color = Graphite.proposalRemove
        case .changed: color = Graphite.proposalChange
        }
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: CGRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(max(1.6 * viewport.scale, 1.2))
        context.setLineCap(.round)
        let arm = radius * 0.48
        switch kind {
        case .added:
            context.move(to: CGPoint(x: center.x - arm, y: center.y))
            context.addLine(to: CGPoint(x: center.x + arm, y: center.y))
            context.move(to: CGPoint(x: center.x, y: center.y - arm))
            context.addLine(to: CGPoint(x: center.x, y: center.y + arm))
        case .removed:
            context.move(to: CGPoint(x: center.x - arm, y: center.y))
            context.addLine(to: CGPoint(x: center.x + arm, y: center.y))
        case .changed:
            // A small tilde-ish squiggle for "modified".
            context.move(to: CGPoint(x: center.x - arm, y: center.y + arm * 0.35))
            context.addCurve(
                to: CGPoint(x: center.x + arm, y: center.y - arm * 0.35),
                control1: CGPoint(x: center.x - arm * 0.2, y: center.y - arm * 0.8),
                control2: CGPoint(x: center.x + arm * 0.2, y: center.y + arm * 0.8))
        }
        context.strokePath()
        context.restoreGState()
    }

    /// Amber dashed ring marking an element modified in place (recolor,
    /// relabel, restyle) in a proposal review.
    func drawProposalChangedOutline(_ rect: CGRect, in context: CGContext, viewport: CanvasViewport) {
        context.saveGState()
        context.setStrokeColor(Graphite.proposalChange.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(max(1.8 * viewport.scale, 1.4))
        context.setLineDash(phase: 0, lengths: [5 * viewport.scale, 4 * viewport.scale])
        let inset = rect.insetBy(dx: -3, dy: -3)
        context.stroke(inset)
        context.restoreGState()
    }

    func drawProposalChangedRoute(_ viewPoints: [CGPoint], in context: CGContext, viewport: CanvasViewport) {
        guard viewPoints.count >= 2 else { return }
        context.saveGState()
        context.setStrokeColor(Graphite.proposalChange.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(2.2 * viewport.scale)
        context.setLineCap(.round)
        context.setLineDash(phase: 0, lengths: [6 * viewport.scale, 4 * viewport.scale])
        strokePolyline(viewPoints, in: context)
        context.restoreGState()
    }

    /// A linked node's drill-down badge: accent circle with an ↗ arrow at the
    /// node's top-right, OUTSIDE the frame (double-click to enter the board).
    func drawLinkBadge(in rect: CGRect, broken: Bool = false, context: CGContext) {
        context.saveGState()
        // Broken links (target board missing) wear an amber "!" instead of the
        // accent ↗, so it's obvious the drill-down won't work (F4).
        let amber = NSColor(hexString: "#E8943A") ?? Graphite.accent
        context.setFillColor((broken ? amber : Graphite.accent).cgColor)
        context.setShadow(offset: CGSize(width: 0, height: 1), blur: 2,
                          color: Graphite.shadowColor.cgColor)
        context.fillEllipse(in: rect)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        if broken {
            drawText("!", fontSize: rect.height * 0.72, color: .white,
                     centeredIn: rect, context: context)
            context.restoreGState()
            return
        }
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(max(rect.width * 0.11, 1.1))
        context.setLineCap(.round)
        // ↗ arrow: shaft + two head strokes.
        let inset = rect.width * 0.3
        let tail = CGPoint(x: rect.minX + inset, y: rect.maxY - inset)
        let tip = CGPoint(x: rect.maxX - inset, y: rect.minY + inset)
        context.move(to: tail)
        context.addLine(to: tip)
        context.move(to: CGPoint(x: tip.x - rect.width * 0.22, y: tip.y))
        context.addLine(to: tip)
        context.addLine(to: CGPoint(x: tip.x, y: tip.y + rect.height * 0.22))
        context.strokePath()
        context.restoreGState()
    }

    /// A recordable connector during flow recording: dashed colored highlight.
    func drawFlowCandidate(
        _ viewPoints: [CGPoint], in context: CGContext, viewport: CanvasViewport
    ) {
        guard viewPoints.count >= 2 else { return }
        context.saveGState()
        context.setStrokeColor(Graphite.accent.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(2.2 * viewport.scale)
        context.setLineCap(.round)
        context.setLineDash(phase: 0, lengths: [6 * viewport.scale, 5 * viewport.scale])
        strokePolyline(viewPoints, in: context)
        context.restoreGState()
    }

    /// A small tag surfaced during playback (an edge's `condition`, e.g.
    /// "only when gRPC"), drawn near the travelling packet.
    func drawSimulationTag(
        _ text: String, at point: CGPoint, in context: CGContext, viewport: CanvasViewport,
        color: NSColor
    ) {
        let font = NSFont.systemFont(ofSize: max(10, 11 * viewport.scale), weight: .medium)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: Graphite.ink,
        ])
        let size = attributed.size()
        let padding: CGFloat = 5
        let rect = CGRect(
            x: point.x + 10, y: point.y - size.height - 12,
            width: size.width + padding * 2, height: size.height + padding
        )
        let capsule = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
        context.saveGState()
        context.setFillColor(Graphite.panel.withAlphaComponent(0.95).cgColor)
        context.addPath(capsule)
        context.fillPath()
        context.setStrokeColor(color.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(1)
        context.addPath(capsule)
        context.strokePath()
        context.restoreGState()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        attributed.draw(at: CGPoint(x: rect.minX + padding, y: rect.minY + padding / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    func drawSnapGuide(_ guide: SnapEngine.Guide, in context: CGContext, viewport: CanvasViewport) {
        context.setStrokeColor(Palette.snapGuide.cgColor)
        context.setLineWidth(1)
        context.beginPath()
        switch guide.axis {
        case .vertical:
            let x = viewport.toView(Point(x: guide.position, y: guide.start)).x
            context.move(to: CGPoint(x: x, y: viewport.toView(Point(x: guide.position, y: guide.start)).y))
            context.addLine(to: CGPoint(x: x, y: viewport.toView(Point(x: guide.position, y: guide.end)).y))
        case .horizontal:
            let y = viewport.toView(Point(x: guide.start, y: guide.position)).y
            context.move(to: CGPoint(x: viewport.toView(Point(x: guide.start, y: guide.position)).x, y: y))
            context.addLine(to: CGPoint(x: viewport.toView(Point(x: guide.end, y: guide.position)).x, y: y))
        }
        context.strokePath()
    }

    func drawRubberBand(_ rect: CGRect, in context: CGContext) {
        context.setFillColor(Palette.selection.withAlphaComponent(0.08).cgColor)
        context.fill(rect)
        context.setStrokeColor(Palette.selection.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(rect)
        context.setLineDash(phase: 0, lengths: [])
    }

    // MARK: Text

    private func drawText(
        _ text: String, fontSize: CGFloat, color: NSColor,
        centeredIn rect: CGRect, context: CGContext
    ) {
        let attributed = attributedString(text, fontSize: fontSize, color: color)
        let size = attributed.size()
        let maxWidth = max(rect.width - 8, 10)

        // Names wider than the block wrap onto extra lines while the frame
        // has room (draw.io/Excalidraw imports keep their small frames);
        // only when even wrapping can't fit does truncation kick in.
        if size.width > maxWidth, rect.height > size.height * 2.2 {
            let wrapped = NSMutableAttributedString(attributedString: attributed)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            wrapped.addAttribute(
                .paragraphStyle, value: paragraph,
                range: NSRange(location: 0, length: wrapped.length)
            )
            let maxLines = min(3, Int((rect.height - 6) / max(size.height, 1)))
            let bounds = wrapped.boundingRect(
                with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin]
            )
            let height = min(bounds.height, CGFloat(maxLines) * size.height)
            if height > size.height, maxLines >= 2 {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                wrapped.draw(
                    with: CGRect(x: rect.minX + 4, y: rect.midY - height / 2,
                                 width: maxWidth, height: height),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                )
                NSGraphicsContext.restoreGraphicsState()
                return
            }
        }

        // Center the VISIBLE (possibly truncated) width — centering the full
        // text width made oversized names start left of their own block and
        // spill over neighbors.
        let visibleWidth = min(size.width, maxWidth)
        let origin = CGPoint(
            x: rect.midX - visibleWidth / 2,
            y: rect.midY - size.height / 2
        )
        draw(attributed, at: origin, maxWidth: maxWidth, context: context)
    }

    private func drawText(
        _ text: String, fontSize: CGFloat, color: NSColor,
        in rect: CGRect, context: CGContext
    ) {
        let attributed = attributedString(text, fontSize: fontSize, color: color)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        attributed.draw(in: rect.insetBy(dx: 4, dy: 4))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func draw(
        _ attributed: NSAttributedString, at origin: CGPoint,
        maxWidth: CGFloat, context: CGContext
    ) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let size = attributed.size()
        // A tight height equal to `size.height` clips glyph descenders (the
        // bottom of "Cloud") once zoom makes the scale fractional and the line
        // box rounds down. Give a couple of points of bottom headroom — the
        // text stays top-anchored at origin.y, so the baseline doesn't shift.
        let rect = CGRect(
            x: origin.x, y: origin.y,
            width: min(size.width, max(maxWidth, 10)).rounded(.up),
            height: size.height.rounded(.up) + 2
        )
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Font size for a label: base × the element's textSize multiplier × zoom,
    /// then clamped so a single measured line of `text` fits inside `frameView`
    /// (view space) — keeps XL text from spilling out of a small shape (F6).
    private func clampedLabelFontSize(
        base: CGFloat, multiplier: Double, text: String,
        frameView: CGRect, viewport: CanvasViewport
    ) -> CGFloat {
        let requested = base * CGFloat(multiplier) * CGFloat(viewport.scale)
        guard !text.isEmpty else { return requested }
        let measured = attributedString(text, fontSize: requested, color: .black).size()
        let maxW = max(frameView.width - 8 * viewport.scale, 1)
        let maxH = max(frameView.height - 8 * viewport.scale, 1)
        let widthRatio = measured.width > maxW ? maxW / measured.width : 1
        let heightRatio = measured.height > maxH ? maxH / measured.height : 1
        let ratio = min(widthRatio, heightRatio)
        // Never shrink below the readable floor the renderer already respects.
        return max(requested * ratio, min(requested, 9))
    }

    private func attributedString(
        _ text: String, fontSize: CGFloat, color: NSColor
    ) -> NSAttributedString {
        // Bucket font sizes so the cache survives continuous zooming.
        let bucketed = (fontSize * 2).rounded() / 2
        let key = TextCacheKey(text: text, fontSize: bucketed, colorSeed: color.hashValue)
        if let cached = textCache[key] { return cached }
        if textCache.count > 4096 { textCache.removeAll() }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSAttributedString(string: text, attributes: [
            .font: labelFont(ofSize: bucketed),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
        textCache[key] = attributed
        return attributed
    }

    /// Hand-drawn boards write by hand (P3). Noteworthy ships with macOS;
    /// the rounded system face is the graceful fallback.
    private func labelFont(ofSize size: CGFloat) -> NSFont {
        guard sketchy else { return NSFont.systemFont(ofSize: size, weight: .medium) }
        if let hand = NSFont(name: "Noteworthy-Bold", size: size) { return hand }
        let descriptor = NSFont.systemFont(ofSize: size, weight: .medium)
            .fontDescriptor.withDesign(.rounded)
        return descriptor.flatMap { NSFont(descriptor: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size, weight: .medium)
    }

    // MARK: Colors

    private func color(hex: String?, fallback: NSColor) -> CGColor {
        guard let hex, let parsed = NSColor(hexString: hex) else { return fallback.cgColor }
        return parsed.cgColor
    }
}

/// Canvas palette — a thin façade over the shared Studio Graphite tokens so
/// the renderer reads cleanly (Palette.selection, Palette.edgeStroke, …).
enum Palette {
    static let selection = Graphite.accent
    static let nodeStroke = Graphite.nodeStroke
    static let edgeStroke = Graphite.edge
    static let danglingEdge = Graphite.dangling
    static let snapGuide = Graphite.snapGuide
    static let captionBackground = Graphite.captionBackground
    static let nodeText = Graphite.nodeText
    static let noteText = Graphite.noteText
    static let inkStroke = Graphite.ink_stroke
    static let canvasBackground = Graphite.canvas
    static let grid = Graphite.grid
    static let hintText = Graphite.hint

    static func nodeFill(for kind: NodeKind) -> NSColor { Graphite.nodeFill(for: kind) }
    static func kindDot(for kind: NodeKind) -> NSColor { Graphite.kindDot(for: kind) }
}

extension NSColor {
    /// Parses "#RRGGBB" or "#RRGGBBAA".
    public convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else {
            return nil
        }
        let hasAlpha = hex.count == 8
        let divisor: CGFloat = 255
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / divisor
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / divisor
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / divisor
        let a = hasAlpha ? CGFloat(value & 0xFF) / divisor : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

/// The eight resize handles around a single-selection bounding box.
enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    static let size: CGFloat = 8

    func rect(around box: CGRect) -> CGRect {
        let s = Self.size
        let (x, y): (CGFloat, CGFloat)
        switch self {
        case .topLeft: (x, y) = (box.minX, box.minY)
        case .top: (x, y) = (box.midX, box.minY)
        case .topRight: (x, y) = (box.maxX, box.minY)
        case .right: (x, y) = (box.maxX, box.midY)
        case .bottomRight: (x, y) = (box.maxX, box.maxY)
        case .bottom: (x, y) = (box.midX, box.maxY)
        case .bottomLeft: (x, y) = (box.minX, box.maxY)
        case .left: (x, y) = (box.minX, box.midY)
        }
        return CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s)
    }

    /// Applies a world-space drag delta to `original`, respecting a minimum size.
    func resize(_ original: Rect, byWorldDelta dx: Double, _ dy: Double, minSize: Double = 24) -> Rect {
        var rect = original
        func adjustLeft() {
            let applied = min(dx, original.width - minSize)
            rect.x = original.x + applied
            rect.width = original.width - applied
        }
        func adjustRight() { rect.width = max(minSize, original.width + dx) }
        func adjustTop() {
            let applied = min(dy, original.height - minSize)
            rect.y = original.y + applied
            rect.height = original.height - applied
        }
        func adjustBottom() { rect.height = max(minSize, original.height + dy) }

        switch self {
        case .topLeft: adjustLeft(); adjustTop()
        case .top: adjustTop()
        case .topRight: adjustRight(); adjustTop()
        case .right: adjustRight()
        case .bottomRight: adjustRight(); adjustBottom()
        case .bottom: adjustBottom()
        case .bottomLeft: adjustLeft(); adjustBottom()
        case .left: adjustLeft()
        }
        return rect
    }

    var cursor: NSCursor {
        switch self {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .topLeft, .bottomRight, .topRight, .bottomLeft:
            return .crosshair
        }
    }
}
