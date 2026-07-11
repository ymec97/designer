import AppKit
import DesignerModel

/// Draws board content into a CGContext. Stateless apart from a text-layout
/// cache; the view decides *what* is visible (culling) and *where* (viewport).
final class BoardRenderer {
    /// Below this scale, text is unreadable anyway — skip it entirely. This
    /// is both an LOD optimization and better visual noise behavior.
    static let textVisibilityScale: Double = 0.35

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

    func draw(
        _ element: Element,
        in context: CGContext,
        viewport: CanvasViewport,
        frameOverride: Rect? = nil,
        isSelected: Bool,
        suppressText: Bool = false
    ) {
        switch element.content {
        case .node(let node):
            drawNode(
                node, frame: frameOverride ?? node.frame,
                in: context, viewport: viewport,
                isSelected: isSelected, suppressText: suppressText
            )
        case .note(let note):
            drawNote(
                note, frame: frameOverride ?? note.frame,
                in: context, viewport: viewport,
                isSelected: isSelected, suppressText: suppressText
            )
        case .ink(let ink):
            drawInk(ink, in: context, viewport: viewport, isSelected: isSelected)
        case .edge:
            break // M2
        }
    }

    private func drawNode(
        _ node: Node, frame: Rect,
        in context: CGContext, viewport: CanvasViewport,
        isSelected: Bool, suppressText: Bool
    ) {
        let rect = viewport.toView(frame)
        let cornerRadius = min(8 * viewport.scale, rect.width / 4, rect.height / 4)
        let path = CGPath(
            roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
            transform: nil
        )

        if let hex = node.style.fill, let parsed = NSColor(hexString: hex) {
            context.setFillColor(parsed.cgColor)
        } else {
            context.setFillColor(resolvedNodeFill(for: node.semantic.kind))
        }
        context.addPath(path)
        context.fillPath()

        context.setStrokeColor(color(hex: node.style.stroke, fallback: Palette.nodeStroke))
        context.setLineWidth(CGFloat(node.style.strokeWidth ?? 1) * viewport.scale)
        context.addPath(path)
        context.strokePath()

        if isSelected {
            strokeSelection(path: path, in: context, viewport: viewport)
        }

        if !suppressText, viewport.scale >= Self.textVisibilityScale, !node.semantic.name.isEmpty {
            drawText(
                node.semantic.name,
                fontSize: 13 * viewport.scale,
                color: Palette.nodeText,
                centeredIn: rect,
                context: context
            )
        }
    }

