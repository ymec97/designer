import AppKit
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
            spatialIndex = SpatialIndex(board: board)
            zOrderedElements = board.elementsInZOrder
            selection.formIntersection(Set(board.elements.keys))
            needsDisplay = true
        }
    }

    /// Cached draw order — rebuilt on board changes, never per frame.
    private var zOrderedElements: [Element] = []

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

    /// Below this scale a 160-wide node is under ~29px — simplified rendering.
    static let simplifiedRenderScale: Double = 0.18

    private var spatialIndex = SpatialIndex()
    private let renderer = BoardRenderer()

    /// Frames shown during an in-flight drag/resize, committed as one
    /// operation (= one undo step) at gesture end.
    private var transientFrames: [ElementID: Rect] = [:]

    private enum GestureState {
        case idle
        case mouseDown(at: CGPoint, on: ElementID?, hadSelection: Bool)
        case move(originals: [ElementID: Rect], startWorld: Point)
        case resize(id: ElementID, handle: ResizeHandle, original: Rect, startWorld: Point)
        case rubberBand(start: CGPoint, current: CGPoint)
    }

    private var gesture: GestureState = .idle
    private var labelEditor: NSTextField?
    private var editingElementID: ElementID?

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

    // MARK: Rendering

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.setFillColor(Palette.canvasBackground.cgColor)
        context.fill(bounds)

        let visibleWorld = viewport.visibleWorldRect(viewSize: bounds.size)
        let visibleIDs = spatialIndex.query(visibleWorld)
        let hiddenLayers = Set(board.layers.filter { !$0.isVisible }.map(\.id))

        // Cached z-order; per-frame work is a filter, not a sort.
        let drawables = zOrderedElements.filter { element in
            visibleIDs.contains(element.id)
                && element.layerIDs.contains { !hiddenLayers.contains($0) }
        }

        // LOD: when nodes are a few pixels wide, rounded paths, strokes, and
        // text are invisible anyway — batch-fill plain rects grouped by color
        // (one CG call per color instead of four per node).
        if viewport.scale < Self.simplifiedRenderScale {
            renderer.drawSimplified(
                drawables,
                in: context,
                viewport: viewport,
                transientFrames: transientFrames,
                selection: selection
            )
        } else {
            for element in drawables {
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

        if let handleBox = singleSelectionViewRect() {
            renderer.drawResizeHandles(around: handleBox, in: context)
        }

        if case .rubberBand(let start, let current) = gesture {
            renderer.drawRubberBand(rectFrom(start, current), in: context)
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

    public override func mouseDown(with event: NSEvent) {
        commitLabelEditor()
        let point = convert(event.locationInWindow, from: nil)

        if event.clickCount == 2 {
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
            let dx = world.x - startWorld.x
            let dy = world.y - startWorld.y
            for (id, original) in originals {
                transientFrames[id] = Rect(
                    x: original.x + dx, y: original.y + dy,
                    width: original.width, height: original.height
                )
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

        case .idle:
            break
        }
    }

    public override func mouseUp(with event: NSEvent) {
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

        case .mouseDown, .idle:
            break
        }
        gesture = .idle
    }

    private func handleDoubleClick(at point: CGPoint) {
        if let hit = editableElement(at: point) {
            selection = [hit.id]
            beginLabelEdit(for: hit)
        } else {
            createBlock(at: viewport.toWorld(point))
        }
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            deleteSelection(nil)
        case 53: // escape
            selection = []
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
        let operations = selection.compactMap { id -> BoardOperation? in
            board.elements[id] != nil ? .removeElement(id) : nil
        }
        selection = []
        delegate?.canvasView(self, perform: .batch(operations), actionName: "Delete")
    }

    @objc public func addBlock(_ sender: Any?) {
        createBlock(at: viewport.toWorld(CGPoint(x: bounds.midX, y: bounds.midY)))
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

    /// M1: all visible, unlocked layers are "active"; M4 adds explicit control.
    private func activeLayerIDs() -> Set<LayerID> {
        let active = board.layers.filter { $0.isVisible && !$0.isLocked }.map(\.id)
        return active.isEmpty ? [] : [active[0]]
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
        addSubview(field)
        window?.makeFirstResponder(field)
        labelEditor = field
        editingElementID = element.id
        needsDisplay = true
    }

    @objc private func labelEditorDidCommit(_ sender: NSTextField) {
        commitLabelEditor()
    }

    func commitLabelEditor() {
        guard let field = labelEditor, let id = editingElementID else { return }
        let text = field.stringValue
        field.removeFromSuperview()
        labelEditor = nil
        editingElementID = nil
        needsDisplay = true

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
        window?.makeFirstResponder(self)
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
            return false
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
        let point = convert(event.locationInWindow, from: nil)
        if let handleBox = singleSelectionViewRect(),
           let handle = ResizeHandle.allCases.first(where: {
               $0.rect(around: handleBox).insetBy(dx: -3, dy: -3).contains(point)
           }) {
            handle.cursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }
}
