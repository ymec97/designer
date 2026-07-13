import AppKit
import SwiftUI
import DesignerModel

public protocol CanvasViewDelegate: AnyObject {
    /// The one channel for document mutations (operation layer, D11).
    func canvasView(_ view: CanvasView, perform operation: BoardOperation, actionName: String)
    func canvasViewDidChangeSelection(_ view: CanvasView)
}

/// The board canvas: rendering, navigation, selection, and direct
/// manipulation. Holds *view* state only (viewport, selection, in-flight
/// gestures); the document is the single source of truth for the board.
public final class CanvasView: NSView {
    public weak var delegate: CanvasViewDelegate?

    public var board = Board(title: "") {
        didSet {
            routeCache = SpatialIndex.resolveRoutes(for: board)
            spatialIndex = SpatialIndex(board: board, edgeRoutes: routeCache)
            edgeBatchCache = nil
            boardRevision += 1
            // zOrderedElements FIRST — the derived caches below read it.
            zOrderedElements = board.elementsInZOrder
            inkElementIDs = zOrderedElements.compactMap {
                if case .ink = $0.content { return $0.id }
                return nil
            }
            danglingEdgeIDs = Set(zOrderedElements.compactMap { element in
                guard let edge = element.edge, board.isDangling(edge) else { return nil }
                return element.id
            })
            selection.formIntersection(Set(board.elements.keys))
            needsDisplay = true
        }
    }

    /// Cached draw order — rebuilt on board changes, never per frame.
    private var zOrderedElements: [Element] = []
    /// Resolved edge routes — rebuilt on board changes; only edges touched by
    /// an in-flight drag are re-resolved per frame.
    private var routeCache: [ElementID: EdgeGeometry.Route] = [:]
    /// World-space paths holding every edge except `excluded` — stroked in
    /// single CG calls through the CTM, split into full-opacity and dimmed
    /// groups when focus mode is on. Rebuilt when the exclusion set changes
    /// (once per drag gesture), not per frame.
    private var edgeBatchCache: (excluded: Set<ElementID>, active: CGPath, dimmed: CGPath)?

    /// Bumped on every board change; keys the renderer's edge-layer cache.
    private var boardRevision = 0

    private func edgeBatchPaths(
        excluding excluded: Set<ElementID>
    ) -> (active: CGPath, dimmed: CGPath) {
        if let cache = edgeBatchCache, cache.excluded == excluded {
            return (cache.active, cache.dimmed)
        }
        let active = CGMutablePath()
        let dimmed = CGMutablePath()
        for (id, route) in routeCache where !excluded.contains(id) {
            guard let first = route.points.first else { continue }
            let path = (board.elements[id].map(isDimmed) == true) ? dimmed : active
            path.move(to: CGPoint(x: first.x, y: first.y))
            for point in route.points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
        }
        edgeBatchCache = (excluded, active, dimmed)
        return (active, dimmed)
    }

    /// World-space node rect paths grouped by fill color, cached per board
    /// revision (and per drag-exclusion set, rebuilt once per gesture),
    /// split into full-opacity and dimmed groups when focus mode is on.
    private var nodeBatchCache: (
        revision: Int,
        excluded: Set<ElementID>,
        active: [(color: CGColor, path: CGPath)],
        dimmed: [(color: CGColor, path: CGPath)]
    )?
    /// Ink elements are rare; they draw individually on the fast path.
    private var inkElementIDs: [ElementID] = []
    /// Edges with an unattached endpoint — warning style, excluded from batches.
    private var danglingEdgeIDs: Set<ElementID> = []

    private func nodeBatchPaths(
        excluding excluded: Set<ElementID>
    ) -> (active: [(color: CGColor, path: CGPath)], dimmed: [(color: CGColor, path: CGPath)]) {
        if let cache = nodeBatchCache, cache.revision == boardRevision, cache.excluded == excluded {
            return (cache.active, cache.dimmed)
        }
        let hiddenLayers = Set(board.layers.filter { !$0.isVisible }.map(\.id))
        var activeByColor: [CGColor: CGMutablePath] = [:]
        var dimmedByColor: [CGColor: CGMutablePath] = [:]
        for element in zOrderedElements {
            guard !excluded.contains(element.id),
                  let node = element.node,
                  element.layerIDs.contains(where: { !hiddenLayers.contains($0) }) else { continue }
            let color: CGColor
            if let hex = node.style.fill, let parsed = NSColor(hexString: hex) {
                color = parsed.cgColor
            } else {
                color = renderer.resolvedNodeFill(for: node.semantic.kind)
            }
            // Explicit insert: `[_, default:]` with a method call on a class
            // value is a get, so the default would never be stored.
            let dimmedElement = isDimmed(element)
            var byColor = dimmedElement ? dimmedByColor : activeByColor
            let path: CGMutablePath
            if let existing = byColor[color] {
                path = existing
            } else {
                path = CGMutablePath()
                byColor[color] = path
            }
            path.addRect(CGRect(
                x: node.frame.x, y: node.frame.y,
                width: node.frame.width, height: node.frame.height
            ))
            if dimmedElement { dimmedByColor = byColor } else { activeByColor = byColor }
        }
        let active = activeByColor.map { (color: $0.key, path: $0.value as CGPath) }
        let dimmed = dimmedByColor.map { (color: $0.key, path: $0.value as CGPath) }
        nodeBatchCache = (boardRevision, excluded, active, dimmed)
        return (active, dimmed)
    }

    /// Settable so controllers can restore saved view state and test drivers
    /// can script navigation.
    public var viewport = CanvasViewport() {
        didSet { needsDisplay = true }
    }

    public private(set) var selection: Set<ElementID> = [] {
        didSet {
            if selection != oldValue {
                needsDisplay = true
                delegate?.canvasViewDidChangeSelection(self)
            }
        }
    }