    private func drawNote(
        _ note: Note, frame: Rect,
        in context: CGContext, viewport: CanvasViewport,
        isSelected: Bool, suppressText: Bool
    ) {
        let rect = viewport.toView(frame)
        if isSelected {
            let path = CGPath(rect: rect.insetBy(dx: -2, dy: -2), transform: nil)
            strokeSelection(path: path, in: context, viewport: viewport)
        }
        if !suppressText, viewport.scale >= Self.textVisibilityScale, !note.text.isEmpty {
            drawText(
                note.text,
                fontSize: 12 * viewport.scale,
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
        simplified: Bool = false
    ) {
        let viewPoints = route.points.map { viewport.toView($0) }
        guard viewPoints.count >= 2 else { return }

        let strokeColor = color(hex: edge.style.stroke, fallback: Palette.edgeStroke)
        let lineWidth = max(CGFloat(edge.style.strokeWidth ?? 1.5) * viewport.scale, simplified ? 0.5 : 1)

        if isSelected {
            context.setStrokeColor(Palette.selection.withAlphaComponent(0.35).cgColor)
            context.setLineWidth(lineWidth + 4)
            strokePolyline(viewPoints, in: context)
        }

        context.setStrokeColor(isSelected ? Palette.selection.cgColor : strokeColor)
        context.setLineWidth(lineWidth)
        strokePolyline(viewPoints, in: context)

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

        // Label pill + well-known-key badges at the route midpoint.
        if viewport.scale >= Self.textVisibilityScale {
            drawEdgeCaption(edge, at: viewport.toView(route.midpoint), viewport: viewport, in: context)
        }
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
        _ edge: Edge, at center: CGPoint, viewport: CanvasViewport, in context: CGContext
    ) {
        let label = edge.semantic.label ?? ""
        let badgeKeys = [
            WellKnownEdgeProperty.protocolKey,
            WellKnownEdgeProperty.data,
            WellKnownEdgeProperty.condition,
        ]
        let badges = badgeKeys.compactMap { key in
            edge.semantic.properties[key].map { "\(key): \($0)" }
        }
        guard !label.isEmpty || !badges.isEmpty else { return }

        var lines: [NSAttributedString] = []
        if !label.isEmpty {
            lines.append(attributedString(label, fontSize: 12 * viewport.scale, color: Palette.nodeText))
        }
        if !badges.isEmpty {
            lines.append(attributedString(
                badges.joined(separator: "  ·  "),
                fontSize: 10 * viewport.scale,
                color: Palette.noteText
            ))
        }

        let sizes = lines.map { $0.size() }
        let width = sizes.map(\.width).max() ?? 0
        let height = sizes.map(\.height).reduce(0, +)
        let padding = 5 * viewport.scale
        let pill = CGRect(
            x: center.x - width / 2 - padding,
            y: center.y - height / 2 - padding,
            width: width + padding * 2,
            height: height + padding * 2
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
        viewport: CanvasViewport
    ) {
        guard !paths.isEmpty else { return }
        context.saveGState()
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
    func strokeEdgeBatch(_ worldPath: CGPath, in context: CGContext, viewport: CanvasViewport) {
        guard !worldPath.isEmpty else { return }
        context.saveGState()
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
        let hint = "Double-click to add a block   ·   scroll to pan   ·   pinch or ⌘scroll to zoom"
        let attributed = NSAttributedString(string: hint, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: Palette.hintText,
        ])
        let size = attributed.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        attributed.draw(at: CGPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        ))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Adornments

    private func strokeSelection(path: CGPath, in context: CGContext, viewport: CanvasViewport) {
        context.setStrokeColor(Palette.selection.cgColor)
        context.setLineWidth(2)
        context.addPath(path)
        context.strokePath()
    }

    func drawResizeHandles(around viewRect: CGRect, in context: CGContext) {
        context.setFillColor(NSColor.controlBackgroundColor.cgColor)
        context.setStrokeColor(Palette.selection.cgColor)
        context.setLineWidth(1.5)
        for handle in ResizeHandle.allCases {
            let rect = handle.rect(around: viewRect)
            context.fill(rect)
            context.stroke(rect)
        }
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
        let origin = CGPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
        )
        draw(attributed, at: origin, maxWidth: rect.width - 8, context: context)
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
        let rect = CGRect(
            x: origin.x, y: origin.y,
            width: min(size.width, max(maxWidth, 10)), height: size.height
        )
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()
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
            .font: NSFont.systemFont(ofSize: bucketed, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
        textCache[key] = attributed
        return attributed
    }

    // MARK: Colors

    private func color(hex: String?, fallback: NSColor) -> CGColor {
        guard let hex, let parsed = NSColor(hexString: hex) else { return fallback.cgColor }
        return parsed.cgColor
    }
}

/// Theme-aware defaults (NFR U4): system dynamic colors so boards read
/// correctly in light and dark mode without per-element colors.
enum Palette {
    static let selection = NSColor.controlAccentColor
    static let nodeStroke = NSColor.secondaryLabelColor
    static let edgeStroke = NSColor.secondaryLabelColor
    /// Slightly translucent so captions sit on lines without hard boxes.
    static let captionBackground = NSColor.windowBackgroundColor.withAlphaComponent(0.88)
    static let nodeText = NSColor.labelColor
    static let noteText = NSColor.secondaryLabelColor
    static let inkStroke = NSColor.labelColor
    static let canvasBackground = NSColor.windowBackgroundColor
    static let grid = NSColor.separatorColor.withAlphaComponent(0.35)
    static let hintText = NSColor.tertiaryLabelColor

    /// Node surface must contrast with the canvas in BOTH appearances —
    /// system "background" colors don't (controlBackgroundColor ≈
    /// windowBackgroundColor in dark mode, which made blocks invisible).
    private static let nodeSurface = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.27, green: 0.28, blue: 0.30, alpha: 1)
            : NSColor.white
    }

    static func nodeFill(for kind: NodeKind) -> NSColor {
        switch kind {
        case .database: return nodeSurface.tinted(with: .systemBlue)
        case .queue: return nodeSurface.tinted(with: .systemOrange)
        case .cache: return nodeSurface.tinted(with: .systemPurple)
        case .gateway: return nodeSurface.tinted(with: .systemTeal)
        case .client: return nodeSurface.tinted(with: .systemGreen)
        case .external: return nodeSurface.tinted(with: .systemGray)
        default: return nodeSurface
        }
    }
}

extension NSColor {
    func tinted(with tint: NSColor) -> NSColor {
        NSColor(name: nil) { _ in
            self.blended(withFraction: 0.18, of: tint) ?? self
        }
    }
}

extension NSColor {
    /// Parses "#RRGGBB" or "#RRGGBBAA".
    convenience init?(hexString: String) {
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
