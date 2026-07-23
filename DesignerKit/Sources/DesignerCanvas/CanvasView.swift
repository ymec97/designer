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
            // Undo/redo can delete the element being renamed (a snapped
            // shape reverting to ink) — the floating text box goes with it.
            if let editing = editingElementID, !isLabelEditable(board.elements[editing]) {
                dismissLabelEditorWithoutCommit()
            }
            renderer.sketchy = board.isSketchy
            renderer.captionMode = board.captionMode
            parallelOffsetCache = EdgeGeometry.parallelOffsets(in: board)
            anchorSpreadCache = EdgeGeometry.anchorSpread(in: board)
            routeCache = SpatialIndex.resolveRoutes(for: board)
            spatialIndex = SpatialIndex(board: board, edgeRoutes: routeCache)
            edgeBatchCache = nil
            boardRevision += 1
            // zOrderedElements FIRST — the derived caches below read it.
            zOrderedElements = board.elementsInZOrder
            zOrderIndex = Dictionary(
                uniqueKeysWithValues: zOrderedElements.enumerated().map { ($1.id, $0) })
            inkElementIDs = zOrderedElements.compactMap {
                if case .ink = $0.content { return $0.id }
                return nil
            }
            danglingEdgeIDs = Set(zOrderedElements.compactMap { element in
                guard let edge = element.edge, board.isDangling(edge) else { return nil }
                return element.id
            })
            selection.formIntersection(Set(board.elements.keys))
            captionsDirty = true // routes changed → caption layout must re-solve (B2)
            refreshLabelEditorFontIfEditing() // live text-box size while editing (I3c)
            needsDisplay = true
            // Broken-link validity needs a filesystem scan — never do it inline
            // in the frame path; coalesce it to just after this change (F4).
            DispatchQueue.main.async { [weak self] in self?.refreshBrokenLinks() }
        }
    }

    /// Cached draw order — rebuilt on board changes, never per frame.
    private var zOrderedElements: [Element] = []
    /// id → position in `zOrderedElements` (P8: per-frame culling runs over
    /// a bitmap instead of hashing every element id).
    private var zOrderIndex: [ElementID: Int] = [:]
    /// Resolved edge routes — rebuilt on board changes; only edges touched by
    /// an in-flight drag are re-resolved per frame.
    private var routeCache: [ElementID: EdgeGeometry.Route] = [:]
    /// Perpendicular fan-out for parallel connectors (same node pair), so
    /// drag-time re-resolution matches the cached routes.
    private var parallelOffsetCache: [ElementID: Double] = [:]
    /// Anchor distribution along shared node sides, same drag-time contract.
    private var anchorSpreadCache: [ElementID: EdgeGeometry.EndpointOffsets] = [:]
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
        didSet {
            needsDisplay = true
            if viewport.scale != oldValue.scale {
                viewportScaleChanged?(viewport.scale)
                // Re-solve caption placement only AFTER the zoom settles (B2):
                // debounce so a continuous pinch reuses cached centers.
                scheduleCaptionSettle()
            }
        }
    }

    /// Fires when the zoom level changes (P1: the zoom HUD tracks it).
    public var viewportScaleChanged: ((Double) -> Void)?

    /// True when connector caption placement needs re-solving (B2). Set on
    /// board changes and ~100 ms after a zoom stops; cleared on the solve frame.
    private var captionsDirty = true
    private var captionSettleWork: DispatchWorkItem?

    private func scheduleCaptionSettle() {
        captionSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.captionsDirty = true
            self?.needsDisplay = true
        }
        captionSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
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

    /// Active interaction tool. Select is the default; Draw captures ink;
    /// Shape drags out a block of the given outline (`lockAspect` = the
    /// square/circle picker entries; ⇧ constrains the free ones too).
    public enum Tool: Equatable {
        case select
        case draw
        case shape(NodeShape, lockAspect: Bool)
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

    /// "S" opens the shape PICKER (same as clicking the toolbar button) —
    /// wired by the controller; unset falls back to arming the last shape.
    public var shapePickerRequested: (() -> Void)?

    /// Style applied to the NEXT dragged shape (set by the style panel).
    /// The default is the grouping-outline look the feature exists for:
    /// no background, default stroke.
    // Picker shapes default to the standard node fill (fill == nil resolves to
    // the theme's node background), matching a double-clicked block. Pick the
    // "None" swatch for a hollow grouping-outline shape.
    public var pendingShapeStyle = Style()

    /// Kept in sync by the controller: true when the left style/inspector panel
    /// is showing, so newly-created elements can auto-pan clear of it (B3).
    public var leftPanelIsVisible = false

    /// If `frame`'s on-screen rect underlaps the left style-panel band while a
    /// panel is showing, pan so it clears the band (view x-band ≈ 0…268:
    /// leading 16 + width 236 + 16 gap). Pure view-state — no board mutation,
    /// no undo. No-op when the panel is hidden or the element already clears it.
    private func nudgeClearOfLeftPanel(_ frame: Rect) {
        guard leftPanelIsVisible else { return }
        let band: CGFloat = 268
        let viewRect = viewport.toView(frame)
        guard viewRect.minX < band else { return }
        viewport.pan(viewDeltaX: band + 12 - viewRect.minX, viewDeltaY: 0)
    }
    /// Style applied to NEW ink strokes (pencil settings in the style panel).
    public var pendingInkStyle = Style(strokeWidth: 2)
    /// The shape the shape tool returns to when re-activated via key/palette.
    private var lastShapeChoice: (shape: NodeShape, lockAspect: Bool) = (.rectangle, false)

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

    /// When non-nil, only these elements render at full opacity (flow focus:
    /// "show me just this journey"). Independent of layer focus.
    public var emphasizedElements: Set<ElementID>? {
        didSet {
            guard emphasizedElements != oldValue else { return }
            edgeBatchCache = nil
            nodeBatchCache = nil
            needsDisplay = true
        }
    }

    private func isDimmed(_ element: Element) -> Bool {
        if let emphasized = emphasizedElements, !emphasized.contains(element.id) { return true }
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
        /// Shape tool: dragging out the new shape's frame.
        case shapeDraw(start: CGPoint, current: CGPoint)
        /// Dragging an already-selected connector bends it (P5). `index` is
        /// the JOINT being dragged: an existing waypoint, or (`inserting`)
        /// a new one born on the grabbed segment — connectors carry any
        /// number of joints, each movable on its own.
        case bendEdge(id: ElementID, index: Int, inserting: Bool, start: CGPoint)
        /// Dragging a selected connector BY AN ENDPOINT moves that endpoint:
        /// drop on a block to reattach, drop on canvas to detach (dangling).
        case moveEndpoint(id: ElementID, end: EdgeEndpoint, target: ElementID?)
        /// Space-bar held: drag anywhere to pan (mouse-friendly navigation).
        case spacePan(last: CGPoint)
    }

    enum EdgeEndpoint { case from, to }

    /// True while the space bar is held — the next drag pans the canvas.
    private var isSpacePanHeld = false

    /// Live waypoint list during a `.bendEdge` drag; committed on up.
    private var transientBend: (id: ElementID, waypoints: [Point])?
    /// Live endpoint position during a `.moveEndpoint` drag. `anchor` is the
    /// resolved attachment the endpoint would commit to — a discrete node slot
    /// when hovering a block, else a free (dangling) point.
    private var transientEndpoint: (id: ElementID, end: EdgeEndpoint, point: Point, anchor: DesignerModel.Anchor)?

    /// The connector under the cursor. Tracked only to reveal its caption in
    /// On-Focus mode (hover-to-peek); redraws only when it changes and the
    /// mode cares, so it costs nothing in Always / Off.
    private var hoveredEdgeID: ElementID? {
        didSet {
            guard hoveredEdgeID != oldValue, board.captionMode == .onFocus else { return }
            needsDisplay = true
        }
    }

    /// World-space width of the border band that starts a connection drag
    /// instead of a move (in view pixels, so it feels constant at any zoom).
    private static let connectBandViewWidth: CGFloat = 10

    private var gesture: GestureState = .idle
    private var labelEditor: NSTextField?
    /// Test hook: the on-screen frame of the open label editor (nil = none).
    /// Used by --ui-test to prove the field never blankets the toolbar.
    public var labelEditorFrameForTesting: CGRect? { labelEditor?.frame }
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
            // committed to the board until mouseUp). An agent proposal must
            // ALSO render here — a proposal onto a fresh untitled canvas was
            // invisible until the user drew something.
            if case .draw = gesture {} else if proposalGhost == nil {
                renderer.drawEmptyHint(in: context, bounds: bounds)
            }
            drawLinkBadges(in: context)
            drawProposalGhostOverlay(in: context)
            drawInFlightGesture(in: context)
            drawTransientHint(in: context)
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
        if let bend = transientBend { dragAffectedEdges.insert(bend.id) }
        if let endpoint = transientEndpoint { dragAffectedEdges.insert(endpoint.id) }
        let overrideFrames = transientFrames.isEmpty
            ? nil
            : board.frameProvider(overrides: transientFrames)
        // Live obstacles over the dragged frames so mid-drag routes avoid blocks
        // and match the settled route the drop produces — no more "cross then
        // pop" (B10). Built once per frame, only while a drag is in flight.
        let dragObstacles: ((Rect) -> [Rect])? = transientFrames.isEmpty
            ? nil
            : SpatialIndex.nodeObstacleQuery(for: board, overrides: transientFrames)
        // Routes come from the per-board-revision cache except for the few
        // edges tracking an in-flight drag — resolving 4k routes per frame
        // was the difference between 45ms and 16ms frames at fit zoom.
        let routeFor: (Element) -> EdgeGeometry.Route? = { [routeCache, parallelOffsetCache, anchorSpreadCache, transientBend, transientEndpoint, board] element in
            if let transientBend, transientBend.id == element.id, var edge = element.edge {
                edge.waypoints = transientBend.waypoints
                return EdgeGeometry.route(
                    for: edge, frames: overrideFrames ?? board.frameProvider(),
                    obstacles: dragObstacles)
            }
            if let transientEndpoint, transientEndpoint.id == element.id, var edge = element.edge {
                switch transientEndpoint.end {
                case .from: edge.from = transientEndpoint.anchor
                case .to: edge.to = transientEndpoint.anchor
                }
                return EdgeGeometry.route(
                    for: edge, frames: overrideFrames ?? board.frameProvider(),
                    obstacles: dragObstacles)
            }
            if let overrideFrames, dragAffectedEdges.contains(element.id), let edge = element.edge {
                return EdgeGeometry.route(
                    for: edge, frames: overrideFrames,
                    parallelOffset: parallelOffsetCache[element.id] ?? 0,
                    anchorOffsets: anchorSpreadCache[element.id],
                    obstacles: dragObstacles)
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
                // A live ink move arrives as `frameOverride` (transient bbox);
                // renderer.draw translates the stroke for it (I4/B13).
                withFocusAlpha(context, dimmed: isDimmed(element)) {
                    renderer.draw(
                        element, in: context, viewport: viewport,
                        frameOverride: transientFrames[id],
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

            // Cached z-order; per-frame work is a filter, not a sort. The
            // membership test runs over a Bool bitmap indexed by cached
            // z-position — hashing the visible ids once (P8: hashing every
            // element id per frame was ~3ms of an 8.3ms budget).
            var visibleBitmap = [Bool](repeating: false, count: zOrderedElements.count)
            for id in visibleIDs {
                if let index = zOrderIndex[id] { visibleBitmap[index] = true }
            }
            var drawables: [Element] = []
            drawables.reserveCapacity(min(visibleIDs.count, zOrderedElements.count))
            for (index, element) in zOrderedElements.enumerated()
            where visibleBitmap[index] && isOnVisibleLayer(element) {
                drawables.append(element)
            }
            probe("filter")

            // Elevation shadows only when few nodes are on screen — costly
            // per-node, imperceptible when dense.
            let visibleNodeCount = drawables.reduce(0) { $0 + ($1.node != nil ? 1 : 0) }
            renderer.elevateNodes = visibleNodeCount <= 70

            // Connector captions dodge blocks AND each other; the spatial
            // index answers the pill-rect probes, the renderer's caption
            // pass tracks pill-vs-pill.
            // Only re-solve caption placement on a SETTLED viewport (no camera
            // animation, and the debounce after the last zoom fired) — otherwise
            // reuse cached centers so captions don't jitter mid-zoom (B2).
            let resolveCaptions = captionsDirty && cameraAnimation == nil
            renderer.beginCaptionPass(resolve: resolveCaptions)
            if resolveCaptions { captionsDirty = false }
            let captionObstacles: (Rect) -> [Rect] = { [spatialIndex, board] rect in
                spatialIndex.query(rect).compactMap { board.elements[$0]?.node?.frame }
            }

            for element in drawables {
                withFocusAlpha(context, dimmed: isDimmed(element)) {
                    if let edge = element.edge {
                        if let route = routeFor(element) {
                            // "Focused" for On-Focus captions: selected, part of
                            // the emphasized flow set, or under the cursor.
                            let emphasized = selection.contains(element.id)
                                || (emphasizedElements?.contains(element.id) ?? false)
                                || hoveredEdgeID == element.id
                            renderer.drawEdge(
                                edge, route: route,
                                in: context, viewport: viewport,
                                isSelected: selection.contains(element.id),
                                isDangling: danglingEdgeIDs.contains(element.id),
                                emphasized: emphasized,
                                captionFraction: anchorSpreadCache[element.id]?.captionT ?? 0.5,
                                captionObstacles: captionObstacles,
                                edgeID: element.id
                            )
                        }
                    } else {
                        renderer.draw(
                            element,
                            in: context,
                            viewport: viewport,
                            frameOverride: transientFrames[element.id],
                            isSelected: selection.contains(element.id),
                            suppressText: element.id == editingElementID,
                            dimmed: isDimmed(element)
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

        // Handles on a lone selected connector: one dot per JOINT (drag to
        // move it, drop on the line to remove it), the midpoint dot when the
        // line is still straight (drag to grow the first joint), and the two
        // END grips (drop on a block to reattach, on canvas to detach).
        if selection.count == 1, let id = selection.first,
           let element = board.elements[id], let edge = element.edge,
           let route = routeFor(element) {
            let joints = transientBend?.id == id ? transientBend!.waypoints : edge.waypoints
            if joints.isEmpty {
                renderer.drawBendHandle(at: viewport.toView(route.midpoint), in: context)
            } else {
                for joint in joints {
                    renderer.drawBendHandle(at: viewport.toView(joint), in: context)
                }
            }
            renderer.drawBendHandle(at: viewport.toView(route.start), in: context)
            renderer.drawBendHandle(at: viewport.toView(route.end), in: context)
        }

        for guide in snapGuides {
            renderer.drawSnapGuide(guide, in: context, viewport: viewport)
        }

        drawLinkBadges(in: context)
        drawProposalGhostOverlay(in: context)
        drawSimulationOverlay(in: context)
        drawFlowSourcePickOverlay(in: context)
        drawFlowRecordingOverlay(in: context)
        drawInFlightGesture(in: context)
        drawTransientHint(in: context)
    }

    // MARK: Transient hint

    /// A short-lived caption near a gesture that was absorbed (e.g. a repeat
    /// connection drag), teaching the modifier that would have done more.
    private var transientHint: (text: String, at: CGPoint, expires: Date)?

    func showTransientHint(_ text: String, at point: CGPoint, seconds: TimeInterval = 2.5) {
        transientHint = (text, point, Date().addingTimeInterval(seconds))
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) { [weak self] in
            self?.needsDisplay = true
        }
    }

    private func drawTransientHint(in context: CGContext) {
        guard let hint = transientHint else { return }
        guard hint.expires > Date() else {
            transientHint = nil
            return
        }
        renderer.drawHintCaption(hint.text, at: hint.at, in: context)
    }

    // MARK: Traffic simulation (F2)

    /// One playback timeline: a scripted simulator that starts `start` seconds
    /// into the run, in its own color. A single flow or flood is one track; a
    /// composition is several (serial = staggered starts, parallel = same
    /// start). One clock drives them all.
    private struct SimulationTrack {
        let simulator: TrafficSimulator
        let start: TimeInterval
        let color: NSColor
        let reversedEdges: Set<ElementID>
    }

    private var simulationTracks: [SimulationTrack] = []
    private var simulationTotalDuration: TimeInterval = 0
    private var simulationDisplayLink: CADisplayLink?
    private var simulationClock: TimeInterval = 0   // accumulated simulation seconds
    private var lastSimulationTick: CFTimeInterval = 0
    private var simulationPaused = false

    /// Simulation speed multiplier (1 = normal).
    public var simulationSpeed: Double = 1

    public var isSimulating: Bool { !simulationTracks.isEmpty }
    /// Fires when a simulation starts, pauses/resumes, or ends (so chrome can
    /// show/update the transport). Bool = running (unpaused).
    public var simulationStateChanged: ((_ active: Bool, _ paused: Bool) -> Void)?

    /// Whether the given node can be a simulation source (a node with outgoing
    /// flow), so callers can offer the affordance only when it's meaningful.
    public func canSimulate(from id: ElementID) -> Bool {
        !TrafficSimulation.steps(from: id, in: board).isEmpty
    }

    /// The flow being played back, if any (nil = flood mode or composition).
    public private(set) var playingFlowID: FlowID?
    /// The composition being played back, if any.
    public private(set) var playingCompositionID: FlowCompositionID?
    /// Edges traversed opposite to their storage order, across every running
    /// track (a bidirectional edge walked to→from, or a backward edge): the
    /// packet must fly the traversal direction, not the storage direction.
    public var reversedSimulationEdges: Set<ElementID> {
        simulationTracks.reduce(into: Set<ElementID>()) { $0.formUnion($1.reversedEdges) }
    }

    /// Derives traversal reversal from delivery: an edge whose step delivers
    /// to its *storage-from* endpoint was walked backwards. Loop-closing edges
    /// (delivering to an already-lit node, absent from step.nodes) fall back
    /// to the semantic direction.
    private func reversedEdges(in steps: [TrafficSimulation.Step]) -> Set<ElementID> {
        var reversed: Set<ElementID> = []
        for step in steps {
            let delivered = Set(step.nodes)
            for edgeID in step.edges {
                guard let edge = board.elements[edgeID]?.edge,
                      let from = edge.from.elementID, let to = edge.to.elementID else { continue }
                if delivered.contains(from), !delivered.contains(to) {
                    reversed.insert(edgeID)
                } else if !delivered.contains(from), !delivered.contains(to),
                          edge.semantic.direction == .backward {
                    reversed.insert(edgeID)
                }
            }
        }
        return reversed
    }

    public func startSimulation(from source: ElementID) {
        guard board.elements[source]?.node != nil else { return }
        let steps = TrafficSimulation.steps(from: source, in: board)
        guard !steps.isEmpty else { return }
        playingFlowID = nil
        playingCompositionID = nil
        startTracks([SimulationTrack(
            simulator: TrafficSimulator(source: source, steps: steps),
            start: 0, color: Graphite.accent, reversedEdges: reversedEdges(in: steps)
        )])
    }

    /// Plays a recorded flow: exactly its steps, in its color, skipping any
    /// connectors deleted since recording.
    public func startFlowPlayback(_ flow: Flow) {
        guard board.elements[flow.source]?.node != nil else { return }
        let steps = flow.liveSteps(in: board).map { TrafficSimulation.Step(edges: $0.edges, nodes: $0.nodes) }
        guard !steps.isEmpty else { return }
        cancelFlowRecording()
        playingFlowID = flow.id
        playingCompositionID = nil
        startTracks([SimulationTrack(
            simulator: TrafficSimulator(source: flow.source, steps: steps),
            start: 0,
            color: Graphite.flowColors[flow.colorIndex % Graphite.flowColors.count],
            reversedEdges: reversedEdges(in: steps)
        )])
    }

    /// Plays a composition: each referenced flow becomes its own timed track
    /// (serial groups stagger, parallel groups overlap), all under one clock.
    public func startCompositionPlayback(_ composition: FlowComposition) {
        let schedule = FlowCompositionSchedule.compile(
            composition, in: board,
            edgeDuration: TrafficSimulator.edgeDuration,
            nodeDwell: TrafficSimulator.nodeDwell
        )
        let tracks = schedule.tracks.map { track in
            SimulationTrack(
                simulator: TrafficSimulator(source: track.source, steps: track.steps),
                start: track.start,
                color: Graphite.flowColors[track.colorIndex % Graphite.flowColors.count],
                reversedEdges: reversedEdges(in: track.steps)
            )
        }
        guard !tracks.isEmpty else { return }
        cancelFlowRecording()
        playingFlowID = nil
        playingCompositionID = composition.id
        startTracks(tracks)
    }

    private func startTracks(_ tracks: [SimulationTrack]) {
        simulationTracks = tracks
        simulationTotalDuration = tracks.map { $0.start + $0.simulator.totalDuration }.max() ?? 0
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
        simulationTracks = []
        simulationTotalDuration = 0
        simulationPaused = false
        playingFlowID = nil
        playingCompositionID = nil
        simulationStateChanged?(false, false)
        needsDisplay = true
    }

    @objc private func simulationTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let delta = now - lastSimulationTick
        lastSimulationTick = now
        guard !simulationTracks.isEmpty, !simulationPaused else { return }
        simulationClock += delta * simulationSpeed
        // Loop with a short pause at the end so the run reads as continuous.
        if simulationClock > simulationTotalDuration + 0.9 {
            simulationClock = 0
        }
        needsDisplay = true
    }

    private func drawSimulationOverlay(in context: CGContext) {
        guard !simulationTracks.isEmpty else { return }
        let frames = board.frameProvider(overrides: transientFrames)

        renderer.drawSimulationScrim(bounds, in: context)

        // Each track paints in its own color at its own offset into the clock.
        // A track that hasn't started yet (serial successor) renders nothing —
        // frame(at:0) always lights the source, so the `clock >= start` gate
        // keeps a not-yet-playing flow dark.
        for track in simulationTracks where simulationClock >= track.start {
            let frame = track.simulator.frame(at: simulationClock - track.start)
            let color = track.color

            // Lit edges (done first, then active).
            for edgeID in frame.doneEdges {
                guard let route = routeCache[edgeID] else { continue }
                renderer.drawSimulationEdge(route.points.map { viewport.toView($0) }, in: context, viewport: viewport, active: false, color: color)
            }
            for active in frame.activeEdges {
                guard let route = routeCache[active.id] else { continue }
                renderer.drawSimulationEdge(route.points.map { viewport.toView($0) }, in: context, viewport: viewport, active: true, color: color)
            }

            // Lit nodes with a glow.
            for nodeID in frame.litNodes {
                guard let element = board.elements[nodeID], let node = element.node else { continue }
                let path = nodeGlowPath(for: node, id: nodeID, frames: frames)
                renderer.draw(element, in: context, viewport: viewport, isSelected: false)
                renderer.drawSimulationNodeGlow(path, in: context, viewport: viewport, intensity: 1, color: color)
            }

            // Travelling packets at the head of each active edge, with the
            // edge's condition surfaced while it transits ("only when gRPC").
            // Reversed traversals fly the traversal direction, not storage.
            for active in frame.activeEdges {
                guard let route = routeCache[active.id] else { continue }
                let fraction = track.reversedEdges.contains(active.id) ? 1 - active.progress : active.progress
                let world = route.point(atFraction: fraction)
                let view = viewport.toView(world)
                renderer.drawSimulationPacket(at: view, in: context, viewport: viewport, color: color)
                // The connector a packet is crossing reveals ALL its fields with
                // a colored ring, even when the board caption mode is On-Focus
                // or Off — you always see what's flowing right now.
                if let edge = board.elements[active.id]?.edge {
                    renderer.drawActiveEdgeCaption(edge, route: route, edgeID: active.id,
                                                   color: color, viewport: viewport, in: context)
                }
            }
        }
    }

    // MARK: Agent proposal ghosts (F4)

    /// A staged proposal rendered as ghosts: additions from the proposed
    /// board (dashed accent, translucent), removals marked on the current
    /// board (dashed red outline). Cleared on accept/reject.
    public struct ProposalGhost {
        public let proposedBoard: Board
        public let addedElements: Set<ElementID>
        public let removedElements: Set<ElementID>
        /// Proposed-side ids of elements modified in place (recolor, relabel,
        /// kind/shape/style change) — rendered so an edit is visible in
        /// review, not just adds/removes.
        public let changedElements: Set<ElementID>

        public init(proposedBoard: Board, addedElements: Set<ElementID>,
                    removedElements: Set<ElementID>, changedElements: Set<ElementID> = []) {
            self.proposedBoard = proposedBoard
            self.addedElements = addedElements
            self.removedElements = removedElements
            self.changedElements = changedElements
        }
    }

    public var proposalGhost: ProposalGhost? {
        didSet {
            ghostObstacles = proposalGhost.map { SpatialIndex.nodeObstacleQuery(for: $0.proposedBoard) }
            needsDisplay = true
        }
    }

    /// Node-frame query over the PROPOSED board, so ghost connectors route
    /// around blocks exactly like they will after accepting.
    private var ghostObstacles: ((Rect) -> [Rect])?

    /// World bounds of the ghosted additions (for the reveal camera).
    public func proposalGhostBounds() -> Rect? {
        guard let ghost = proposalGhost else { return nil }
        let frames = ghost.proposedBoard.frameProvider()
        var union: Rect?
        for id in ghost.addedElements {
            guard let element = ghost.proposedBoard.elements[id] else { continue }
            let rect: Rect?
            if let node = element.node {
                rect = node.frame
            } else if let edge = element.edge {
                rect = EdgeGeometry.route(for: edge, frames: frames)?.boundingRect
            } else if case .note(let note) = element.content {
                rect = note.frame
            } else {
                rect = nil
            }
            guard let rect else { continue }
            union = union.map { Self.union($0, rect) } ?? rect
        }
        return union
    }

    private static func union(_ a: Rect, _ b: Rect) -> Rect {
        let minX = min(a.x, b.x), minY = min(a.y, b.y)
        let maxX = max(a.x + a.width, b.x + b.width)
        let maxY = max(a.y + a.height, b.y + b.height)
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Pans/zooms so `worldRect` is comfortably visible (zooming out as
    /// needed, never zooming in past 1×) — used to reveal staged proposals.
    public func reveal(worldRect: Rect) {
        let padded = Rect(
            x: worldRect.x - 120, y: worldRect.y - 120,
            width: worldRect.width + 240, height: worldRect.height + 240
        )
        let visible = viewport.visibleWorldRect(viewSize: bounds.size)
        let contained = padded.x >= visible.x && padded.y >= visible.y
            && padded.x + padded.width <= visible.x + visible.width
            && padded.y + padded.height <= visible.y + visible.height
        guard !contained else { return }
        // Frame the target together with existing content so context is kept.
        var target = padded
        if let content = board.contentBounds() {
            target = Self.union(target, content)
        }
        viewport.fit(target, in: bounds.size, padding: 60)
        if viewport.scale > 1 { // don't zoom IN past 100% for a reveal
            viewport.scale = 1
            viewport.origin = Point(
                x: target.x + target.width / 2 - Double(bounds.width) / 2,
                y: target.y + target.height / 2 - Double(bounds.height) / 2
            )
        }
        needsDisplay = true
    }

    private func drawProposalGhostOverlay(in context: CGContext) {
        guard let ghost = proposalGhost else { return }
        let ghostFrames = ghost.proposedBoard.frameProvider()

        // Removals: red dashed outline + a diagonal ✕ — "this gets deleted".
        for id in ghost.removedElements {
            guard let element = board.elements[id] else { continue }
            if let node = element.node {
                let rect = viewport.toView(node.frame)
                renderer.drawProposalRemovedOutline(rect, in: context, viewport: viewport)
                renderer.drawProposalRemovedStrike(rect, in: context, viewport: viewport)
                renderer.drawGhostBadge(kind: .removed, at: CGPoint(x: rect.minX, y: rect.minY), in: context, viewport: viewport)
            } else if element.edge != nil, let route = routeCache[id] {
                renderer.drawProposalRemovedRoute(route.points.map { viewport.toView($0) }, in: context, viewport: viewport)
            }
        }

        // Additions: translucent content in GREEN dress — green dashed
        // outline + "+" badge on blocks, green dashed routes on connectors.
        context.saveGState()
        context.setAlpha(0.62)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for element in ghost.proposedBoard.elementsInZOrder where ghost.addedElements.contains(element.id) {
            if let edge = element.edge {
                if let route = EdgeGeometry.route(for: edge, frames: ghostFrames, obstacles: ghostObstacles) {
                    renderer.drawProposalAddedRoute(route.points.map { viewport.toView($0) }, in: context, viewport: viewport)
                }
            } else {
                renderer.draw(element, in: context, viewport: viewport, isSelected: false)
                if let node = element.node {
                    renderer.drawProposalAddedOutline(
                        viewport.toView(node.frame), in: context, viewport: viewport,
                        color: Graphite.proposalAdd)
                }
            }
        }
        context.endTransparencyLayer()
        context.restoreGState()

        // Modifications: render the element's PROPOSED appearance in place
        // (so a recolor/relabel/restyle is visible in review, not just
        // adds/removes) under an amber "changed" ring.
        for element in ghost.proposedBoard.elementsInZOrder where ghost.changedElements.contains(element.id) {
            if let edge = element.edge {
                if let route = EdgeGeometry.route(for: edge, frames: ghostFrames, obstacles: ghostObstacles) {
                    let pts = route.points.map { viewport.toView($0) }
                    renderer.drawEdge(edge, route: route, in: context, viewport: viewport, isSelected: false)
                    renderer.drawProposalChangedRoute(pts, in: context, viewport: viewport)
                }
            } else if let node = element.node {
                renderer.draw(element, in: context, viewport: viewport, isSelected: false)
                renderer.drawProposalChangedOutline(viewport.toView(node.frame), in: context, viewport: viewport)
            }
        }

        // Badges above everything so they read at full strength.
        for id in ghost.addedElements {
            guard let node = ghost.proposedBoard.elements[id]?.node else { continue }
            let rect = viewport.toView(node.frame)
            renderer.drawGhostBadge(kind: .added, at: CGPoint(x: rect.minX, y: rect.minY), in: context, viewport: viewport)
        }
        for id in ghost.changedElements {
            guard let node = ghost.proposedBoard.elements[id]?.node else { continue }
            let rect = viewport.toView(node.frame)
            renderer.drawGhostBadge(kind: .changed, at: CGPoint(x: rect.minX, y: rect.minY), in: context, viewport: viewport)
        }
    }

    // MARK: Linked boards (drill-down)

    /// Fired when the user activates a node's board link (double-clicking
    /// the badge, or the context menu's Go to Board). The controller owns
    /// navigation; the canvas only detects the gesture.
    public var linkActivated: ((ElementID) -> Void)?

    /// The controller supplies the right-click menu for a node (linking
    /// actions live there); nil falls through to no menu.
    public var nodeContextMenu: ((ElementID) -> NSMenu?)?

    /// Linked-board view mode: the canvas shows a foreign board read-only —
    /// navigation (pan/zoom/select) works, mutations don't start.
    public var isReadOnly = false {
        didSet {
            guard isReadOnly != oldValue else { return }
            if isReadOnly {
                commitLabelEditor()
                tool = .select
                gesture = .idle
            }
            needsDisplay = true
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard !isReadOnly else { return nil }
        if let badgeNode = linkBadgeHit(at: point) {
            return nodeContextMenu?(badgeNode)
        }
        guard let element = editableNode(at: point), element.node != nil else {
            return super.menu(for: event)
        }
        // Right-click selects the node it targets (platform convention).
        if !selection.contains(element.id) {
            selection = [element.id]
        }
        return nodeContextMenu?(element.id)
    }

    // MARK: Animated camera (linked-board zoom)

    private var cameraAnimation: (start: CanvasViewport, target: CanvasViewport,
                                  startTime: TimeInterval, duration: TimeInterval,
                                  anchorWorld: Point?, completion: (() -> Void)?)?
    private var cameraTimer: Timer?

    /// Glides the camera to `target` (ease-in-out; scale lerped in log space
    /// so zooming feels linear). Completion fires exactly at the target. When
    /// `anchorWorld` is given, that world point's on-screen position is
    /// interpolated directly, so the motion zooms INTO it (used for the
    /// linked-board dive, so it doesn't drift to the viewport middle first).
    public func animateViewport(to target: CanvasViewport, duration: TimeInterval = 0.32,
                                anchorWorld: CGPoint? = nil,
                                completion: (() -> Void)? = nil) {
        cameraTimer?.invalidate()
        guard duration > 0.01 else {
            viewport = target
            completion?()
            return
        }
        let anchor = anchorWorld.map { Point(x: Double($0.x), y: Double($0.y)) }
        cameraAnimation = (viewport, target, CACurrentMediaTime(), duration, anchor, completion)
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            guard let self, let animation = self.cameraAnimation else {
                timer.invalidate()
                return
            }
            let raw = (CACurrentMediaTime() - animation.startTime) / animation.duration
            let t = min(max(raw, 0), 1)
            // Ease in-out.
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let logStart = log(animation.start.scale), logEnd = log(animation.target.scale)
            let scale = exp(logStart + (logEnd - logStart) * eased)
            let origin: Point
            if let anchor = animation.anchorWorld {
                // Keep the anchor's screen position moving smoothly from its
                // start mapping to its target mapping, so the zoom homes in on
                // the node instead of the camera sliding after a center zoom.
                let startScreen = animation.start.toView(anchor)
                let endScreen = animation.target.toView(anchor)
                let screenX = startScreen.x + (endScreen.x - startScreen.x) * eased
                let screenY = startScreen.y + (endScreen.y - startScreen.y) * eased
                origin = Point(x: anchor.x - Double(screenX) / scale,
                               y: anchor.y - Double(screenY) / scale)
            } else {
                origin = Point(
                    x: animation.start.origin.x + (animation.target.origin.x - animation.start.origin.x) * eased,
                    y: animation.start.origin.y + (animation.target.origin.y - animation.start.origin.y) * eased
                )
            }
            self.viewport = CanvasViewport(origin: origin, scale: scale)
            if t >= 1 {
                timer.invalidate()
                self.cameraTimer = nil
                let done = animation.completion
                self.cameraAnimation = nil
                self.viewport = animation.target
                self.captionsDirty = true // re-solve captions now the camera settled (B2)
                done?()
            }
        }
        cameraTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The view-space rect of a linked node's badge — top-right, OUTSIDE the
    /// frame so even tiny nodes wear it without covering their label.
    public func linkBadgeRect(forNodeFrame frame: Rect) -> CGRect {
        let rect = viewport.toView(frame)
        let radius = max(7 * viewport.scale, 6)
        return CGRect(x: rect.maxX + 2, y: rect.minY - radius * 2 - 2,
                      width: radius * 2, height: radius * 2)
    }

    /// The linked node whose badge contains the view-space point, if any.
    public func linkBadgeHit(at point: CGPoint) -> ElementID? {
        for element in zOrderedElements.reversed() {
            guard let node = element.node, node.semantic.linkedBoardID != nil else { continue }
            if linkBadgeRect(forNodeFrame: node.frame).insetBy(dx: -3, dy: -3).contains(point) {
                return element.id
            }
        }
        return nil
    }

    private func drawLinkBadges(in context: CGContext) {
        let hiddenLayers = Set(board.layers.filter { !$0.isVisible }.map(\.id))
        for element in zOrderedElements {
            guard let node = element.node, node.semantic.linkedBoardID != nil,
                  element.layerIDs.contains(where: { !hiddenLayers.contains($0) }) else { continue }
            renderer.drawLinkBadge(in: linkBadgeRect(forNodeFrame: node.frame),
                                   broken: brokenLinkIDs.contains(element.id), context: context)
        }
    }

    // MARK: Broken board links (F4)

    /// Nodes whose linked board can't be resolved to a file. Recomputed off the
    /// hot path (never per frame — resolution is a filesystem scan).
    public private(set) var brokenLinkIDs: Set<ElementID> = []
    /// Injected by the controller so the canvas needn't depend on BoardCatalog.
    public var resolveLinkValidity: ((BoardID) -> Bool)?
    /// Fires when the hovered broken-link badge changes (id, its view rect).
    public var brokenLinkHoverChanged: ((ElementID?, CGRect) -> Void)?
    /// Fires when a broken link's badge is clicked (explain instead of navigate).
    public var brokenLinkActivated: ((ElementID) -> Void)?
    private var hoveredBrokenLink: ElementID?

    /// Re-resolve every link's validity. Runs the filesystem scan ONCE,
    /// deduped by board id — call from board changes (async), window focus,
    /// or catalog-change notifications, never per frame.
    public func refreshBrokenLinks() {
        guard let resolve = resolveLinkValidity else {
            if !brokenLinkIDs.isEmpty { brokenLinkIDs = []; needsDisplay = true }
            return
        }
        var broken: Set<ElementID> = []
        var cache: [BoardID: Bool] = [:]
        for element in zOrderedElements {
            guard let linkID = element.node?.semantic.linkedBoardID else { continue }
            let ok: Bool
            if let cached = cache[linkID] { ok = cached }
            else { ok = resolve(linkID); cache[linkID] = ok }
            if !ok { broken.insert(element.id) }
        }
        if broken != brokenLinkIDs { brokenLinkIDs = broken; needsDisplay = true }
    }

    /// Broken-link hover hit-test — call from mouseMoved. Cheap: only iterates
    /// the (usually empty) broken set.
    private func updateBrokenLinkHover(at point: CGPoint) {
        let hit = brokenLinkIDs.first { id in
            guard let frame = board.elements[id]?.node?.frame else { return false }
            return linkBadgeRect(forNodeFrame: frame).insetBy(dx: -3, dy: -3).contains(point)
        }
        guard hit != hoveredBrokenLink else { return }
        hoveredBrokenLink = hit
        let rect = hit.flatMap { board.elements[$0]?.node?.frame }
            .map { linkBadgeRect(forNodeFrame: $0) } ?? .zero
        brokenLinkHoverChanged?(hit, rect)
    }

    // MARK: Flow recording (F5)

    public private(set) var flowRecorder: FlowRecorder?
    public var isRecordingFlow: Bool { flowRecorder != nil }
    /// Fires when recording starts/advances/ends. `connectors` = clicks so far.
    public var flowRecordingChanged: ((_ active: Bool, _ connectors: Int) -> Void)?
    /// Pending candidates when a click was ambiguous (parallel edges); the
    /// chooser menu resolves into `recordFlowCandidate`.
    private var pendingFlowChoices: [FlowRecorder.Candidate] = []

    /// True while we're waiting for the user to click the source block (F10):
    /// Record with nothing selected drops straight into the dimmed recording
    /// canvas and lets them pick the starting block, instead of an alert.
    public private(set) var isPickingFlowSource = false

    @discardableResult
    public func startFlowRecording(from source: ElementID) -> Bool {
        guard board.elements[source]?.node != nil else { return false }
        stopSimulation()
        commitLabelEditor()
        isPickingFlowSource = false
        flowRecorder = FlowRecorder(source: source)
        select([])
        flowRecordingChanged?(true, 0)
        needsDisplay = true
        return true
    }

    /// Enter the "pick a source block" step (F10): dim the canvas like a live
    /// recording and wait for the first block click to become the source.
    public func beginFlowSourcePick() {
        stopSimulation()
        commitLabelEditor()
        select([])
        isPickingFlowSource = true
        flowRecordingChanged?(true, 0)
        needsDisplay = true
    }

    public func cancelFlowSourcePick() {
        guard isPickingFlowSource else { return }
        isPickingFlowSource = false
        flowRecordingChanged?(false, 0)
        needsDisplay = true
    }

    public func cancelFlowRecording() {
        guard flowRecorder != nil else { return }
        flowRecorder = nil
        pendingFlowChoices = []
        flowRecordingChanged?(false, 0)
        needsDisplay = true
    }

    /// Ends recording and returns the recorder for the app layer to name and
    /// persist (nil when nothing was recorded).
    public func finishFlowRecording() -> FlowRecorder? {
        guard let recorder = flowRecorder else { return nil }
        flowRecorder = nil
        pendingFlowChoices = []
        flowRecordingChanged?(false, 0)
        needsDisplay = true
        return recorder.isEmpty ? nil : recorder
    }

    public func undoLastFlowConnector() {
        guard var recorder = flowRecorder else { return }
        recorder.undoLast()
        flowRecorder = recorder
        flowRecordingChanged?(true, recorder.recordedEdges.count)
        needsDisplay = true
    }

    /// Recording must not lead the user to blocks the layer settings hide —
    /// clicking one looked like the canvas "generating new nodes".
    private func isRecordable(_ candidate: FlowRecorder.Candidate) -> Bool {
        let hidden = Set(board.layers.filter { !$0.isVisible }.map(\.id))
        func visible(_ id: ElementID) -> Bool {
            guard let element = board.elements[id] else { return false }
            return element.layerIDs.contains { !hidden.contains($0) }
        }
        // Both the connector and the block it delivers to must be on a visible
        // layer, and so must the origin — an element hidden by its layer must
        // never appear as an advancement option, even across layers (F13).
        return visible(candidate.from) && visible(candidate.edge) && visible(candidate.to)
    }

    /// A click while recording. The primary gesture is clicking the NEXT
    /// BLOCK the traffic visits — the walk continues from the CURSOR (the
    /// last clicked block): B, A, C records B→A then A→C, never a second
    /// departure from B. Clicking a reached block moves the cursor there
    /// (fan-out); clicking a connector directly still works as a fallback.
    private func handleFlowRecordingClick(at point: CGPoint, event: NSEvent) {
        guard let recorder = flowRecorder else { return }
        let world = viewport.toWorld(point)

        // 1. Did the click land on a block?
        if let nodeID = board.elementsInZOrder.reversed().first(where: { element in
            element.node?.frame.contains(world) == true
        })?.id {
            let choices = recorder.preferredCandidates(to: nodeID, in: board).filter(isRecordable)
            let continuesFromCursor = choices.first?.from == recorder.cursor
            // A reached block is a cursor move (fan-out) — unless the cursor
            // itself delivers here, which is an intentional cycle hop.
            if recorder.reachedNodes.contains(nodeID), !continuesFromCursor {
                var moved = recorder
                if moved.moveCursor(to: nodeID) {
                    flowRecorder = moved
                    needsDisplay = true
                }
                return
            }
            if !choices.isEmpty {
                resolveFlowChoices(choices, event: event)
                return
            }
        }

        // 2. Fallback: a click near a candidate connector.
        let tolerance = 14 / viewport.scale
        var hits: [(candidate: FlowRecorder.Candidate, distance: Double)] = []
        for candidate in recorder.candidates(in: board) where isRecordable(candidate) {
            guard let route = routeCache[candidate.edge] else { continue }
            let distance = route.distance(to: world)
            if distance < Double(tolerance) { hits.append((candidate, distance)) }
        }
        hits.sort { $0.distance < $1.distance }
        resolveFlowChoices(hits.map(\.candidate), event: event)
    }

    /// Records the single choice, or pops the connector chooser for several.
    private func resolveFlowChoices(_ choices: [FlowRecorder.Candidate], event: NSEvent) {
        switch choices.count {
        case 0:
            return
        case 1:
            recordFlowCandidateNow(choices[0])
        default:
            pendingFlowChoices = choices
            let menu = NSMenu()
            for (index, choice) in pendingFlowChoices.enumerated() {
                let item = NSMenuItem(title: flowCandidateTitle(choice),
                                      action: #selector(flowChoiceSelected(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    @objc private func flowChoiceSelected(_ sender: NSMenuItem) {
        guard pendingFlowChoices.indices.contains(sender.tag) else { return }
        recordFlowCandidateNow(pendingFlowChoices[sender.tag])
        pendingFlowChoices = []
    }

    /// Records one hop programmatically — what clicking its target block
    /// does. Used by self-tests and the scripted demo driver.
    public func recordFlowCandidate(_ candidate: FlowRecorder.Candidate) {
        recordFlowCandidateNow(candidate)
    }

    private func recordFlowCandidateNow(_ candidate: FlowRecorder.Candidate) {
        guard var recorder = flowRecorder else { return }
        guard recorder.record(candidate, in: board) else { return }
        flowRecorder = recorder
        flowRecordingChanged?(true, recorder.recordedEdges.count)
        needsDisplay = true
    }

    private func flowCandidateTitle(_ candidate: FlowRecorder.Candidate) -> String {
        func name(_ id: ElementID) -> String {
            let n = board.elements[id]?.node?.semantic.name ?? ""
            return n.isEmpty ? "untitled" : n
        }
        var parts: [String] = []
        if let edge = board.elements[candidate.edge]?.edge {
            if let label = edge.semantic.label, !label.isEmpty { parts.append(label) }
            if let proto = edge.semantic.properties[WellKnownEdgeProperty.protocolKey], !proto.isEmpty {
                parts.append(proto)
            }
        }
        let detail = parts.isEmpty ? "connector" : parts.joined(separator: " · ")
        return "\(name(candidate.from)) → \(name(candidate.to))  (\(detail))"
    }

    /// Recording overlay: scrim dims everything unreachable; the recorded
    /// path glows in accent; the blocks you can click NEXT re-render normally
    /// with a dashed accent ring, their connectors drawn as usual — so the
    /// choice reads as "which block does the traffic visit next".
    private func drawFlowSourcePickOverlay(in context: CGContext) {
        guard isPickingFlowSource else { return }
        renderer.drawSimulationScrim(bounds, in: context)
        let hidden = Set(board.layers.filter { !$0.isVisible }.map(\.id))
        // Lift every visible block above the scrim so the user can see what to
        // click for the source.
        for element in board.elementsInZOrder {
            guard element.node != nil,
                  element.layerIDs.contains(where: { !hidden.contains($0) }) else { continue }
            renderer.draw(element, in: context, viewport: viewport, isSelected: false)
        }
        renderer.drawHintCaption("Click the block the traffic starts from",
                                 at: CGPoint(x: bounds.midX, y: 40), in: context)
    }

    private func drawFlowRecordingOverlay(in context: CGContext) {
        guard let recorder = flowRecorder else { return }
        let frames = board.frameProvider(overrides: transientFrames)

        renderer.drawSimulationScrim(bounds, in: context)

        // The journey so far.
        for step in recorder.steps {
            for edgeID in step.edges {
                guard let route = routeCache[edgeID] else { continue }
                renderer.drawSimulationEdge(route.points.map { viewport.toView($0) }, in: context, viewport: viewport, active: false)
            }
        }

        // Connectors that could carry the next hop: their regular rendering,
        // lifted above the scrim (arrowheads and labels intact). Hidden
        // layers stay hidden — recording never reveals them.
        for candidate in recorder.candidates(in: board) where isRecordable(candidate) {
            guard let element = board.elements[candidate.edge], let edge = element.edge,
                  let route = routeCache[candidate.edge] else { continue }
            renderer.drawEdge(edge, route: route, in: context, viewport: viewport, isSelected: false,
                              captionFraction: anchorSpreadCache[candidate.edge]?.captionT ?? 0.5)
        }

        // Reached blocks: soft glow, with the CURSOR (where the walk stands,
        // where the next hop departs from) glowing strongest. Candidate next
        // blocks: normal render + dashed accent ring = "click me".
        for nodeID in recorder.reachedNodes {
            guard let element = board.elements[nodeID], let node = element.node else { continue }
            let path = nodeGlowPath(for: node, id: nodeID, frames: frames)
            renderer.draw(element, in: context, viewport: viewport, isSelected: false)
            renderer.drawSimulationNodeGlow(
                path, in: context, viewport: viewport,
                intensity: nodeID == recorder.cursor ? 1.0 : 0.45
            )
        }
        let recordableTargets = Set(recorder.candidates(in: board).filter(isRecordable).map(\.to))
        for nodeID in recordableTargets where !recorder.reachedNodes.contains(nodeID) {
            guard let element = board.elements[nodeID], let node = element.node else { continue }
            renderer.draw(element, in: context, viewport: viewport, isSelected: false)
            renderer.drawProposalAddedOutline(viewport.toView(node.frame), in: context, viewport: viewport)
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
                Ink(points: points, style: pendingInkStyle),
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

        case .moveEndpoint(_, _, let target):
            if let target, let frame = board.frameProvider(overrides: transientFrames)(target) {
                renderer.highlightConnectTarget(viewport.toView(frame), in: context)
                // Show the discrete slots the endpoint can snap to, with the
                // one it would land on highlighted.
                let slots = EdgeGeometry.anchorSlots(for: frame)
                var selected: Int?
                if case .element(_, let side, let offset)? = transientEndpoint?.anchor {
                    selected = slots.firstIndex { $0.side == side && $0.offset == offset }
                }
                renderer.drawAnchorSlots(
                    slots.map { viewport.toView($0.point) }, selected: selected, in: context)
            }

        case .shapeDraw(let start, let current):
            if case .shape(let shape, _) = tool {
                let band = rectFrom(start, current)
                guard band.width >= 2 || band.height >= 2 else { break }
                let world = Rect(
                    x: viewport.toWorld(band.origin).x,
                    y: viewport.toWorld(band.origin).y,
                    width: Double(band.width) / viewport.scale,
                    height: Double(band.height) / viewport.scale
                )
                // Live preview: the actual node render at reduced alpha, so
                // what you drop is exactly what you saw.
                var preview = pendingShapeStyle
                preview.opacity = (preview.opacity ?? 1) * 0.65
                let ghost = Element(
                    layerIDs: [board.layers[0].id], sortKey: board.topSortKey,
                    content: .node(Node(semantic: NodeSemantic(name: ""),
                                        frame: world, shape: shape, style: preview))
                )
                renderer.draw(ghost, in: context, viewport: viewport, isSelected: false)
            }

        default:
            break
        }
    }

    // MARK: Navigation input

    public override func scrollWheel(with event: NSEvent) {
        // A mouse WHEEL zooms toward the cursor (there is no other fluid way
        // to zoom with a mouse); trackpad scrolling pans as before, with
        // ⌘-scroll forcing zoom on either device.
        let wheelZoom = !event.hasPreciseScrollingDeltas
        if wheelZoom || event.modifierFlags.contains(.command) {
            let exponent = event.hasPreciseScrollingDeltas ? 1.0015 : 1.06
            let factor = pow(exponent, Double(event.scrollingDeltaY))
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
        if isSpacePanHeld {
            gesture = .spacePan(last: convert(event.locationInWindow, from: nil))
            NSCursor.closedHand.set()
            return
        }
        // Simulation is a read-only mode; ignore edit gestures (pan/zoom still
        // work via scroll/pinch). The transport controls it.
        if isSimulating { return }
        if isPickingFlowSource {
            let world = viewport.toWorld(convert(event.locationInWindow, from: nil))
            if let nodeID = board.elementsInZOrder.reversed().first(where: {
                $0.node?.frame.contains(world) == true && isEditable(id: $0.id)
            })?.id {
                _ = startFlowRecording(from: nodeID) // clears the pick flag
            }
            return // clicks on empty canvas just wait for a valid block
        }
        if isRecordingFlow {
            handleFlowRecordingClick(at: convert(event.locationInWindow, from: nil), event: event)
            return
        }
        commitLabelEditor()
        let point = convert(event.locationInWindow, from: nil)

        // Linked-board view: navigation + selection only. The badge still
        // works (nested links show the depth affordance), everything that
        // would mutate is cut off before it starts.
        if isReadOnly {
            if event.clickCount == 2, let linked = linkBadgeHit(at: point) {
                if brokenLinkIDs.contains(linked) { brokenLinkActivated?(linked); return }
                linkActivated?(linked)
                return
            }
            let hit = editableElement(at: point)
            if let hit, !event.modifierFlags.contains(.shift) {
                selection = board.expandSelectionToGroups([hit.id])
            } else if hit == nil {
                selection = []
            }
            gesture = .idle
            return
        }

        if tool == .draw {
            gesture = .draw(
                points: [strokePoint(from: event, at: point, since: event.timestamp)],
                startedAt: event.timestamp
            )
            return
        }

        if case .shape = tool {
            gesture = .shapeDraw(start: point, current: point)
            return
        }

        if event.clickCount == 2 {
            Self.debugTrace?("doubleClick at view=\(point)")
            // The link badge sits OUTSIDE node frames — check it explicitly
            // before normal double-click handling (label edit / create).
            if let linked = linkBadgeHit(at: point) {
                if brokenLinkIDs.contains(linked) { brokenLinkActivated?(linked); return }
                linkActivated?(linked)
                return
            }
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

        // The END GRIPS of a lone selected connector win over everything —
        // they sit ON node borders, where the connect band would otherwise
        // swallow the drag. Grabbing one moves that endpoint: drop on a
        // block to reattach, drop on canvas to detach.
        if selection.count == 1, let selectedID = selection.first,
           board.elements[selectedID]?.edge != nil,
           !event.modifierFlags.contains(.shift),
           let route = routeCache[selectedID] {
            let grabRadius: CGFloat = 12
            let startView = viewport.toView(route.start)
            let endView = viewport.toView(route.end)
            if hypot(point.x - startView.x, point.y - startView.y) < grabRadius {
                gesture = .moveEndpoint(id: selectedID, end: .from, target: nil)
                return
            }
            if hypot(point.x - endView.x, point.y - endView.y) < grabRadius {
                gesture = .moveEndpoint(id: selectedID, end: .to, target: nil)
                return
            }
            // An existing JOINT under the cursor drags on its own — grips
            // beat everything, wherever the joint happens to sit.
            if let edge = board.elements[selectedID]?.edge,
               let jointIndex = edge.waypoints.firstIndex(where: { waypoint in
                   let view = viewport.toView(waypoint)
                   return hypot(point.x - view.x, point.y - view.y) < grabRadius
               }) {
                gesture = .bendEdge(id: selectedID, index: jointIndex, inserting: false, start: point)
                return
            }
        }

        let hit = editableElement(at: point)

        // Starting a drag from a node's border band creates a connection.
        // The band wins even when a connector lies on top of the border
        // (its anchor sits exactly there — the just-created connector would
        // otherwise swallow the next connection drag as a bend/selection).
        // BUT only for FILLED / image nodes: a no-fill node (a grouping
        // outline) is hittable ONLY on its border, so if the connect band
        // claimed it there'd be no way to select or move it — its border must
        // select/move instead (I1). Real connections start from solid blocks.
        let bandNode = (hit?.node != nil ? hit : editableNode(at: point))
        let bandNodeConnectable = bandNode?.node.map { $0.style.hasFill || $0.style.image != nil } ?? false
        if let bandNode, bandNodeConnectable, !event.modifierFlags.contains(.shift),
           isInConnectBand(point, of: bandNode) {
            gesture = .connect(from: bandNode.id, current: point, target: nil)
            return
        }

        // Dragging a connector that is already the (sole) selection bends it:
        // grabbing a segment grows a NEW joint there and drags it; dropping
        // a joint back on the line between its neighbors removes it (P5).
        if let hit, let edge = hit.edge, selection == [hit.id],
           !event.modifierFlags.contains(.shift) {
            let world = viewport.toWorld(point)
            var insertAt = edge.waypoints.count
            if let route = routeCache[hit.id], !edge.waypoints.isEmpty {
                // Which segment of start → joints → end was grabbed?
                let vertices = [route.start] + edge.waypoints + [route.end]
                var best = Double.greatestFiniteMagnitude
                for i in 0..<(vertices.count - 1) {
                    let d = EdgeGeometry.Route.segmentDistance(world, vertices[i], vertices[i + 1])
                    if d < best { best = d; insertAt = i }
                }
            } else {
                insertAt = 0
            }
            gesture = .bendEdge(id: hit.id, index: insertAt, inserting: true, start: point)
            return
        }

        if let hit {
            if event.modifierFlags.contains(.shift) {
                if selection.contains(hit.id) {
                    selection.subtract(board.expandSelectionToGroups([hit.id]))
                } else {
                    selection.formUnion(board.expandSelectionToGroups([hit.id]))
                }
            } else if !selection.contains(hit.id) {
                // Clicking a group member selects the whole group.
                selection = board.expandSelectionToGroups([hit.id])
            }
        } else if !event.modifierFlags.contains(.shift) {
            selection = []
        }
        gesture = .mouseDown(at: point, on: hit?.id, hadSelection: hit != nil)
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch gesture {
        case .spacePan(let last):
            viewport.pan(viewDeltaX: point.x - last.x, viewDeltaY: point.y - last.y)
            gesture = .spacePan(last: point)

        case .bendEdge(let id, let index, let inserting, let start):
            let distance = hypot(point.x - start.x, point.y - start.y)
            guard distance > 3 || transientBend != nil else { return }
            // Rebuild from the (unchanged) board each event: idempotent.
            var waypoints = board.elements[id]?.edge?.waypoints ?? []
            let world = viewport.toWorld(point)
            if inserting {
                waypoints.insert(world, at: min(index, waypoints.count))
            } else if waypoints.indices.contains(index) {
                waypoints[index] = world
            }
            transientBend = (id, waypoints)
            needsDisplay = true

        case .moveEndpoint(let id, let end, let previousTarget):
            let world = viewport.toWorld(point)
            // Highlight the block the endpoint would attach to — anywhere on
            // the other end's block means "cancel", not a self-loop.
            let otherEnd = board.elements[id]?.edge.map { end == .from ? $0.to : $0.from }
            // Fill-aware hit (like the new-connection drag): a no-fill grouping
            // rectangle is hollow, so its big frame no longer magnetizes the
            // endpoint — you snap to real blocks, not the group outline (I5).
            let hit = editableElement(at: point)
            var candidate: ElementID? = hit?.node != nil ? hit?.id : nil
            // Hysteresis: if we've drifted just off the previously targeted
            // SOLID block, keep it rather than thrashing to nothing/another as
            // the cursor moves a little (I5). A fresh solid hit always wins.
            if candidate == nil, let previousTarget,
               let node = board.elements[previousTarget]?.node,
               node.style.hasFill || node.style.image != nil {
                let margin = 14 / viewport.scale
                let f = node.frame
                let expanded = Rect(x: f.x - margin, y: f.y - margin,
                                    width: f.width + margin * 2, height: f.height + margin * 2)
                if expanded.contains(world) { candidate = previousTarget }
            }
            let targetID = candidate == otherEnd?.elementID ? nil : candidate
            // Over a block: snap to its nearest discrete anchor slot so the
            // endpoint jumps between fixed points. Off a block: dangle free.
            let anchor = endpointAnchor(forTarget: targetID, droppedAt: world)
            transientEndpoint = (id, end, world, anchor)
            gesture = .moveEndpoint(id: id, end: end, target: targetID)
            needsDisplay = true

        case .mouseDown(let start, let hitID, _):
            let distance = hypot(point.x - start.x, point.y - start.y)
            guard distance > 3 else { return }
            if hitID != nil, !selection.isEmpty {
                var originals: [ElementID: Rect] = [:]
                for id in selection {
                    if let element = board.elements[id] {
                        let movable = element.node != nil || isNote(element) || element.boundary != nil
                        let isInk = { if case .ink = element.content { return true }; return false }()
                        if movable || isInk {
                            originals[id] = SpatialIndex.boundingRect(of: element)
                        }
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
            var resized = handle.resize(
                original,
                byWorldDelta: world.x - startWorld.x, world.y - startWorld.y
            )
            // Alignment snapping for the moving edges (suppressed while ⌘ is
            // held), showing the same red guides as a move.
            snapGuides = []
            if !event.modifierFlags.contains(.command) {
                let others = snapCandidates(excluding: [id])
                let snap = SnapEngine.snapResize(
                    frame: resized, original: original, others: others,
                    threshold: 7 / viewport.scale)
                resized = snap.frame
                snapGuides = snap.guides
            }
            transientFrames[id] = resized
            needsDisplay = true

        case .rubberBand(let start, _):
            gesture = .rubberBand(start: start, current: point)
            needsDisplay = true

        case .shapeDraw(let start, _):
            gesture = .shapeDraw(
                start: start,
                current: constrainedShapePoint(from: start, to: point, shiftHeld: event.modifierFlags.contains(.shift))
            )
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
            // The spatial index answers by bounding box; a connector's box
            // spans both endpoints, so it can overlap the band while the actual
            // line is nowhere near it. Require the route to truly cross the band
            // for edges — nodes/ink keep partial-overlap selection (intentional).
            let candidates = spatialIndex.query(worldBand).filter { isEditable(id: $0) }
            let precise = candidates.filter { id in
                guard board.elements[id]?.edge != nil else { return true }
                guard let route = routeCache[id] else { return false }
                return EdgeGeometry.route(route, intersects: worldBand)
            }
            let hitIDs = board.expandSelectionToGroups(precise)
            if event.modifierFlags.contains(.shift) {
                selection.formUnion(hitIDs)
            } else {
                selection = hitIDs
            }
            needsDisplay = true

        case .shapeDraw(let start, let current):
            guard case .shape(let shape, _) = tool else { break }
            let band = rectFrom(start, current)
            let world: Rect
            if band.width < 4, band.height < 4 {
                // A bare click drops a default-size shape centered there,
                // zoom-normalized like block insertion.
                let scaled = 160.0 * creationScaleFactor()
                let height = (shape == .rectangle ? 80.0 : 120.0) * creationScaleFactor()
                let center = viewport.toWorld(start)
                world = Rect(x: center.x - scaled / 2, y: center.y - height / 2,
                             width: scaled, height: height)
            } else {
                world = Rect(
                    x: viewport.toWorld(band.origin).x,
                    y: viewport.toWorld(band.origin).y,
                    width: Double(band.width) / viewport.scale,
                    height: Double(band.height) / viewport.scale
                )
            }
            insertShape(worldRect: world, shape: shape, style: pendingShapeStyle)

        case .connect(let fromID, let dropPoint, let targetID):
            if let targetID {
                // Every connection drag creates a connector — including a
                // repeat between an already-connected pair, which becomes a
                // PARALLEL connector (gRPC + HTTP, request + response…).
                // Anchor spreading keeps parallels visibly separate, and the
                // editor opens immediately so the new one gets its own label.
                // (Bidirectional is a property in the edge editor, never a
                // silent merge of two drags.)
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
                    content: .ink(Ink(points: points, style: pendingInkStyle))
                )
                delegate?.canvasView(self, perform: .insertElement(element), actionName: "Draw")
                strokeFinished?(element.id)
            }
            needsDisplay = true

        case .moveEndpoint(let id, let end, let targetID):
            defer { transientEndpoint = nil }
            if let dragged = transientEndpoint, var element = board.elements[id], var edge = element.edge {
                let otherEnd = end == .from ? edge.to : edge.from
                // Dropping on the other end's own block is a cancel (a
                // self-loop connector would be meaningless), as is a drop
                // that never moved.
                if targetID != otherEnd.elementID {
                    // Reuse the anchor resolved during the drag: a discrete
                    // node slot when over a block, else a free dangling point.
                    let anchor = dragged.anchor
                    if end == .from { edge.from = anchor } else { edge.to = anchor }
                    element.content = .edge(edge)
                    delegate?.canvasView(
                        self, perform: .replaceElement(element),
                        actionName: targetID != nil ? "Reconnect Connector" : "Detach Connector")
                }
            }
            needsDisplay = true

        case .bendEdge(let id, let index, let inserting, _):
            defer { transientBend = nil }
            if let bend = transientBend, var element = board.elements[id], var edge = element.edge {
                var waypoints = bend.waypoints
                let dragged = inserting ? min(index, max(waypoints.count - 1, 0)) : index

                // Dropping a joint back onto the line between its NEIGHBORS
                // removes it — the generalized straighten.
                if waypoints.indices.contains(dragged) {
                    var neighborEdge = edge
                    var without = waypoints
                    without.remove(at: dragged)
                    neighborEdge.waypoints = without
                    let tolerance = Double(8 / viewport.scale)
                    if let route = EdgeGeometry.route(for: neighborEdge, frames: board.frameProvider()) {
                        let vertices = [route.start] + without + [route.end]
                        let previous = vertices[dragged]
                        let next = vertices[dragged + 1]
                        if EdgeGeometry.Route.segmentDistance(waypoints[dragged], previous, next) < tolerance {
                            waypoints = without
                        }
                    }
                }

                edge.waypoints = waypoints
                element.content = .edge(edge)
                let actionName: String
                if waypoints.count < bend.waypoints.count {
                    actionName = waypoints.isEmpty ? "Straighten Connector" : "Remove Joint"
                } else {
                    actionName = inserting ? "Bend Connector" : "Move Joint"
                }
                delegate?.canvasView(self, perform: .replaceElement(element), actionName: actionName)
            }

        case .spacePan:
            (isSpacePanHeld ? NSCursor.openHand : NSCursor.arrow).set()

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
            // Double-click on empty canvas creates a borderless text box, not
            // a shape (F5). Shapes come from the shape tool / picker; ⌘B still
            // adds a block.
            insertTextNote(at: viewport.toWorld(point))
        }
    }

    /// A borderless, background-less text box (a `.note`, which renders as pure
    /// text) placed at `world`, immediately in label-edit. This is the default
    /// double-click gesture on empty canvas (F5).
    private func insertTextNote(at world: Point) {
        let layerIDs = activeLayerIDs()
        guard !layerIDs.isEmpty else { return }
        let factor = creationScaleFactor()
        let size = CGSize(width: 140 * factor, height: 40 * factor)
        let frame = Rect(
            x: world.x - Double(size.width) / 2, y: world.y - Double(size.height) / 2,
            width: Double(size.width), height: Double(size.height)
        )
        let element = Element(
            layerIDs: layerIDs,
            sortKey: board.topSortKey,
            content: .note(Note(text: "", frame: frame, style: Style(fill: Style.noFill)))
        )
        delegate?.canvasView(self, perform: .insertElement(element), actionName: "Add Text")
        selection = [element.id]
        if let inserted = board.elements[element.id] {
            beginLabelEdit(for: inserted)
        }
        nudgeClearOfLeftPanel(frame)
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        // Space: hold to pan with any pointing device (⎵ + drag), like every
        // canvas app — essential for mouse-only setups without trackpad
        // scrolling.
        if event.keyCode == 49, editingElementID == nil {
            if !event.isARepeat, !isSpacePanHeld {
                isSpacePanHeld = true
                NSCursor.openHand.set()
            }
            return
        }
        // Single-key tool switching (Excalidraw-style), no modifiers.
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": return activateSelectTool(nil)
            case "d": return activateDrawTool(nil)
            case "s":
                // Same behavior as the toolbar button: pop the shape picker.
                if let shapePickerRequested {
                    shapePickerRequested()
                    return
                }
                return activateShapeTool(nil)
            default: break
            }
        }
        if isSimulating, event.keyCode == 53 { // escape exits simulation
            stopSimulation()
            return
        }
        if isPickingFlowSource, event.keyCode == 53 { // escape cancels source pick
            cancelFlowSourcePick()
            return
        }
        if isRecordingFlow {
            switch event.keyCode {
            case 53: // escape cancels the recording
                cancelFlowRecording()
            case 51, 117: // delete removes the last recorded connector
                undoLastFlowConnector()
            default:
                break // return/enter handled by the record bar's Save button
            }
            return
        }
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            deleteSelection(nil)
        case 53: // escape
            if case .draw = gesture {
                gesture = .idle // cancel the in-flight stroke
                needsDisplay = true
            } else if case .shapeDraw = gesture {
                gesture = .idle // cancel the in-flight shape
                needsDisplay = true
            } else if tool == .draw {
                tool = .select
            } else if case .shape = tool {
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

    public override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            isSpacePanHeld = false
            if case .spacePan = gesture {} else { NSCursor.arrow.set() }
            return
        }
        super.keyUp(with: event)
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

    // MARK: Grouping & boundaries (feature 4)

    public var canGroupSelection: Bool {
        selection.count >= 2 && board.groupOperation(for: selection) != nil
    }

    public var canUngroupSelection: Bool {
        selection.contains { board.elements[$0]?.groupID != nil }
    }

    @objc public func groupSelection(_ sender: Any?) {
        guard let (operation, _) = board.groupOperation(for: selection) else { return }
        delegate?.canvasView(self, perform: operation, actionName: "Group")
    }

    @objc public func ungroupSelection(_ sender: Any?) {
        let groupIDs = Set(selection.compactMap { board.elements[$0]?.groupID })
        let operations = groupIDs.compactMap { board.ungroupOperation($0) }
        guard !operations.isEmpty else { return }
        delegate?.canvasView(
            self,
            perform: operations.count == 1 ? operations[0] : .batch(operations),
            actionName: "Ungroup"
        )
    }

    /// Inserts a labeled boundary container around the selection (or a
    /// default-sized one at the viewport center when nothing is selected),
    /// z-ordered behind everything, and opens its label editor.
    @objc public func addBoundaryAroundSelection(_ sender: Any?) {
        let frame: Rect
        let selectionFrames = selection
            .compactMap { board.elements[$0] }
            .compactMap { SpatialIndex.boundingRect(of: $0) }
        if let first = selectionFrames.first {
            var union = first
            for rect in selectionFrames.dropFirst() { union = Self.union(union, rect) }
            frame = Rect(x: union.x - 36, y: union.y - 44, width: union.width + 72, height: union.height + 80)
        } else {
            let center = visibleCenterWorld
            frame = Rect(x: center.x - 220, y: center.y - 140, width: 440, height: 280)
        }
        // Bottom of the z-order: containers render behind their contents.
        let bottomKey = SortKey.between(nil, board.elements.values.map(\.sortKey).min())
        let layerIDs = activeLayerIDs()
        let element = Element(
            layerIDs: layerIDs.isEmpty ? [board.layers[0].id] : layerIDs,
            sortKey: bottomKey,
            content: .boundary(Note(text: "Boundary", frame: frame))
        )
        delegate?.canvasView(self, perform: .insertElement(element), actionName: "Add Boundary")
        select([element.id])
        if let inserted = board.elements[element.id] {
            beginLabelEdit(for: inserted)
        }
    }

    // MARK: Copy / paste / duplicate

    /// Pasteboard type carrying a self-contained clip (a mini-board's JSON), so
    /// elements round-trip losslessly — including across document windows.
    public static let clipPasteboardType = NSPasteboard.PasteboardType("com.yarden.designer.clip")

    @objc public func copy(_ sender: Any?) {
        guard !selection.isEmpty else { return }
        let clip = board.makeClip(of: selection)
        guard let data = try? JSONEncoder().encode(clip) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.clipPasteboardType)
    }

    @objc public func cut(_ sender: Any?) {
        guard !selection.isEmpty else { return }
        copy(sender)
        deleteSelection(sender)
    }

    @objc public func paste(_ sender: Any?) {
        if let data = NSPasteboard.general.data(forType: Self.clipPasteboardType),
           let clip = try? JSONDecoder().decode(Board.self, from: data),
           !clip.elements.isEmpty {
            insertClip(clip, centeredOnViewport: true)
            return
        }
        // Foreign content: an SVG copied from the web, or a raster image —
        // becomes an image block (Style.image data URI) at viewport center.
        _ = pasteForeignImage()
    }

    /// SVG markup (string/HTML/public.svg-image) or a raster image on the
    /// pasteboard becomes an image block. Returns whether anything landed.
    @discardableResult
    public func pasteForeignImage() -> Bool {
        let pasteboard = NSPasteboard.general

        // 1. SVG: dedicated type, or markup inside a plain string / HTML.
        var svgText: String?
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType("public.svg-image")) {
            svgText = String(data: data, encoding: .utf8)
        }
        if svgText == nil {
            for type in [NSPasteboard.PasteboardType.string, .html] {
                guard let text = pasteboard.string(forType: type) else { continue }
                if let range = text.range(of: "<svg"),
                   let end = text.range(of: "</svg>", range: range.lowerBound..<text.endIndex) {
                    svgText = String(text[range.lowerBound..<end.upperBound])
                    break
                }
            }
        }
        if let svgText, let data = svgText.data(using: .utf8), NSImage(data: data) != nil {
            let uri = "data:image/svg+xml;base64,\(data.base64EncodedString())"
            insertImageBlock(dataURI: uri, naturalSize: NSImage(data: data)?.size)
            return true
        }

        // 2. Raster: PNG directly, or anything NSImage can read (TIFF from
        // most apps) re-encoded as PNG.
        if let png = pasteboard.data(forType: .png), let image = NSImage(data: png) {
            insertImageBlock(dataURI: "data:image/png;base64,\(png.base64EncodedString())",
                             naturalSize: image.size)
            return true
        }
        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            insertImageBlock(dataURI: "data:image/png;base64,\(png.base64EncodedString())",
                             naturalSize: image.size)
            return true
        }
        return false
    }

    private func insertImageBlock(dataURI: String, naturalSize: CGSize?) {
        // Clamp to a sane on-board footprint, preserving aspect.
        let natural = naturalSize.flatMap { $0.width > 1 && $0.height > 1 ? $0 : nil }
            ?? CGSize(width: 240, height: 180)
        let maxSide = 420.0 * creationScaleFactor()
        let scale = min(1, maxSide / Double(max(natural.width, natural.height)))
        let width = Double(natural.width) * scale
        let height = Double(natural.height) * scale
        let center = visibleCenterWorld
        let layerIDs = activeLayerIDs()
        let element = Element(
            layerIDs: layerIDs.isEmpty ? [board.layers[0].id] : layerIDs,
            sortKey: board.topSortKey,
            content: .node(Node(
                semantic: NodeSemantic(name: ""),
                frame: Rect(x: center.x - width / 2, y: center.y - height / 2,
                            width: width, height: height),
                style: Style(fill: Style.noFill, image: dataURI)
            ))
        )
        delegate?.canvasView(self, perform: .insertElement(element), actionName: "Paste Image")
        selection = [element.id]
    }

    @objc public func duplicateSelection(_ sender: Any?) {
        guard !selection.isEmpty else { return }
        let clip = board.makeClip(of: selection)
        insertClip(clip, centeredOnViewport: false)
    }

    /// Instantiates a clip into the board with fresh IDs on the active layer,
    /// then selects the new elements. Centered on the viewport (paste) or
    /// nudged from the original (duplicate).
    private func insertClip(_ clip: Board, centeredOnViewport: Bool) {
        let layerIDs = activeLayerIDs()
        guard let layerID = layerIDs.first ?? board.layers.first?.id else { return }

        var dx = 24.0, dy = 24.0
        if centeredOnViewport, let bounds = clip.contentBounds() {
            let center = visibleCenterWorld
            dx = center.x - bounds.midX
            dy = center.y - bounds.midY
        }
        let (operations, newIDs) = board.instantiateOperations(from: clip, offsetBy: dx, dy, onto: layerID)
        guard !operations.isEmpty else { return }
        delegate?.canvasView(self, perform: .batch(operations), actionName: "Paste")
        select(newIDs)
    }

    public var canPaste: Bool {
        let pasteboard = NSPasteboard.general
        if pasteboard.data(forType: Self.clipPasteboardType) != nil { return true }
        if pasteboard.data(forType: NSPasteboard.PasteboardType("public.svg-image")) != nil { return true }
        if pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil { return true }
        if let text = pasteboard.string(forType: .string), text.contains("<svg") { return true }
        return false
    }

    /// Removes manual bends from every selected connector (P5).
    @objc public func straightenSelection(_ sender: Any?) {
        let operations: [BoardOperation] = selection.compactMap { id in
            guard var element = board.elements[id], var edge = element.edge,
                  !edge.waypoints.isEmpty else { return nil }
            edge.waypoints = []
            element.content = .edge(edge)
            return .replaceElement(element)
        }
        guard !operations.isEmpty else { return }
        delegate?.canvasView(
            self,
            perform: operations.count == 1 ? operations[0] : .batch(operations),
            actionName: "Straighten Connector")
    }

    @objc public func activateSelectTool(_ sender: Any?) {
        tool = .select
    }

    @objc public func activateDrawTool(_ sender: Any?) {
        tool = .draw
    }

    /// Shape tool via key/palette: returns to the last picked shape.
    @objc public func activateShapeTool(_ sender: Any?) {
        tool = .shape(lastShapeChoice.shape, lockAspect: lastShapeChoice.lockAspect)
    }

    /// Shape tool via the picker: remembers the choice for the "S" key.
    public func activateShapeTool(shape: NodeShape, lockAspect: Bool) {
        lastShapeChoice = (shape, lockAspect)
        tool = .shape(shape, lockAspect: lockAspect)
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
        insertBlock(at: world, kind: .generic, shape: .rectangle)
    }

    /// The typed-insertion entry point (feature 3): drop a block of a chosen
    /// kind and shape at the viewport center and start naming it.
    public func addBlock(kind: NodeKind, shape: NodeShape, orientation: ShapeOrientation = .up) {
        insertBlock(
            at: viewport.toWorld(CGPoint(x: bounds.midX, y: bounds.midY)),
            kind: kind, shape: shape, orientation: orientation
        )
    }

    /// P1 (zoom drift): the factor applied to a new block's default size so
    /// creation is consistent with what the user is LOOKING at. Next to
    /// visible blocks, match them (median width vs the 160pt standard);
    /// on empty space, size for readability at the current zoom (1/scale) —
    /// zoomed-out sketching gets proportionally bigger blocks instead of
    /// specks that dwarf everything when you zoom back in.
    private func creationScaleFactor() -> Double {
        let visibleWorld = viewport.visibleWorldRect(viewSize: bounds.size)
        let visibleWidths = spatialIndex.query(visibleWorld)
            .compactMap { board.elements[$0]?.node?.frame.width }
            .sorted()
        if !visibleWidths.isEmpty {
            return (visibleWidths[visibleWidths.count / 2] / 160).clamped(to: 0.25...4)
        }
        return (1 / viewport.scale).clamped(to: 0.25...4)
    }

    private func insertBlock(
        at world: Point, kind: NodeKind, shape: NodeShape, orientation: ShapeOrientation = .up
    ) {
        let layerIDs = activeLayerIDs()
        Self.debugTrace?("createBlock world=\(world) layers=\(layerIDs.count) delegate=\(delegate != nil)")
        guard !layerIDs.isEmpty else { return }
        // Squarer default for the symbolic shapes so they read correctly.
        let base = shape == .rectangle ? CGSize(width: 160, height: 80) : CGSize(width: 130, height: 90)
        let factor = creationScaleFactor()
        let size = CGSize(width: base.width * factor, height: base.height * factor)
        let frame = Rect(
            x: world.x - Double(size.width) / 2, y: world.y - Double(size.height) / 2,
            width: Double(size.width), height: Double(size.height)
        )
        let element = Element(
            layerIDs: layerIDs,
            sortKey: board.topSortKey,
            content: .node(Node(
                semantic: NodeSemantic(kind: kind, name: ""),
                frame: frame, shape: shape, orientation: orientation
            ))
        )
        delegate?.canvasView(self, perform: .insertElement(element), actionName: "Add Block")
        selection = [element.id]
        if let inserted = board.elements[element.id] {
            beginLabelEdit(for: inserted)
        }
        nudgeClearOfLeftPanel(frame)
    }

    /// Shape-tool commit: a node at EXACTLY the dragged frame, unlabeled
    /// (grouping shapes start nameless — double-click labels later), styled
    /// by the pending style. The shape tool STAYS armed so you can stamp
    /// several shapes in a row (Esc / V returns to Select). Because the tool
    /// is pure view state that undo never touches, ⌘Z removes the shape
    /// without reverting your pick back to the cursor.
    private func insertShape(worldRect: Rect, shape: NodeShape, style: Style) {
        let layerIDs = activeLayerIDs()
        let element = Element(
            layerIDs: layerIDs.isEmpty ? [board.layers[0].id] : layerIDs,
            sortKey: board.topSortKey,
            content: .node(Node(
                semantic: NodeSemantic(kind: .generic, name: ""),
                frame: worldRect,
                shape: shape,
                style: style
            ))
        )
        delegate?.canvasView(self, perform: .insertElement(element), actionName: "Add Shape")
        selection = [element.id]
        nudgeClearOfLeftPanel(worldRect)
    }

    /// Shift (or a square/circle picker entry) constrains the drag to equal
    /// width and height, keeping the dragged corner's direction.
    private func constrainedShapePoint(from start: CGPoint, to point: CGPoint, shiftHeld: Bool) -> CGPoint {
        guard case .shape(_, let lockAspect) = tool, lockAspect || shiftHeld else { return point }
        let dx = point.x - start.x
        let dy = point.y - start.y
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: start.x + (dx < 0 ? -side : side),
                       y: start.y + (dy < 0 ? -side : side))
    }

    /// Z-order controls: one undoable sortKey change per element. A grouping
    /// shape drawn over existing blocks gets tucked BEHIND them with
    /// sendToBack; bringToFront is the inverse.
    public func bringSelectionToFront() {
        reorderSelection(toFront: true)
    }

    public func sendSelectionToBack() {
        reorderSelection(toFront: false)
    }

    /// Peers of `id` for layer-scoped z-order: elements sharing at least one of
    /// its layers, in back→front draw order (includes `id` itself).
    private func zPeers(of id: ElementID) -> [Element] {
        guard let element = board.elements[id] else { return [] }
        let layers = element.layerIDs
        return board.elementsInZOrder.filter {
            $0.id == id || !$0.layerIDs.isDisjoint(with: layers)
        }
    }

    /// 1-based rank from the FRONT among layer-sharing peers, and the peer
    /// count — drives the style panel's "Nth from front of M" readout (F8).
    public func zPosition(of id: ElementID) -> (rank: Int, total: Int)? {
        let peers = zPeers(of: id)
        guard let idx = peers.firstIndex(where: { $0.id == id }) else { return nil }
        return (rank: peers.count - idx, total: peers.count)
    }

    public func canStepSelection(forward: Bool) -> Bool {
        guard selection.count == 1, let id = selection.first else { return false }
        let peers = zPeers(of: id)
        guard let idx = peers.firstIndex(where: { $0.id == id }) else { return false }
        return forward ? idx < peers.count - 1 : idx > 0
    }

    public func stepSelectionForward() { stepSelection(forward: true) }
    public func stepSelectionBackward() { stepSelection(forward: false) }

    /// Move the single selected element ONE position among its layer-sharing
    /// peers (not to the global extreme like To Front/Back). One undo step.
    private func stepSelection(forward: Bool) {
        guard selection.count == 1, let id = selection.first,
              let element = board.elements[id] else { return }
        let peers = zPeers(of: id)
        guard let idx = peers.firstIndex(where: { $0.id == id }) else { return }
        var moved = element
        if forward {
            guard idx < peers.count - 1 else { return } // already frontmost among peers
            let above = peers[idx + 1]
            let aboveAbove = idx + 2 < peers.count ? peers[idx + 2].sortKey : nil
            moved.sortKey = SortKey.between(above.sortKey, aboveAbove)
        } else {
            guard idx > 0 else { return } // already backmost among peers
            let below = peers[idx - 1]
            let belowBelow = idx - 2 >= 0 ? peers[idx - 2].sortKey : nil
            moved.sortKey = SortKey.between(belowBelow, below.sortKey)
        }
        delegate?.canvasView(self, perform: .replaceElement(moved),
                             actionName: forward ? "Bring Forward" : "Send Backward")
        needsDisplay = true
    }

    private func reorderSelection(toFront: Bool) {
        guard !selection.isEmpty else { return }
        var operations: [BoardOperation] = []
        for id in selection.sorted() {
            guard var element = board.elements[id] else { continue }
            if toFront {
                element.sortKey = board.topSortKey
            } else {
                let bottom = board.elements.values.map(\.sortKey).min()
                element.sortKey = SortKey.between(nil, bottom)
            }
            operations.append(.replaceElement(element))
        }
        guard !operations.isEmpty else { return }
        delegate?.canvasView(self, perform: .batch(operations),
                             actionName: toFront ? "Bring to Front" : "Send to Back")
        needsDisplay = true
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

    /// The editor font for `element`. For a text box (`.note`) it tracks the box
    /// HEIGHT (× textSize) so the field matches the on-canvas text and scales
    /// with a resize (I2/I3); other elements use the fixed zoom-scaled size.
    /// Clamped to keep the field legible and (at high zoom) from ballooning over
    /// the toolbar.
    private func labelEditorFont(for element: Element, frame: Rect) -> NSFont {
        let raw: CGFloat
        let cap: CGFloat
        if isNote(element), case .note(let note) = element.content {
            raw = CGFloat(max(frame.height * 0.55, 6))
                * CGFloat(note.style.effectiveTextMultiplier) * CGFloat(viewport.scale)
            cap = 120
        } else {
            raw = 13 * CGFloat(viewport.scale)
            cap = 26
        }
        return .systemFont(ofSize: min(max(raw, 11), cap), weight: .medium)
    }

    /// Keep the live editor font in sync when the element being edited changes
    /// size (text-size control or a resize during edit) so you SEE the text
    /// change size while typing (I3c). Called from `board` didSet.
    private func refreshLabelEditorFontIfEditing() {
        guard let field = labelEditor, let id = editingElementID,
              let element = board.elements[id],
              let frame = SpatialIndex.boundingRect(of: element) else { return }
        field.font = labelEditorFont(for: element, frame: frame)
    }

    public func beginLabelEdit(for element: Element) {
        commitLabelEditor()
        guard let frame = SpatialIndex.boundingRect(of: element) else { return }
        guard element.node != nil || isNote(element) || element.boundary != nil else { return }

        let field = NSTextField(string: currentLabel(of: element))
        field.isBordered = false
        // A text box (`.note`) edits as pure text: no background box, no focus
        // ring — just a caret you type into (I3). Nodes/boundaries keep the
        // solid field background for legibility over their fill.
        let isTextBox = isNote(element)
        field.drawsBackground = !isTextBox
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = isTextBox ? .none : .default
        field.alignment = .center
        let font = labelEditorFont(for: element, frame: frame)
        field.font = font
        let fontSize = font.pointSize
        let fieldHeight = fontSize + 12
        let viewRect = viewport.toView(frame)
        let width = min(max(viewRect.width - 8, 40), 340)
        let toolbarBand: CGFloat = 66 // toolbar sits in the top band; stay clear
        let x = min(max(viewRect.midX - width / 2, 4), bounds.width - width - 4)
        let y = min(max(viewRect.midY - fieldHeight / 2, toolbarBand),
                    bounds.height - fieldHeight - 4)
        field.frame = CGRect(x: x, y: y, width: width, height: fieldHeight)
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

    private func isLabelEditable(_ element: Element?) -> Bool {
        switch element?.content {
        case .node, .note, .boundary: return true
        default: return false
        }
    }

    /// Tears the label editor down WITHOUT committing text — for when the
    /// element it was editing no longer exists (undo storms).
    private func dismissLabelEditorWithoutCommit() {
        labelEditor?.removeFromSuperview()
        labelEditor = nil
        editingElementID = nil
        needsDisplay = true
        window?.makeFirstResponder(self)
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
        case .boundary(var boundary):
            boundary.text = text
            element.content = .boundary(boundary)
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
        case .boundary(let boundary): return boundary.text
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
        case .boundary(var boundary):
            boundary.frame = frame
            element.content = .boundary(boundary)
            return true
        case .ink(var ink):
            // Ink has no frame; translate every point by the delta between its
            // current bounding box and the dragged frame (B13).
            guard let current = SpatialIndex.boundingRect(of: element) else { return false }
            let dx = frame.x - current.x, dy = frame.y - current.y
            ink.points = ink.points.map {
                StrokePoint(x: $0.x + dx, y: $0.y + dy, pressure: $0.pressure, time: $0.time)
            }
            element.content = .ink(ink)
            return true
        case .edge:
            return false // routing follows endpoints; no frame move
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

    /// Topmost NODE under the point, ignoring connectors and ink — the
    /// connect-band check must see the node even when an edge covers it.
    private func editableNode(at viewPoint: CGPoint) -> Element? {
        let world = viewport.toWorld(viewPoint)
        let candidates = spatialIndex
            .query(Rect(x: world.x - 1, y: world.y - 1, width: 2, height: 2))
            .compactMap { board.elements[$0] }
            .filter { $0.node != nil && isEditable(id: $0.id) }
            .filter { $0.node?.frame.contains(world) == true }
        return candidates.max { ($0.sortKey, $0.id) < ($1.sortKey, $1.id) }
    }

    /// The anchor a dragged connector endpoint should commit to: the nearest
    /// discrete slot on the target block (so it pins to a fixed point the user
    /// can later re-pick to de-clutter), or a free dangling point off any block.
    private func endpointAnchor(
        forTarget targetID: ElementID?, droppedAt world: Point
    ) -> DesignerModel.Anchor {
        guard let targetID,
              let frame = board.frameProvider(overrides: transientFrames)(targetID) else {
            return .free(world)
        }
        let slot = EdgeGeometry.nearestAnchorSlot(to: world, on: frame)
        return .element(targetID, side: slot.side, offset: slot.offset)
    }

    private func preciseHit(_ element: Element, world: Point, tolerance: Double) -> Bool {
        switch element.content {
        case .node(let node):
            guard node.frame.contains(world) else { return false }
            // A filled node (or one showing an image) is solid everywhere. A
            // no-fill shape (hollow outline / grouping rectangle) is empty
            // inside — a click in the interior should fall through to whatever
            // sits behind it; only its border and its own label are "solid".
            if node.style.hasFill || node.style.image != nil { return true }
            func inset(_ rect: Rect, by amount: Double) -> Rect {
                Rect(x: rect.x + amount, y: rect.y + amount,
                     width: max(rect.width - amount * 2, 0), height: max(rect.height - amount * 2, 0))
            }
            let band = max(8 / viewport.scale, tolerance)
            if !inset(node.frame, by: band).contains(world) { return true } // on the border
            if !node.semantic.name.isEmpty {
                // The centered label area stays clickable so a titled outline
                // (or a text box inside a shape) can still be grabbed.
                let labelHeight = min(node.frame.height, 28)
                let labelBox = Rect(x: node.frame.x, y: node.frame.midY - labelHeight / 2,
                                    width: node.frame.width, height: labelHeight)
                if labelBox.contains(world) { return true }
            }
            return false
        case .note(let note):
            return note.frame.contains(world)
        case .ink(let ink):
            return ink.points.contains {
                hypot($0.x - world.x, $0.y - world.y) <= tolerance * 2
            }
        case .boundary(let boundary):
            // Hit only on the border band or the label strip — clicks inside
            // the container must reach the nodes it holds.
            let frame = boundary.frame
            func inset(_ rect: Rect, by amount: Double) -> Rect {
                Rect(x: rect.x + amount, y: rect.y + amount,
                     width: max(rect.width - amount * 2, 0), height: max(rect.height - amount * 2, 0))
            }
            guard inset(frame, by: -tolerance).contains(world) else { return false }
            let band = max(8 / viewport.scale, tolerance)
            if !inset(frame, by: band).contains(world) { return true } // border band
            // Label strip: top area where the title renders.
            let labelStrip = Rect(x: frame.x, y: frame.y, width: frame.width, height: min(30, frame.height))
            return labelStrip.contains(world)
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
              element.node != nil || isNote(element) || element.boundary != nil else { return nil }
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
        let point = convert(event.locationInWindow, from: nil)
        updateCursor(at: point)
        // Hover-to-peek captions: only worth a hit-test when the mode reveals
        // captions on focus; otherwise leave `hoveredEdgeID` untouched/cleared.
        if board.captionMode == .onFocus {
            let hit = editableElement(at: point)
            hoveredEdgeID = hit?.edge != nil ? hit?.id : nil
        } else if hoveredEdgeID != nil {
            hoveredEdgeID = nil
        }
        updateBrokenLinkHover(at: point)
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
        } else if let hit = editableElement(at: point), let node = hit.node,
                  node.style.hasFill || node.style.image != nil,
                  isInConnectBand(point, of: hit) {
            // Only solid blocks show the connect crosshair on their border; a
            // no-fill outline shows the normal arrow so it reads as movable (I1).
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

extension CanvasView: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)),
             #selector(duplicateSelection(_:)), #selector(deleteSelection(_:)):
            return !selection.isEmpty
        case #selector(paste(_:)):
            return canPaste
        case #selector(groupSelection(_:)):
            return canGroupSelection
        case #selector(ungroupSelection(_:)):
            return canUngroupSelection
        default:
            return true
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