    private var spatialIndex = SpatialIndex()
    private let renderer = BoardRenderer()

    /// Frames shown during an in-flight drag/resize, committed as one
    /// operation (= one undo step) at gesture end.
    private var transientFrames: [ElementID: Rect] = [:]
    /// Alignment guides to draw during a snapping move.
    private var snapGuides: [SnapEngine.Guide] = []

    private func union(of rects: some Collection<Rect>) -> Rect? {
        guard var result = rects.first else { return nil }
        for rect in rects.dropFirst() {
            let minX = min(result.x, rect.x), minY = min(result.y, rect.y)
            let maxX = max(result.maxX, rect.maxX), maxY = max(result.maxY, rect.maxY)
            result = Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        return result
    }

    /// Node/note frames eligible as snap targets (visible, not being dragged).
    private func snapCandidates(excluding movingIDs: Set<ElementID>) -> [Rect] {
        let visibleWorld = viewport.visibleWorldRect(viewSize: bounds.size)
        return spatialIndex.query(visibleWorld).compactMap { id -> Rect? in
            guard !movingIDs.contains(id), let element = board.elements[id],
                  element.node != nil || isNote(element) else { return nil }
            return SpatialIndex.boundingRect(of: element)
        }
    }

    /// Active interaction tool. Select is the default; Draw captures ink.
    public enum Tool {
        case select
        case draw
    }

    public var tool: Tool = .select {
        didSet {
            guard tool != oldValue else { return }
            commitLabelEditor()
            gesture = .idle
            window?.invalidateCursorRects(for: self)
            updateCursor(at: nil)
            needsDisplay = true
            toolChanged?(tool)
        }
    }

    /// Observers (toolbar) are told when the tool changes, however it changes.
    public var toolChanged: ((Tool) -> Void)?

    /// Where new elements land (D9). Nil falls back to the first visible,
    /// unlocked layer. Set by the layers panel.
    public var activeLayerID: LayerID? {
        didSet {
            guard activeLayerID != oldValue else { return }
            edgeBatchCache = nil
            nodeBatchCache = nil
            needsDisplay = true
        }
    }

    /// Focus mode: elements not on the active layer render dimmed.
    public var focusActiveLayer: Bool = false {
        didSet {
            guard focusActiveLayer != oldValue else { return }
            edgeBatchCache = nil
            nodeBatchCache = nil
            needsDisplay = true
        }
    }

    static let dimmedAlpha: CGFloat = 0.22

    /// Non-nil when focus dimming is in effect: the layer to keep at full
    /// opacity.
    private var focusLayerID: LayerID? {
        guard focusActiveLayer, let id = activeLayerID,
              board.layers.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private func isDimmed(_ element: Element) -> Bool {
        guard let focusID = focusLayerID else { return false }
        return !element.layerIDs.contains(focusID)
    }

    private enum GestureState {
        case idle
        case mouseDown(at: CGPoint, on: ElementID?, hadSelection: Bool)
        case move(originals: [ElementID: Rect], startWorld: Point)
        case resize(id: ElementID, handle: ResizeHandle, original: Rect, startWorld: Point)
        case rubberBand(start: CGPoint, current: CGPoint)
        case connect(from: ElementID, current: CGPoint, target: ElementID?)
        case draw(points: [StrokePoint], startedAt: TimeInterval)
    }

    /// World-space width of the border band that starts a connection drag
    /// instead of a move (in view pixels, so it feels constant at any zoom).
    private static let connectBandViewWidth: CGFloat = 10

    private var gesture: GestureState = .idle
    private var labelEditor: NSTextField?
    private var editingElementID: ElementID?
    /// Typing undo stays local to the editing session; only the committed
    /// rename lands on the document's undo stack (as one operation).
    private var labelEditingUndoManager = UndoManager()
    private var edgePopover: NSPopover?
    /// Edge state when the popover opened; the diff commits as one operation.
    private var edgeEditBaseline: (id: ElementID, edge: DesignerModel.Edge)?
    private var edgeEditCurrent: EdgeEditorView.Values?

    // MARK: Setup

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    public required init?(coder: NSCoder) {
        fatalError("CanvasView is created in code")
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    /// First click on an inactive window should engage the canvas, not be
    /// swallowed by click-through protection.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Rendering

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        var probeT0 = CACurrentMediaTime()
        var probeReport = ""
        func probe(_ name: String) {
            guard Self.perfProbe != nil else { return }
            let now = CACurrentMediaTime()
            probeReport += String(format: "%@=%.2f ", name, (now - probeT0) * 1000)
            probeT0 = now
        }

        context.setFillColor(Palette.canvasBackground.cgColor)
        context.fill(bounds)

        if board.elements.isEmpty {
            // Still show the hint, but keep drawing so the very first stroke
            // on a blank canvas is visible while it's being drawn (it isn't
            // committed to the board until mouseUp).
            if case .draw = gesture {} else {
                renderer.drawEmptyHint(in: context, bounds: bounds)
            }
            drawInFlightGesture(in: context)
            return
        }

        // Edges anchored to a node being dragged follow it live; their cached
        // routes and indexed bounds are stale until the gesture commits, so
        // they are collected and re-resolved individually.
        var dragAffectedEdges: Set<ElementID> = []
        if !transientFrames.isEmpty {
            for id in transientFrames.keys {
                for edge in board.edges(anchoredTo: id) {
                    dragAffectedEdges.insert(edge.id)
                }
            }
        }
        let overrideFrames = transientFrames.isEmpty
            ? nil
            : board.frameProvider(overrides: transientFrames)
        // Routes come from the per-board-revision cache except for the few
        // edges tracking an in-flight drag — resolving 4k routes per frame
        // was the difference between 45ms and 16ms frames at fit zoom.
        let routeFor: (Element) -> EdgeGeometry.Route? = { [routeCache] element in
            if let overrideFrames, dragAffectedEdges.contains(element.id), let edge = element.edge {
                return EdgeGeometry.route(for: edge, frames: overrideFrames)
            }
            return routeCache[element.id]
        }

        let hiddenLayers = Set(board.layers.filter { !$0.isVisible }.map(\.id))
        func isOnVisibleLayer(_ element: Element) -> Bool {
            element.layerIDs.contains { !hiddenLayers.contains($0) }
        }

        if viewport.scale < BoardRenderer.textVisibilityScale {
            // FAR-ZOOM FAST PATH. Below caption scale, edges are plain lines
            // and nodes are plain rects — both come from world-space paths
            // cached per board revision and drawn through the CTM. No culling,
            // no per-element Swift work: the probe showed query+filter+
            // per-node batching cost ~11ms/frame at 6k elements; this path
            // does a handful of CG calls regardless of element count.
            let edgePaths = edgeBatchPaths(excluding: dragAffectedEdges.union(danglingEdgeIDs))
            renderer.strokeEdgeBatch(edgePaths.active, in: context, viewport: viewport)
            renderer.strokeEdgeBatch(
                edgePaths.dimmed, in: context, viewport: viewport, alpha: Self.dimmedAlpha
            )
            // Dangling connectors keep their warning style at any zoom.
            for id in danglingEdgeIDs where !dragAffectedEdges.contains(id) {
                guard let element = board.elements[id], isOnVisibleLayer(element),
                      let edge = element.edge, let route = routeFor(element) else { continue }
                withFocusAlpha(context, dimmed: isDimmed(element)) {
                    renderer.drawEdge(
                        edge, route: route, in: context, viewport: viewport,
                        isSelected: selection.contains(id), isDangling: true, simplified: true
                    )
                }
            }
            probe("edges")

            let nodePaths = nodeBatchPaths(excluding: Set(transientFrames.keys))
            renderer.fillNodeBatch(nodePaths.active, in: context, viewport: viewport)
            renderer.fillNodeBatch(
                nodePaths.dimmed, in: context, viewport: viewport, alpha: Self.dimmedAlpha
            )

            // Individual overlays: drag-affected edges, selection, in-flight
            // drags, and ink (rare at this scale, drawn as-is).
            for id in dragAffectedEdges {
                guard let element = board.elements[id], isOnVisibleLayer(element),
                      let edge = element.edge, let route = routeFor(element) else { continue }
                renderer.drawEdge(
                    edge, route: route, in: context, viewport: viewport,
                    isSelected: selection.contains(id),
                    isDangling: danglingEdgeIDs.contains(id),
                    simplified: true
                )
            }
            for id in selection {
                guard let element = board.elements[id], isOnVisibleLayer(element) else { continue }
                if let edge = element.edge {
                    guard !dragAffectedEdges.contains(id), !danglingEdgeIDs.contains(id),
                          let route = routeFor(element) else { continue }
                    renderer.drawEdge(
                        edge, route: route, in: context, viewport: viewport,
                        isSelected: true, simplified: true
                    )
                } else if let node = element.node {
                    renderer.drawSimplifiedNode(
                        node, frame: transientFrames[id] ?? node.frame,
                        in: context, viewport: viewport, isSelected: true
                    )
                }
            }
            for (id, frame) in transientFrames where !selection.contains(id) {
                guard let node = board.elements[id]?.node else { continue }
                renderer.drawSimplifiedNode(
                    node, frame: frame, in: context, viewport: viewport, isSelected: false
                )
            }
            for id in inkElementIDs {
                guard let element = board.elements[id], isOnVisibleLayer(element) else { continue }
                withFocusAlpha(context, dimmed: isDimmed(element)) {
                    renderer.draw(
                        element, in: context, viewport: viewport,
                        isSelected: selection.contains(id)
                    )
                }
            }
            probe("nodes")
        } else {
            // NEAR-ZOOM FULL PATH: cull to the viewport, draw each element
            // with full detail (rounded nodes, text, arrowheads, captions).
            let visibleWorld = viewport.visibleWorldRect(viewSize: bounds.size)
            var visibleIDs = spatialIndex.query(visibleWorld)
            visibleIDs.formUnion(dragAffectedEdges)
            probe("query")

            // Cached z-order; per-frame work is a filter, not a sort.
            let drawables = zOrderedElements.filter { element in
                visibleIDs.contains(element.id) && isOnVisibleLayer(element)
            }
            probe("filter")

            // Elevation shadows only when few nodes are on screen — costly
            // per-node, imperceptible when dense.
            let visibleNodeCount = drawables.reduce(0) { $0 + ($1.node != nil ? 1 : 0) }
            renderer.elevateNodes = visibleNodeCount <= 70

            for element in drawables {
                withFocusAlpha(context, dimmed: isDimmed(element)) {
                    if let edge = element.edge {
                        if let route = routeFor(element) {
                            renderer.drawEdge(
                                edge, route: route,
                                in: context, viewport: viewport,
                                isSelected: selection.contains(element.id),
                                isDangling: danglingEdgeIDs.contains(element.id)
                            )
                        }
                    } else {
                        renderer.draw(
                            element,
                            in: context,
                            viewport: viewport,
                            frameOverride: transientFrames[element.id],
                            isSelected: selection.contains(element.id),
                            suppressText: element.id == editingElementID
                        )
                    }
                }
            }
            probe("nodes")
        }
        if let report = Self.perfProbe, !probeReport.isEmpty {
            report(probeReport)
        }

        if let handleBox = singleSelectionViewRect() {
            renderer.drawResizeHandles(around: handleBox, in: context)
        }

        for guide in snapGuides {
            renderer.drawSnapGuide(guide, in: context, viewport: viewport)
        }

        drawSimulationOverlay(in: context)
        drawInFlightGesture(in: context)
    }

    // MARK: Traffic simulation (F2)

    private var simulator: TrafficSimulator?
    private var simulationDisplayLink: CADisplayLink?
    private var simulationClock: TimeInterval = 0   // accumulated simulation seconds
    private var lastSimulationTick: CFTimeInterval = 0
    private var simulationPaused = false

    /// Simulation speed multiplier (1 = normal).
    public var simulationSpeed: Double = 1

    public var isSimulating: Bool { simulator != nil }
    /// Fires when a simulation starts, pauses/resumes, or ends (so chrome can
    /// show/update the transport). Bool = running (unpaused).
    public var simulationStateChanged: ((_ active: Bool, _ paused: Bool) -> Void)?

    /// Whether the given node can be a simulation source (a node with outgoing
    /// flow), so callers can offer the affordance only when it's meaningful.
    public func canSimulate(from id: ElementID) -> Bool {
        !TrafficSimulation.steps(from: id, in: board).isEmpty
    }

    public func startSimulation(from source: ElementID) {
        guard board.elements[source]?.node != nil else { return }
        let sim = TrafficSimulator(source: source, board: board)
        guard !sim.isEmpty else { return }
        simulator = sim
        simulationClock = 0
        simulationPaused = false
        lastSimulationTick = CACurrentMediaTime()

        let link = displayLink(target: self, selector: #selector(simulationTick(_:)))
        link.add(to: .main, forMode: .common)
        simulationDisplayLink = link
        simulationStateChanged?(true, false)
        needsDisplay = true
    }

    public func pauseSimulation() {
        guard isSimulating, !simulationPaused else { return }
        simulationPaused = true
        simulationStateChanged?(true, true)
    }

    public func resumeSimulation() {
        guard isSimulating, simulationPaused else { return }
        simulationPaused = false
        lastSimulationTick = CACurrentMediaTime()
        simulationStateChanged?(true, false)
    }

    public func restartSimulation() {
        guard isSimulating else { return }
        simulationClock = 0
        simulationPaused = false
        lastSimulationTick = CACurrentMediaTime()
        simulationStateChanged?(true, false)
        needsDisplay = true
    }

    public func stopSimulation() {
        simulationDisplayLink?.invalidate()
        simulationDisplayLink = nil
        simulator = nil
        simulationPaused = false
        simulationStateChanged?(false, false)
        needsDisplay = true
    }

    @objc private func simulationTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let delta = now - lastSimulationTick
        lastSimulationTick = now
        guard let sim = simulator, !simulationPaused else { return }
        simulationClock += delta * simulationSpeed
        // Loop with a short pause at the end so the flow reads as continuous.
        if simulationClock > sim.totalDuration + 0.9 {
            simulationClock = 0
        }
        needsDisplay = true
    }

    private func drawSimulationOverlay(in context: CGContext) {
        guard let sim = simulator else { return }
        let frame = sim.frame(at: simulationClock)
        let frames = board.frameProvider(overrides: transientFrames)

        renderer.drawSimulationScrim(bounds, in: context)

        // Lit edges (done first, then active) in accent.
        for edgeID in frame.doneEdges {
            guard let route = routeCache[edgeID] else { continue }
            renderer.drawSimulationEdge(route.points.map { viewport.toView($0) }, in: context, viewport: viewport, active: false)
        }
        for active in frame.activeEdges {
            guard let route = routeCache[active.id] else { continue }
            renderer.drawSimulationEdge(route.points.map { viewport.toView($0) }, in: context, viewport: viewport, active: true)
        }

        // Lit nodes with a glow; source and freshly-reached pulse brightest.
        for nodeID in frame.litNodes {
            guard let element = board.elements[nodeID], let node = element.node else { continue }
            let path = nodeGlowPath(for: node, id: nodeID, frames: frames)
            renderer.draw(element, in: context, viewport: viewport, isSelected: false)
            renderer.drawSimulationNodeGlow(path, in: context, viewport: viewport, intensity: 1)
        }

        // Travelling packets at the head of each active edge.
        for active in frame.activeEdges {
            guard let route = routeCache[active.id] else { continue }
            let world = route.point(atFraction: active.progress)
            renderer.drawSimulationPacket(at: viewport.toView(world), in: context, viewport: viewport)
        }
    }

    private func nodeGlowPath(for node: Node, id: ElementID, frames: EdgeGeometry.FrameProvider) -> CGPath {
        let frame = frames(id) ?? node.frame
        let rect = viewport.toView(frame)
        switch node.shape {
        case .ellipse: return CGPath(ellipseIn: rect, transform: nil)
        default:
            let r = min(8 * viewport.scale, rect.width / 4, rect.height / 4)
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        }
    }

    /// In-flight gesture overlays (rubber band, live ink stroke, connect
    /// preview). Drawn in both the normal and empty-canvas paths so the very
    /// first stroke is visible while drawing.
    private func drawInFlightGesture(in context: CGContext) {
        switch gesture {
        case .rubberBand(let start, let current):
            renderer.drawRubberBand(rectFrom(start, current), in: context)

        case .draw(let points, _) where points.count > 1:
            renderer.drawInk(
                Ink(points: points, style: Style(strokeWidth: 2)),
                in: context, viewport: viewport, isSelected: false
            )

        case .connect(let fromID, let current, let target):
            let frames = board.frameProvider(overrides: transientFrames)
            if let frame = frames(fromID) {
                let startWorld = EdgeGeometry.point(
                    on: frame,
                    side: EdgeGeometry.autoSide(from: frame, toward: viewport.toWorld(current)),
                    offset: 0.5
                )
                renderer.drawConnectPreview(
                    from: viewport.toView(startWorld), to: current, in: context
                )
            }
            if let target, let targetFrame = frames(target) {
                renderer.highlightConnectTarget(viewport.toView(targetFrame), in: context)
            }

        default:
            break
        }
    }

    // MARK: Navigation input

    public override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // ⌘-scroll zooms toward the cursor.
            let factor = pow(1.0015, Double(event.scrollingDeltaY))
            viewport.zoom(by: factor, at: convert(event.locationInWindow, from: nil))
        } else {
            viewport.pan(viewDeltaX: event.scrollingDeltaX, viewDeltaY: event.scrollingDeltaY)
        }
    }

