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

    /// Whether nodes get a soft drop shadow this pass. Elevation is set false
    /// when many nodes are visible (CoreGraphics shadows are per-node and
    /// costly) — imperceptible on a dense board, and it keeps the frame budget.
    var elevateNodes = true

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
        default:
            let cornerRadius = min(8 * viewport.scale, rect.width / 4, rect.height / 4)
            path = CGPath(
                roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                transform: nil
            )
        }

        // Soft elevation (Studio Graphite): a quiet drop shadow lifts the node
        // off the graphite ground. Skipped on dense boards (elevateNodes) to
        // protect the frame budget.
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

        context.setStrokeColor(color(hex: node.style.stroke, fallback: Palette.nodeStroke))
        context.setLineWidth(CGFloat(node.style.strokeWidth ?? 1.25) * viewport.scale)
        context.addPath(path)
        context.strokePath()

        // The kind dot — one saturated spot of colour, top-left inside the
        // node. Only on rectangles/ellipses, where it sits cleanly (a diamond
        // or triangle's corners crowd it).
        let dottable = node.shape == .rectangle || node.shape == .ellipse
        if elevateNodes, dottable, node.semantic.kind != .generic, viewport.scale >= Self.textVisibilityScale {
            let r = 3.4 * viewport.scale
            let inset = 13 * viewport.scale
            let anchor = CGPoint(x: rect.minX + inset, y: rect.minY + inset)
            context.setFillColor(Palette.kindDot(for: node.semantic.kind).cgColor)
            context.fillEllipse(in: CGRect(x: anchor.x - r, y: anchor.y - r, width: r * 2, height: r * 2))
        }

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
        isDangling: Bool = false,
        simplified: Bool = false
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
        strokePolyline(viewPoints, in: context)
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

    /// A lit node: an accent glow halo, brighter when it has just been reached.
    func drawSimulationNodeGlow(
        _ path: CGPath, in context: CGContext, viewport: CanvasViewport, intensity: CGFloat
    ) {
        context.saveGState()
        context.setShadow(
            offset: .zero, blur: 14 * viewport.scale,
            color: Graphite.accent.withAlphaComponent(0.55 * intensity).cgColor
        )
        context.setStrokeColor(Graphite.accent.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(2 * viewport.scale)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// An edge the flow has used: a bright accent overlay on its route.
    func drawSimulationEdge(
        _ viewPoints: [CGPoint], in context: CGContext, viewport: CanvasViewport, active: Bool
    ) {
        guard viewPoints.count >= 2 else { return }
        context.setStrokeColor(Graphite.accent.withAlphaComponent(active ? 0.95 : 0.7).cgColor)
        context.setLineWidth((active ? 2.4 : 1.8) * viewport.scale)
        context.setLineCap(.round)
        strokePolyline(viewPoints, in: context)
    }

    /// The travelling packet — a glowing accent dot at the head of the flow.
    func drawSimulationPacket(at point: CGPoint, in context: CGContext, viewport: CanvasViewport) {
        let r = 5 * viewport.scale
        context.saveGState()
        context.setShadow(offset: .zero, blur: 8 * viewport.scale, color: Graphite.accent.cgColor)
        context.setFillColor(Graphite.accent.cgColor)
        context.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
        context.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        let ri = r * 0.4
        context.fillEllipse(in: CGRect(x: point.x - ri, y: point.y - ri, width: ri * 2, height: ri * 2))
        context.restoreGState()
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