    public override func magnify(with event: NSEvent) {
        viewport.zoom(
            by: 1 + Double(event.magnification),
            at: convert(event.locationInWindow, from: nil)
        )
    }

    @objc public func zoomIn(_ sender: Any?) {
        viewport.zoom(by: 1.25, at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    @objc public func zoomOut(_ sender: Any?) {
        viewport.zoom(by: 0.8, at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    @objc public func zoomActualSize(_ sender: Any?) {
        viewport.setScale(1, at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    @objc public func zoomToFit(_ sender: Any?) {
        let rects = board.elements.values.compactMap(SpatialIndex.boundingRect(of:))
        guard let first = rects.first else { return }
        var union = first
        for rect in rects.dropFirst() {
            let minX = min(union.x, rect.x), minY = min(union.y, rect.y)
            let maxX = max(union.maxX, rect.maxX), maxY = max(union.maxY, rect.maxY)
            union = Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        viewport.fit(union, in: bounds.size)
    }

    // MARK: Mouse input

    /// Temporary M1 debug hook; removed once the interaction bug is fixed.
    public static var debugTrace: ((String) -> Void)?
    /// Perf probe: receives per-section draw timings (ms) when set.
    public static var perfProbe: ((String) -> Void)?

    public override func mouseDown(with event: NSEvent) {
        Self.debugTrace?("mouseDown clicks=\(event.clickCount) window=\(event.locationInWindow)")
        // Simulation is a read-only mode; ignore edit gestures (pan/zoom still
        // work via scroll/pinch). The transport controls it.
        if isSimulating { return }
        commitLabelEditor()
        let point = convert(event.locationInWindow, from: nil)

        if tool == .draw {
            gesture = .draw(
                points: [strokePoint(from: event, at: point, since: event.timestamp)],
                startedAt: event.timestamp
            )
            return
        }

        if event.clickCount == 2 {
            Self.debugTrace?("doubleClick at view=\(point)")
            handleDoubleClick(at: point)
            return
        }

        // Resize handle?
        if let handleBox = singleSelectionViewRect(),
           let id = selection.first,
           let handle = ResizeHandle.allCases.first(where: {
               $0.rect(around: handleBox).insetBy(dx: -3, dy: -3).contains(point)
           }),
           let element = board.elements[id],
           let original = SpatialIndex.boundingRect(of: element) {
            gesture = .resize(
                id: id, handle: handle, original: original,
                startWorld: viewport.toWorld(point)
            )
            return
        }

        let hit = editableElement(at: point)

        // Starting a drag from a node's border band creates a connection.
        if let hit, hit.node != nil, !event.modifierFlags.contains(.shift),
           isInConnectBand(point, of: hit) {
            gesture = .connect(from: hit.id, current: point, target: nil)
            return
        }

        if let hit {
            if event.modifierFlags.contains(.shift) {
                if selection.contains(hit.id) {
                    selection.remove(hit.id)
                } else {
                    selection.insert(hit.id)
                }
            } else if !selection.contains(hit.id) {
                selection = [hit.id]
            }
        } else if !event.modifierFlags.contains(.shift) {
            selection = []
        }
        gesture = .mouseDown(at: point, on: hit?.id, hadSelection: hit != nil)
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch gesture {
        case .mouseDown(let start, let hitID, _):
            let distance = hypot(point.x - start.x, point.y - start.y)
            guard distance > 3 else { return }
            if hitID != nil, !selection.isEmpty {
                var originals: [ElementID: Rect] = [:]
                for id in selection {
                    if let element = board.elements[id], element.node != nil || isNote(element) {
                        originals[id] = SpatialIndex.boundingRect(of: element)
                    }
                }
                gesture = .move(originals: originals, startWorld: viewport.toWorld(start))
                mouseDragged(with: event)
            } else {
                gesture = .rubberBand(start: start, current: point)
                needsDisplay = true
            }

        case .move(let originals, let startWorld):
            let world = viewport.toWorld(point)
            var dx = world.x - startWorld.x
            var dy = world.y - startWorld.y

            // Alignment snapping (suppressed while ⌘ is held) against nearby
            // elements not being dragged.
            snapGuides = []
            if !event.modifierFlags.contains(.command), let movingUnion = union(of: originals.values) {
                let moved = movingUnion.offsetBy(dx: dx, dy: dy)
                let movingIDs = Set(originals.keys)
                let others = snapCandidates(excluding: movingIDs)
                let snap = SnapEngine.snap(movingBox: moved, others: others, threshold: 7 / viewport.scale)
                dx += snap.dx
                dy += snap.dy
                snapGuides = snap.guides
            }

            for (id, original) in originals {
                transientFrames[id] = original.offsetBy(dx: dx, dy: dy)
            }
            needsDisplay = true

        case .resize(let id, let handle, let original, let startWorld):
            let world = viewport.toWorld(point)
            transientFrames[id] = handle.resize(
                original,
                byWorldDelta: world.x - startWorld.x, world.y - startWorld.y
            )
            needsDisplay = true

        case .rubberBand(let start, _):
            gesture = .rubberBand(start: start, current: point)
            needsDisplay = true

        case .connect(let fromID, _, _):
            let target = editableElement(at: point)
            let targetID = (target?.node != nil && target?.id != fromID) ? target?.id : nil
            gesture = .connect(from: fromID, current: point, target: targetID)
            needsDisplay = true

        case .draw(var points, let startedAt):
            points.append(strokePoint(from: event, at: point, since: startedAt))
            gesture = .draw(points: points, startedAt: startedAt)
            needsDisplay = true

        case .idle:
            break
        }
    }

    /// World-space stroke sample from an input event. Pressure comes from
    /// tablet events (Sidecar pencil, Wacom); plain mouse/trackpad strokes
    /// use the neutral 0.5 — ink never requires a pressure device (D15 note).
    private func strokePoint(from event: NSEvent, at viewPoint: CGPoint, since start: TimeInterval) -> StrokePoint {
        let world = viewport.toWorld(viewPoint)
        let pressure: Double
        if event.subtype == .tabletPoint || event.subtype == .tabletProximity {
            pressure = Double(event.pressure)
        } else {
            pressure = 0.5
        }
        return StrokePoint(x: world.x, y: world.y, pressure: pressure, time: event.timestamp - start)
    }

    public override func mouseUp(with event: NSEvent) {
        snapGuides = []
        switch gesture {
        case .move, .resize:
            commitTransientFrames(actionName: {
                if case .resize = gesture { return "Resize" }
                return "Move"
            }())

        case .rubberBand(let start, let current):
            let band = rectFrom(start, current)
            let worldBand = Rect(
                x: viewport.toWorld(band.origin).x,
                y: viewport.toWorld(band.origin).y,
                width: Double(band.width) / viewport.scale,
                height: Double(band.height) / viewport.scale
            )
            let hitIDs = spatialIndex.query(worldBand).filter { isEditable(id: $0) }
            if event.modifierFlags.contains(.shift) {
                selection.formUnion(hitIDs)
            } else {
                selection = hitIDs
            }
            needsDisplay = true

        case .connect(let fromID, let dropPoint, let targetID):
            if let targetID {
                switch board.connectionMergeOutcome(from: fromID, to: targetID) {
                case .alreadyConnected(let existing):
                    // Idempotent: repeating a connection selects it, no duplicate.
                    selection = [existing]
                case .oppositeDirection(let existing):
                    if let operation = board.makeBidirectionalOperation(existing) {
                        delegate?.canvasView(self, perform: operation, actionName: "Make Bidirectional")
                    }
                    selection = [existing]
                case .none:
                    let layerIDs = activeLayerIDs()
                    let element = Element(
                        layerIDs: layerIDs.isEmpty ? [board.layers[0].id] : layerIDs,
                        sortKey: board.topSortKey,
                        content: .edge(Edge(
                            from: .element(fromID, side: nil, offset: nil),
                            to: .element(targetID, side: nil, offset: nil)
                        ))
                    )
                    delegate?.canvasView(self, perform: .insertElement(element), actionName: "Connect")
                    selection = [element.id]
                    // Seamless labeling: open the editor on the fresh edge so
                    // protocol/data/label can be set without a second click.
                    if let inserted = board.elements[element.id] {
                        gesture = .idle
                        presentEdgeEditor(for: inserted, at: dropPoint)
                    }
                }
            }
            needsDisplay = true

        case .draw(var points, let startedAt):
            points.append(strokePoint(
                from: event,
                at: convert(event.locationInWindow, from: nil),
                since: startedAt
            ))
            if points.count > 1 {
                let element = Element(
                    layerIDs: activeLayerIDs().isEmpty ? [board.layers[0].id] : activeLayerIDs(),
                    sortKey: board.topSortKey,
                    content: .ink(Ink(points: points, style: Style(strokeWidth: 2)))
                )
                delegate?.canvasView(self, perform: .insertElement(element), actionName: "Draw")
                strokeFinished?(element.id)
            }
            needsDisplay = true

        case .mouseDown, .idle:
            break
        }
        gesture = .idle
    }

    /// Called after a drawn stroke is committed — the live-recognition hook.
    public var strokeFinished: ((ElementID) -> Void)?

    /// Programmatic selection (structurize handover, tests).
    public func select(_ ids: Set<ElementID>) {
        selection = ids.filter { board.elements[$0] != nil }
    }

    /// World point at the center of the visible canvas — the natural drop
    /// location for inserted library clips.
    public var visibleCenterWorld: Point {
        viewport.toWorld(CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// Inside the node but within a thin band of its border (or slightly
    /// outside it) — the affordance for starting a connection.
    private func isInConnectBand(_ viewPoint: CGPoint, of element: Element) -> Bool {
        guard let frame = SpatialIndex.boundingRect(of: element) else { return false }
        let world = viewport.toWorld(viewPoint)
        let band = Double(Self.connectBandViewWidth) / viewport.scale
        let insideExpanded = Rect(
            x: frame.x - band, y: frame.y - band,
            width: frame.width + band * 2, height: frame.height + band * 2
        ).contains(world)
        let insideCore = Rect(
            x: frame.x + band, y: frame.y + band,
            width: max(frame.width - band * 2, 0), height: max(frame.height - band * 2, 0)
        ).contains(world)
        return insideExpanded && !insideCore
    }

    private func handleDoubleClick(at point: CGPoint) {
        if let hit = editableElement(at: point) {
            selection = [hit.id]
            if hit.edge != nil {
                presentEdgeEditor(for: hit, at: point)
            } else {
                beginLabelEdit(for: hit)
            }
        } else {
            createBlock(at: viewport.toWorld(point))
        }
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        // Single-key tool switching (Excalidraw-style), no modifiers.
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": return activateSelectTool(nil)
            case "d": return activateDrawTool(nil)
            default: break
            }
        }
        if isSimulating, event.keyCode == 53 { // escape exits simulation
            stopSimulation()
            return
        }
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            deleteSelection(nil)
        case 53: // escape
            if case .draw = gesture {
                gesture = .idle // cancel the in-flight stroke
                needsDisplay = true
            } else if tool == .draw {
                tool = .select
            } else {
                selection = []
            }
        case 123, 124, 125, 126: // arrows: ← → ↓ ↑
            let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
            let (dx, dy): (Double, Double) = {
                switch event.keyCode {
                case 123: return (-step, 0)
                case 124: return (step, 0)
                case 125: return (0, step)
                default: return (0, -step)
                }
            }()
            nudgeSelection(dx: dx, dy: dy)
        default:
            super.keyDown(with: event)
        }
    }

    public override func selectAll(_ sender: Any?) {
        selection = Set(board.elements.keys.filter { isEditable(id: $0) })
    }

    @objc public func deleteSelection(_ sender: Any?) {
        guard !selection.isEmpty else { return }
        // Deleting a node keeps its connectors, detached and visibly dangling
        // (they snap back in when a node lands near the free endpoint).
        let doomed = selection.filter { board.elements[$0] != nil }
        let operations = board.deleteDetachingEdges(doomed)
        guard !operations.isEmpty else { return }
        selection = []
        delegate?.canvasView(self, perform: .batch(operations), actionName: "Delete")
    }

    @objc public func addBlock(_ sender: Any?) {
        createBlock(at: viewport.toWorld(CGPoint(x: bounds.midX, y: bounds.midY)))
    }

    @objc public func activateSelectTool(_ sender: Any?) {
        tool = .select
    }

    @objc public func activateDrawTool(_ sender: Any?) {
        tool = .draw
    }

    private func nudgeSelection(dx: Double, dy: Double) {
        let operations = selection.compactMap { id -> BoardOperation? in
            guard var element = board.elements[id],
                  let frame = SpatialIndex.boundingRect(of: element) else { return nil }
            let moved = Rect(x: frame.x + dx, y: frame.y + dy, width: frame.width, height: frame.height)
            guard applyFrame(moved, to: &element) else { return nil }
            return .replaceElement(element)
        }
        guard !operations.isEmpty else { return }
        delegate?.canvasView(self, perform: .batch(operations), actionName: "Move")
    }

    // MARK: Block creation & label editing

    private func createBlock(at world: Point) {
        let layerIDs = activeLayerIDs()
        Self.debugTrace?("createBlock world=\(world) layers=\(layerIDs.count) delegate=\(delegate != nil)")
        guard !layerIDs.isEmpty else { return }
        let frame = Rect(x: world.x - 80, y: world.y - 40, width: 160, height: 80)
        let element = Element(
            layerIDs: layerIDs,
            sortKey: board.topSortKey,
            content: .node(Node(semantic: NodeSemantic(kind: .generic, name: ""), frame: frame))
        )
        delegate?.canvasView(self, perform: .insertElement(element), actionName: "Add Block")
        selection = [element.id]
        if let inserted = board.elements[element.id] {
            beginLabelEdit(for: inserted)
        }
    }

    /// The layer new elements land on: the explicit active layer when it is
    /// usable, otherwise the first visible, unlocked layer.
    private func activeLayerIDs() -> Set<LayerID> {
        if let id = activeLayerID,
           let layer = board.layers.first(where: { $0.id == id }),
           layer.isVisible, !layer.isLocked {
            return [id]
        }
        let usable = board.layers.filter { $0.isVisible && !$0.isLocked }.map(\.id)
        return usable.isEmpty ? [] : [usable[0]]
    }

    /// Draws `body` dimmed when focus mode excludes the element.
    private func withFocusAlpha(_ context: CGContext, dimmed: Bool, _ body: () -> Void) {
        guard dimmed else { return body() }
        context.saveGState()
        context.setAlpha(Self.dimmedAlpha)
        body()
        context.restoreGState()
    }

    func beginLabelEdit(for element: Element) {
        commitLabelEditor()
        guard let frame = SpatialIndex.boundingRect(of: element) else { return }
        guard element.node != nil || isNote(element) else { return }

        let field = NSTextField(string: currentLabel(of: element))
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.alignment = .center
        field.font = .systemFont(ofSize: max(13 * viewport.scale, 9), weight: .medium)
        let viewRect = viewport.toView(frame)
        field.frame = CGRect(
            x: viewRect.minX + 4,
            y: viewRect.midY - 12,
            width: max(viewRect.width - 8, 40),
            height: 24
        )
        field.target = self
        field.action = #selector(labelEditorDidCommit(_:))
        field.delegate = self
        labelEditingUndoManager = UndoManager()
        addSubview(field)
        window?.makeFirstResponder(field)
        labelEditor = field
        editingElementID = element.id
        needsDisplay = true
    }

    @objc private func labelEditorDidCommit(_ sender: NSTextField) {
        commitLabelEditor()
    }

    public func commitLabelEditor() {
        guard let field = labelEditor, let id = editingElementID else { return }
        let text = field.stringValue
        field.removeFromSuperview()
        labelEditor = nil
        editingElementID = nil
        needsDisplay = true
        // Always hand keyboard focus back to the canvas — even when the text
        // didn't change — or shortcuts go dead until the next click.
        window?.makeFirstResponder(self)

        guard var element = board.elements[id], currentLabel(of: element) != text else { return }
        switch element.content {
        case .node(var node):
            node.semantic.name = text
            element.content = .node(node)
        case .note(var note):
            note.text = text
            element.content = .note(note)
        default:
            return
        }
        delegate?.canvasView(self, perform: .replaceElement(element), actionName: "Rename")
    }

    // MARK: Edge editor popover

    private func presentEdgeEditor(for element: Element, at viewPoint: CGPoint) {
        guard let edge = element.edge else { return }
        dismissEdgeEditor()

        edgeEditBaseline = (element.id, edge)
        let editor = EdgeEditorView(values: .init(edge: edge)) { [weak self] values in
            self?.edgeEditCurrent = values
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: editor)
        popover.delegate = self
        popover.show(
            relativeTo: CGRect(x: viewPoint.x - 2, y: viewPoint.y - 2, width: 4, height: 4),
            of: self,
            preferredEdge: .maxY
        )
        edgePopover = popover
    }

    private func dismissEdgeEditor() {
        edgePopover?.close()
        edgePopover = nil
    }

    fileprivate func commitEdgeEditor() {
        defer {
            edgeEditBaseline = nil
            edgeEditCurrent = nil
            edgePopover = nil
        }
        guard
            let baseline = edgeEditBaseline,
            let values = edgeEditCurrent,
            values != EdgeEditorView.Values(edge: baseline.edge),
            var element = board.elements[baseline.id]
        else { return }
        element.content = .edge(values.applied(to: baseline.edge))
        delegate?.canvasView(self, perform: .replaceElement(element), actionName: "Edit Connector")
    }

    private func currentLabel(of element: Element) -> String {
        switch element.content {
        case .node(let node): return node.semantic.name
        case .note(let note): return note.text
        default: return ""
        }
    }

    // MARK: Gesture commit

    private func commitTransientFrames(actionName: String) {
        let frames = transientFrames
        transientFrames = [:]
        let operations = frames.compactMap { id, frame -> BoardOperation? in
            guard var element = board.elements[id] else { return nil }
            guard applyFrame(frame, to: &element) else { return nil }
            return .replaceElement(element)
        }
        guard !operations.isEmpty else {
            needsDisplay = true
            return
        }
        delegate?.canvasView(
            self,
            perform: operations.count == 1 ? operations[0] : .batch(operations),
            actionName: actionName
        )
    }

    private func applyFrame(_ frame: Rect, to element: inout Element) -> Bool {
        switch element.content {
        case .node(var node):
            node.frame = frame
            element.content = .node(node)
            return true
        case .note(var note):
            note.frame = frame
            element.content = .note(note)
            return true
        case .ink, .edge:
            return false // M3 handles ink transforms
        }
    }

    // MARK: Hit testing

    private func editableElement(at viewPoint: CGPoint) -> Element? {
        let world = viewport.toWorld(viewPoint)
        let tolerance = 6 / viewport.scale
        let candidates = spatialIndex
            .query(Rect(
                x: world.x - tolerance, y: world.y - tolerance,
                width: tolerance * 2, height: tolerance * 2
            ))
            .compactMap { board.elements[$0] }
            .filter { isEditable(id: $0.id) }
            .filter { preciseHit($0, world: world, tolerance: tolerance) }
        return candidates.max { ($0.sortKey, $0.id) < ($1.sortKey, $1.id) }
    }

    private func preciseHit(_ element: Element, world: Point, tolerance: Double) -> Bool {
        switch element.content {
        case .node(let node):
            return node.frame.contains(world)
        case .note(let note):
            return note.frame.contains(world)
        case .ink(let ink):
            return ink.points.contains {
                hypot($0.x - world.x, $0.y - world.y) <= tolerance * 2
            }
        case .edge:
            guard let route = routeCache[element.id] else { return false }
            return route.distance(to: world) <= tolerance
        }
    }

    private func isEditable(id: ElementID) -> Bool {
        guard let element = board.elements[id] else { return false }
        // Editable if it belongs to at least one visible, unlocked layer.
        return element.layerIDs.contains { layerID in
            guard let layer = board.layers.first(where: { $0.id == layerID }) else { return false }
            return layer.isVisible && !layer.isLocked
        }
    }

    private func isNote(_ element: Element) -> Bool {
        if case .note = element.content { return true }
        return false
    }

    // MARK: Geometry helpers

    private func singleSelectionViewRect() -> CGRect? {
        guard selection.count == 1,
              let id = selection.first,
              let element = board.elements[id],
              element.node != nil || isNote(element) else { return nil }
        let frame = transientFrames[id]
            ?? SpatialIndex.boundingRect(of: element)
        return frame.map { viewport.toView($0) }
    }

    private func rectFrom(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(a.x - b.x), height: abs(a.y - b.y)
        )
    }

    // MARK: Cursor feedback

    public override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at point: CGPoint?) {
        if tool == .draw {
            NSCursor.crosshair.set()
            return
        }
        guard let point else {
            NSCursor.arrow.set()
            return
        }
        if let handleBox = singleSelectionViewRect(),
           let handle = ResizeHandle.allCases.first(where: {
               $0.rect(around: handleBox).insetBy(dx: -3, dy: -3).contains(point)
           }) {
            handle.cursor.set()
        } else if let hit = editableElement(at: point), hit.node != nil, isInConnectBand(point, of: hit) {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderer.invalidateCaches()
        nodeBatchCache = nil // baked-in resolved colors
        needsDisplay = true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    /// System-managed cursor for the draw tool: survives drags and window
    /// activation (setting NSCursor manually did not, which read as the
    /// cursor "disappearing" during the first stroke).
    public override func resetCursorRects() {
        if tool == .draw {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }
}

extension CanvasView: NSPopoverDelegate {
    public func popoverDidClose(_ notification: Notification) {
        commitEdgeEditor()
    }
}

extension CanvasView: NSTextFieldDelegate {
    /// Keeps the field editor's typing undo out of the document undo stack.
    public func undoManager(for view: NSTextView) -> UndoManager? {
        labelEditingUndoManager
    }
}
