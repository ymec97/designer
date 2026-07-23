import AppKit
import DesignerCanvas
import DesignerInterop
import DesignerModel
import DesignerPersistence

/// In-process UI test: synthesizes mouse/keyboard events and dispatches them
/// through NSWindow.sendEvent — the real hit-testing and responder chain —
/// then verifies both the model and the rendered pixels.
///
///     Designer.app/Contents/MacOS/Designer --ui-test
///
/// This exists because sandbox/TCC rules prevent driving the app from outside;
/// it covers everything except the OS delivering physical input to the window.
final class UITestDriver {
    private let document: BoardDocument
    private let canvasView: CanvasView
    private let window: NSWindow
    private var failures: [String] = []

    init?(document: BoardDocument) {
        guard let window = document.windowControllers.first?.window,
              let controller = window.contentViewController as? CanvasViewController else {
            return nil
        }
        self.document = document
        self.canvasView = controller.canvasView
        self.window = window
    }

    func run() {
        CanvasView.debugTrace = { print("TRACE", $0) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
        print("DIAG isKeyWindow:", window.isKeyWindow, "appActive:", NSApp.isActive)

        step0Diagnostics()
        step0aGhostRendersOnEmptyBoard()
        step0bSpacePan()
        step1CreateBlockByDoubleClick()
        step2TypeLabelAndCommit()
        step3DragBlock()
        step4RenderedPixels()
        step5UndoRedo()
        step6ConnectTwoBlocks()
        step7EdgeFollowsMove()
        step8DanglingDeleteAndSnapIn()
        step9DrawScribbleStaysInk()
        step10SketchRectangleBecomesBlock()
        step11SketchStrokeBecomesConnector()
        step12LayerVisibilityLockingAndActive()
        step13LibraryRoundTrip()
        step14LLMInterchangeAndExport()
        step15TrafficSimulation()
        step16Clipboard()
        step17AgentProposal()
        step18Flows()
        step19GroupsAndBoundaries()
        step20Inspector()
        step21VersionHistory()
        step22BendConnector()
        step23RepeatConnectionCreatesParallel()
        step24DragEndpointToReattach()
        step25ShapeToolAndStyles()
        step26LabelEditorNeverBlanketsToolbar()
        step27SnapOverlapDragByMouse()
        step28StylePanelPolish()
        step30CaptionModeAndDensityNudge()
        step31RubberBandExcludesDistantConnector()
        step32EndpointSnapsToDiscreteSlot()
        step33NoFillRectBorderMovesNotConnect()
        step34InkDragShowsStrokeMoving()
        step35EndpointIgnoresNoFillGroupRect()
        step29LinkedBoards()

        if failures.isEmpty {
            print("UI-TEST PASS: create, label, drag, render, undo, connect, follow, dangling+snap-in, ink, sketch-to-structure, layers, library, llm+export, simulate, clipboard, agent-proposal, flows, groups+boundaries, inspector, versions, bend, parallel-connect, empty-ghost, space-pan, endpoint-reattach, shapes+styles, editor-clamp, mouse-snap+overlap+drag, style-panel-polish, caption-mode+density-nudge, rubber-band-precise, endpoint-slot-snap, nofill-border-moves, ink-drag-visible, endpoint-ignores-group, linked-boards verified")
            exit(0)
        } else {
            for failure in failures {
                FileHandle.standardError.write(Data("UI-TEST FAIL: \(failure)\n".utf8))
            }
            exit(1)
        }
    }

    // MARK: Steps

    private func step0Diagnostics() {
        let center = CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY)
        let windowPoint = canvasView.convert(center, to: nil)
        print("DIAG contentView == canvasView:", window.contentView === canvasView)
        print("DIAG contentView:", String(describing: window.contentView))
        print("DIAG canvasView.window == window:", canvasView.window === window)
        print("DIAG canvasView.frame:", canvasView.frame, "bounds:", canvasView.bounds)
        print("DIAG center(view):", center, "→ window:", windowPoint)
        if let contentView = window.contentView, let superview = contentView.superview {
            let inSuper = superview.convert(windowPoint, from: nil)
            print("DIAG hitTest:", String(describing: superview.hitTest(inSuper)))
        }
        print("DIAG board layers:", canvasView.board.layers.map { "\($0.name) v=\($0.isVisible) l=\($0.isLocked)" })
        print("DIAG doc board layers:", document.board.layers.count, "elements:", document.board.elements.count)
        print("DIAG firstResponder:", String(describing: window.firstResponder))
    }

    /// A proposal onto a FRESH EMPTY canvas must render its ghost preview
    /// (the empty-board fast path used to skip the overlay entirely).
    private func step0aGhostRendersOnEmptyBoard() {
        guard let controller = window.contentViewController as? CanvasViewController else {
            expect(false, "no canvas controller for empty-ghost test")
            return
        }
        expect(document.board.elements.isEmpty, "board should start empty")
        guard let proposed = try? LLMInterchange.parse(
            #"{"format": "designer-board", "nodes": [{"id": "ghost-node", "name": "ghost-node"}], "edges": []}"#
        ).board else {
            expect(false, "couldn't build proposal board")
            return
        }
        controller.presentAgentProposal(proposed, note: nil)
        pumpRunLoop()
        expect(canvasView.proposalGhost != nil, "proposal should stage a ghost")

        // The ghost must actually PAINT: pixels inside its bounds differ
        // from the empty canvas background.
        if let bounds = canvasView.proposalGhostBounds(),
           let bitmap = canvasView.bitmapImageRepForCachingDisplay(in: canvasView.bounds) {
            canvasView.cacheDisplay(in: canvasView.bounds, to: bitmap)
            let center = canvasView.viewport.toView(Point(x: bounds.midX, y: bounds.midY))
            let scaleX = CGFloat(bitmap.pixelsWide) / canvasView.bounds.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / canvasView.bounds.height
            let ghostPixel = bitmap.colorAt(x: Int(center.x * scaleX), y: Int(center.y * scaleY))
            let backgroundPixel = bitmap.colorAt(x: 5, y: Int(CGFloat(bitmap.pixelsHigh) - 5))
            expect(ghostPixel != nil && ghostPixel != backgroundPixel,
                   "ghost must be visible on an empty canvas (ghost=\(String(describing: ghostPixel)) bg=\(String(describing: backgroundPixel)))")
        } else {
            expect(false, "no ghost bounds or bitmap")
        }
        controller.rejectAgentProposal(nil)
        pumpRunLoop()
        expect(canvasView.proposalGhost == nil, "reject should clear the ghost")
        expect(document.board.elements.isEmpty, "reject must not mutate the board")
    }

    /// Holding space turns a drag into a pan (mouse-only navigation).
    private func step0bSpacePan() {
        let before = canvasView.viewport.origin
        let center = CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY)
        keyEvent(.keyDown, keyCode: 49, characters: " ")
        send(.leftMouseDown, at: center, clickCount: 1)
        for step in 1...5 {
            send(.leftMouseDragged, at: CGPoint(x: center.x + CGFloat(step) * 20, y: center.y), clickCount: 1)
        }
        send(.leftMouseUp, at: CGPoint(x: center.x + 100, y: center.y), clickCount: 1)
        keyEvent(.keyUp, keyCode: 49, characters: " ")
        pumpRunLoop()
        let moved = canvasView.viewport.origin
        expect(abs(moved.x - before.x) > 50, "space-drag should pan the canvas (dx=\(moved.x - before.x))")
        expect(document.board.elements.isEmpty, "space-pan must not create anything")
        // Restore the viewport for the steps that follow.
        canvasView.viewport = CanvasViewport(origin: before, scale: canvasView.viewport.scale)
    }

    private func step1CreateBlockByDoubleClick() {
        let center = CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY)
        click(at: center, clickCount: 1)
        click(at: center, clickCount: 2)
        pumpRunLoop()

        let nodes = document.board.elements.values.filter { $0.node != nil }
        expect(nodes.count == 1, "double-click should create 1 block, board has \(nodes.count)")
        expect(canvasView.selection.count == 1, "new block should be selected")
    }

    private func step2TypeLabelAndCommit() {
        // The label editor should be first responder (an NSTextField's field editor).
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            editor.insertText("orders-api", replacementRange: NSRange(location: 0, length: 0))
            key(36) // return
            pumpRunLoop()
            let named = document.board.elements.values.first { $0.node?.semantic.name == "orders-api" }
            expect(named != nil, "typed label 'orders-api' should be committed to the model")
        } else {
            expect(false, "label editor should be first responder after block creation, got \(String(describing: window.firstResponder))")
        }
    }

    private func step3DragBlock() {
        guard let element = document.board.elements.values.first(where: { $0.node != nil }),
              let frame = element.node?.frame else {
            expect(false, "no block to drag")
            return
        }
        let startWorld = Point(x: frame.midX, y: frame.midY)
        let startView = canvasView.viewport.toView(startWorld)
        let endView = CGPoint(x: startView.x + 120, y: startView.y + 60)

        send(.leftMouseDown, at: startView, clickCount: 1)
        for i in 1...8 {
            let t = CGFloat(i) / 8
            send(.leftMouseDragged, at: CGPoint(
                x: startView.x + (endView.x - startView.x) * t,
                y: startView.y + (endView.y - startView.y) * t
            ), clickCount: 1)
        }
        send(.leftMouseUp, at: endView, clickCount: 1)
        pumpRunLoop()

        let moved = document.board.elements[element.id]?.node?.frame
        let dx = (moved?.midX ?? 0) - frame.midX
        let dy = (moved?.midY ?? 0) - frame.midY
        expect(
            abs(dx - 120 / canvasView.viewport.scale) < 2 && abs(dy - 60 / canvasView.viewport.scale) < 2,
            "drag should move block by (120,60)/scale, moved by (\(dx),\(dy))"
        )
    }

    private func step4RenderedPixels() {
        guard let frame = document.board.elements.values.first(where: { $0.node != nil })?.node?.frame else {
            expect(false, "no block to render")
            return
        }
        guard let bitmap = canvasView.bitmapImageRepForCachingDisplay(in: canvasView.bounds) else {
            expect(false, "cannot create bitmap for canvas")
            return
        }
        canvasView.cacheDisplay(in: canvasView.bounds, to: bitmap)

        let inside = canvasView.viewport.toView(Point(x: frame.midX, y: frame.midY))
        let outside = CGPoint(x: 5, y: 5)
        let scaleX = CGFloat(bitmap.pixelsWide) / canvasView.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / canvasView.bounds.height

        func pixel(_ point: CGPoint) -> NSColor? {
            bitmap.colorAt(x: Int(point.x * scaleX), y: Int(point.y * scaleY))
        }
        // isFlipped view: bitmap rows match view coordinates directly.
        let insideColor = pixel(inside)
        let outsideColor = pixel(outside)
        expect(
            insideColor != nil && outsideColor != nil && insideColor != outsideColor,
            "block pixels should differ from empty canvas (inside=\(String(describing: insideColor)) outside=\(String(describing: outsideColor)))"
        )
    }

    private func step5UndoRedo() {
        let countBefore = document.board.elements.count
        document.undoManager?.undo() // undo the move
        pumpRunLoop()
        document.undoManager?.undo() // undo the rename
        document.undoManager?.undo() // undo the create
        pumpRunLoop()
        expect(
            document.board.elements.isEmpty,
            "3 undos should empty the board, has \(document.board.elements.count)"
        )
        document.undoManager?.redo()
        document.undoManager?.redo()
        document.undoManager?.redo()
        pumpRunLoop()
        expect(
            document.board.elements.count == countBefore,
            "3 redos should restore \(countBefore) element(s)"
        )
    }

    private var firstNodeID: ElementID? {
        document.board.elements.values
            .filter { $0.node != nil }
            .min { $0.sortKey < $1.sortKey }?.id
    }

    private func nodeFrame(_ id: ElementID?) -> Rect? {
        id.flatMap { document.board.elements[$0]?.node?.frame }
    }

    private func edgeElements() -> [Element] {
        document.board.elements.values.filter { $0.edge != nil }
    }

    private func step6ConnectTwoBlocks() {
        guard let aID = firstNodeID, let aFrame = nodeFrame(aID) else {
            expect(false, "no source block for connect")
            return
        }
        // Create block B to the right of A.
        let bWorldCenter = Point(x: aFrame.maxX + 320, y: aFrame.midY)
        let bView = canvasView.viewport.toView(bWorldCenter)
        click(at: bView, clickCount: 1)
        click(at: bView, clickCount: 2)
        pumpRunLoop()
        key(53) // escape closes the label editor without a name
        pumpRunLoop()
        canvasView.commitLabelEditor()
        pumpRunLoop()
        expect(
            document.board.elements.values.filter { $0.node != nil }.count == 2,
            "second block should exist"
        )

        // Drag from A's right border band to B's center.
        let borderView = canvasView.viewport.toView(Point(x: aFrame.maxX - 2, y: aFrame.midY))
        send(.leftMouseDown, at: borderView, clickCount: 1)
        for i in 1...6 {
            let t = CGFloat(i) / 6
            send(.leftMouseDragged, at: CGPoint(
                x: borderView.x + (bView.x - borderView.x) * t,
                y: borderView.y + (bView.y - borderView.y) * t
            ), clickCount: 1)
        }
        send(.leftMouseUp, at: bView, clickCount: 1)
        pumpRunLoop()

        let edges = edgeElements()
        expect(edges.count == 1, "border drag should create exactly 1 edge, got \(edges.count)")
        if let edge = edges.first?.edge {
            expect(edge.from.elementID == aID, "edge should start at block A")
        }
    }

    private func step7EdgeFollowsMove() {
        guard let edgeElement = edgeElements().first,
              let edge = edgeElement.edge,
              let bID = edge.to.elementID,
              let bFrame = nodeFrame(bID) else {
            expect(false, "no edge/target for follow test")
            return
        }
        // Drag B and verify the resolved route endpoint tracks its border.
        let bCenterView = canvasView.viewport.toView(Point(x: bFrame.midX, y: bFrame.midY))
        let destination = CGPoint(x: bCenterView.x + 90, y: bCenterView.y + 140)
        send(.leftMouseDown, at: bCenterView, clickCount: 1)
        for i in 1...6 {
            let t = CGFloat(i) / 6
            send(.leftMouseDragged, at: CGPoint(
                x: bCenterView.x + (destination.x - bCenterView.x) * t,
                y: bCenterView.y + (destination.y - bCenterView.y) * t
            ), clickCount: 1)
        }
        send(.leftMouseUp, at: destination, clickCount: 1)
        pumpRunLoop()

        guard let movedFrame = nodeFrame(bID),
              let route = EdgeGeometry.route(
                  for: document.board.elements[edgeElement.id]!.edge!,
                  frames: document.board.frameProvider()
              ) else {
            expect(false, "edge route unresolvable after move")
            return
        }
        expect(abs(movedFrame.midX - bFrame.midX - 90) < 3, "block B should have moved")
        let end = route.end
        let onBorder = abs(end.x - movedFrame.x) < 1 || abs(end.x - movedFrame.maxX) < 1
            || abs(end.y - movedFrame.y) < 1 || abs(end.y - movedFrame.maxY) < 1
        expect(onBorder, "edge endpoint \(end) should sit on moved block border \(movedFrame)")
    }

    private func step8DanglingDeleteAndSnapIn() {
        guard let edgeID = edgeElements().first?.id,
              let edge = edgeElements().first?.edge,
              let bID = edge.to.elementID,
              let bFrame = nodeFrame(bID) else {
            expect(false, "no edge for dangling test")
            return
        }
        let elementsBefore = document.board.elements.count

        // Delete B: the connector must SURVIVE, visibly dangling.
        let bCenter = canvasView.viewport.toView(Point(x: bFrame.midX, y: bFrame.midY))
        click(at: bCenter, clickCount: 1)
        pumpRunLoop()
        key(51) // delete
        pumpRunLoop()

        expect(edgeElements().count == 1, "deleting a block must keep its connector")
        expect(
            document.board.elements.count == elementsBefore - 1,
            "only the block should be removed"
        )
        if let dangling = document.board.elements[edgeID]?.edge {
            expect(document.board.isDangling(dangling), "surviving connector should be dangling")
        }

        // Double-click near the loose endpoint: the new block snaps it in.
        // (Clamped into the view — the moved block can sit near the edge.)
        var target = bCenter
        if let released = document.board.elements[edgeID]?.edge,
           case .free(let point) = released.to {
            target = canvasView.viewport.toView(Point(x: point.x - 60, y: point.y))
        }
        target.x = min(max(target.x, 30), canvasView.bounds.width - 30)
        target.y = min(max(target.y, 60), canvasView.bounds.height - 30)
        click(at: target, clickCount: 1)
        click(at: target, clickCount: 2)
        pumpRunLoop()
        key(53) // escape the label editor
        pumpRunLoop()
        canvasView.commitLabelEditor()
        pumpRunLoop()

        guard let snapped = document.board.elements[edgeID]?.edge else {
            expect(false, "edge disappeared during snap-in")
            return
        }
        let nodeFrames = document.board.elements.values.compactMap(\.node?.frame)
        expect(
            !document.board.isDangling(snapped),
            "new block should snap the connector back in (to=\(snapped.to), clickView=\(bCenter), nodeFrames=\(nodeFrames))"
        )

        // One undo removes the block AND releases the endpoint again.
        document.undoManager?.undo()
        pumpRunLoop()
        if let released = document.board.elements[edgeID]?.edge {
            expect(document.board.isDangling(released), "undo should release the endpoint")
        }
        document.undoManager?.redo()
        pumpRunLoop()
    }

    private func inkCount() -> Int {
        document.board.elements.values.filter {
            if case .ink = $0.content { return true }
            return false
        }.count
    }

    private func drag(along path: [CGPoint]) {
        guard path.count > 1 else { return }
        send(.leftMouseDown, at: path[0], clickCount: 1)
        for point in path.dropFirst().dropLast() {
            send(.leftMouseDragged, at: point, clickCount: 1)
        }
        send(.leftMouseUp, at: path[path.count - 1], clickCount: 1)
        pumpRunLoop()
    }

    private func step9DrawScribbleStaysInk() {
        key(2, characters: "d") // draw tool
        pumpRunLoop()
        guard canvasView.tool == .draw else {
            expect(false, "'d' should activate the draw tool")
            return
        }
        // A jagged zig-zag far from any block: recognized as nothing → ink.
        var path: [CGPoint] = []
        for i in 0..<14 {
            path.append(CGPoint(
                x: 60 + CGFloat(i) * 12,
                y: 620 + CGFloat(i % 2 == 0 ? 0 : 45) + CGFloat(i % 3) * 8
            ))
        }
        let before = inkCount()
        drag(along: path)
        expect(inkCount() == before + 1, "scribble should stay ink (ink \(before)→\(inkCount()))")
    }

    private func step10SketchRectangleBecomesBlock() {
        let nodesBefore = document.board.elements.values.filter { $0.node != nil }.count
        let inkBefore = inkCount()

        // Sketch a rectangle in empty space (view coords, draw tool active).
        var path: [CGPoint] = []
        let x: CGFloat = 620, y: CGFloat = 520, w: CGFloat = 170, h: CGFloat = 110
        for i in 0...10 { path.append(CGPoint(x: x + w * CGFloat(i) / 10, y: y)) }
        for i in 0...8 { path.append(CGPoint(x: x + w, y: y + h * CGFloat(i) / 8)) }
        for i in 0...10 { path.append(CGPoint(x: x + w - w * CGFloat(i) / 10, y: y + h)) }
        for i in 0...7 { path.append(CGPoint(x: x, y: y + h - h * CGFloat(i) / 8)) }
        drag(along: path)

        let nodesAfter = document.board.elements.values.filter { $0.node != nil }.count
        expect(
            nodesAfter == nodesBefore + 1 && inkCount() == inkBefore,
            "sketched rectangle should live-convert to a block (nodes \(nodesBefore)→\(nodesAfter), ink \(inkBefore)→\(inkCount()))"
        )
    }

    private func step11SketchStrokeBecomesConnector() {
        // Stroke from the step-10 block to block A: should become an edge.
        let nodes = document.board.elements.values.filter { $0.node != nil }
        guard nodes.count >= 2 else {
            expect(false, "need two blocks for sketch-connect")
            return
        }
        let sorted = nodes.sorted { $0.sortKey < $1.sortKey }
        guard let fromFrame = sorted[sorted.count - 1].node?.frame,
              let toFrame = sorted[0].node?.frame else {
            expect(false, "missing frames")
            return
        }
        let edgesBefore = edgeElements().count
        let start = canvasView.viewport.toView(Point(x: fromFrame.midX, y: fromFrame.y - 4))
        let end = canvasView.viewport.toView(Point(x: toFrame.midX, y: toFrame.maxY + 4))
        var path: [CGPoint] = []
        for i in 0...16 {
            let t = CGFloat(i) / 16
            path.append(CGPoint(
                x: start.x + (end.x - start.x) * t + CGFloat((i % 3)) * 2,
                y: start.y + (end.y - start.y) * t
            ))
        }
        drag(along: path)

        expect(
            edgeElements().count == edgesBefore + 1,
            "sketched stroke between blocks should live-convert to a connector (edges \(edgesBefore)→\(edgeElements().count))"
        )
        key(9, characters: "v") // back to select tool
        pumpRunLoop()
        expect(canvasView.tool == .select, "'v' should return to the select tool")
    }

    private func step12LayerVisibilityLockingAndActive() {
        // New blocks land on the active layer.
        let security = Layer(name: "Security")
        document.perform(.insertLayer(security, at: 1), actionName: "Add Layer")
        canvasView.activeLayerID = security.id
        pumpRunLoop()

        let before = Set(document.board.elements.keys)
        canvasView.addBlock(nil)
        pumpRunLoop()
        canvasView.commitLabelEditor()
        pumpRunLoop()
        guard let newID = Set(document.board.elements.keys).subtracting(before).first,
              let frame = document.board.elements[newID]?.node?.frame else {
            expect(false, "⌘B should create a block")
            return
        }
        expect(
            document.board.elements[newID]?.layerIDs == [security.id],
            "new block should land on the active layer"
        )

        let center = canvasView.viewport.toView(Point(x: frame.midX, y: frame.midY))

        func setSecurity(_ mutate: (inout Layer) -> Void) {
            guard var layer = document.board.layers.first(where: { $0.id == security.id }) else { return }
            mutate(&layer)
            document.perform(.replaceLayer(layer), actionName: "Edit Layer")
            pumpRunLoop()
        }

        // Hidden layer: invisible pixels, no hit-testing.
        canvasView.select([])
        setSecurity { $0.isVisible = false }
        if let bitmap = canvasView.bitmapImageRepForCachingDisplay(in: canvasView.bounds) {
            canvasView.cacheDisplay(in: canvasView.bounds, to: bitmap)
            let scaleX = CGFloat(bitmap.pixelsWide) / canvasView.bounds.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / canvasView.bounds.height
            let inside = bitmap.colorAt(x: Int(center.x * scaleX), y: Int(center.y * scaleY))
            let empty = bitmap.colorAt(x: Int(5 * scaleX), y: Int(5 * scaleY))
            expect(inside == empty, "hidden layer's block should not render")
        }
        click(at: center, clickCount: 1)
        pumpRunLoop()
        expect(canvasView.selection.isEmpty, "hidden layer's block should not be clickable")

        // Locked layer: visible but not selectable.
        setSecurity { $0.isVisible = true; $0.isLocked = true }
        click(at: center, clickCount: 1)
        pumpRunLoop()
        expect(canvasView.selection.isEmpty, "locked layer's block should not be selectable")

        // Unlocked again: selectable.
        setSecurity { $0.isLocked = false }
        click(at: center, clickCount: 1)
        pumpRunLoop()
        expect(canvasView.selection == [newID], "unlocked block should select normally")

        // Focus mode dims non-active elements (pixel changes at block A).
        canvasView.select([])
        guard let otherFrame = document.board.elements.values
            .first(where: { $0.node != nil && $0.id != newID })?.node?.frame else { return }
        let otherCenter = canvasView.viewport.toView(Point(x: otherFrame.midX, y: otherFrame.midY))
        func pixel(at point: CGPoint) -> NSColor? {
            guard let bitmap = canvasView.bitmapImageRepForCachingDisplay(in: canvasView.bounds) else { return nil }
            canvasView.cacheDisplay(in: canvasView.bounds, to: bitmap)
            let scaleX = CGFloat(bitmap.pixelsWide) / canvasView.bounds.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / canvasView.bounds.height
            return bitmap.colorAt(x: Int(point.x * scaleX), y: Int(point.y * scaleY))
        }
        let fullOpacity = pixel(at: otherCenter)
        canvasView.focusActiveLayer = true
        pumpRunLoop()
        let dimmed = pixel(at: otherCenter)
        expect(
            fullOpacity != nil && dimmed != nil && fullOpacity != dimmed,
            "focus mode should visibly dim blocks off the active layer"
        )
        canvasView.focusActiveLayer = false
        canvasView.activeLayerID = nil
        pumpRunLoop()
    }

    private func step13LibraryRoundTrip() {
        guard let controller = window.contentViewController as? CanvasViewController else {
            expect(false, "no canvas controller for library test")
            return
        }
        if let failure = controller.runLibrarySelfTest() {
            expect(false, "library round-trip failed: \(failure)")
        }
    }

    private func step14LLMInterchangeAndExport() {
        guard let controller = window.contentViewController as? CanvasViewController else {
            expect(false, "no canvas controller for LLM test")
            return
        }
        if let failure = controller.runLLMInterchangeSelfTest() {
            expect(false, "LLM/export round-trip failed: \(failure)")
        }
    }

    private func step15TrafficSimulation() {
        guard let controller = window.contentViewController as? CanvasViewController else {
            expect(false, "no canvas controller for simulation test")
            return
        }
        if let failure = controller.runSimulationSelfTest() {
            expect(false, "traffic simulation failed: \(failure)")
        }
    }

    private func step16Clipboard() {
        guard let controller = window.contentViewController as? CanvasViewController else {
            expect(false, "no canvas controller for clipboard test")
            return
        }
        if let failure = controller.runClipboardSelfTest() {
            expect(false, "clipboard failed: \(failure)")
        }
    }

    private func step17AgentProposal() {
        guard let controller = window.contentViewController as? CanvasViewController else {
            expect(false, "no canvas controller for agent-proposal test")
            return
        }
        if let failure = controller.runAgentProposalSelfTest() {
            expect(false, "agent proposal failed: \(failure)")
        }
    }

    private func step18Flows() {
        guard let controller = window.contentViewController as? CanvasViewController else {
            expect(false, "no canvas controller for flows test")
            return
        }
        if let failure = controller.runFlowSelfTest() {
            expect(false, "flows failed: \(failure)")
        }
    }

    private func step19GroupsAndBoundaries() {
        guard let controller = window.contentViewController as? CanvasViewController else {
            expect(false, "no canvas controller for groups test")
            return
        }
        if let failure = controller.runGroupsAndBoundariesSelfTest() {
            expect(false, "groups+boundaries failed: \(failure)")
        }
    }

    private func step20Inspector() {
        guard let controller = window.contentViewController as? CanvasViewController else {
            expect(false, "no canvas controller for inspector test")
            return
        }
        if let failure = controller.runInspectorSelfTest() {
            expect(false, "inspector failed: \(failure)")
        }
    }

    private func step21VersionHistory() {
        guard let controller = window.contentViewController as? CanvasViewController else {
            expect(false, "no canvas controller for versions test")
            return
        }
        if let failure = controller.runVersionHistorySelfTest() {
            expect(false, "version history failed: \(failure)")
        }
    }

    /// P5: dragging a selected connector bends it; dropping the bend back on
    /// the straight line straightens it.
    private func step22BendConnector() {
        let layer = document.board.layers[0].id
        func node(_ name: String, _ x: Double) -> Element {
            Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                    content: .node(Node(semantic: NodeSemantic(name: name),
                                        frame: Rect(x: x, y: 3000, width: 120, height: 60))))
        }
        let a = node("bend-a", 0), b = node("bend-b", 420)
        let edgeElement = Element(
            layerIDs: [layer], sortKey: document.board.topSortKey,
            content: .edge(Edge(from: .element(a.id, side: nil, offset: nil),
                                to: .element(b.id, side: nil, offset: nil))))
        document.perform(.batch([
            .insertElement(a), .insertElement(b), .insertElement(edgeElement),
        ]), actionName: "Bend Test Graph")
        canvasView.reveal(worldRect: Rect(x: -50, y: 2900, width: 700, height: 300))
        canvasView.select([edgeElement.id])
        pumpRunLoop()

        func currentWaypoints() -> [Point] {
            document.board.elements[edgeElement.id]?.edge?.waypoints ?? []
        }
        guard let straightRoute = EdgeGeometry.route(
            for: edgeElement.edge!, frames: document.board.frameProvider()) else {
            expect(false, "no route for bend edge")
            return
        }
        let midView = canvasView.viewport.toView(straightRoute.midpoint)

        // Bend: drag the middle of the selected connector upward.
        send(.leftMouseDown, at: midView, clickCount: 1)
        for step in 1...5 {
            send(.leftMouseDragged, at: CGPoint(x: midView.x, y: midView.y - CGFloat(step) * 16), clickCount: 1)
        }
        send(.leftMouseUp, at: CGPoint(x: midView.x, y: midView.y - 80), clickCount: 1)
        pumpRunLoop()
        expect(currentWaypoints().count == 1, "drag should bend the connector (one waypoint)")

        func drag(from: CGPoint, to: CGPoint) {
            send(.leftMouseDown, at: from, clickCount: 1)
            for step in 1...5 {
                let t = CGFloat(step) / 5
                send(.leftMouseDragged, at: CGPoint(
                    x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t
                ), clickCount: 1)
            }
            send(.leftMouseUp, at: to, clickCount: 1)
            pumpRunLoop()
        }
        func route() -> EdgeGeometry.Route? {
            EdgeGeometry.route(for: document.board.elements[edgeElement.id]!.edge!,
                               frames: document.board.frameProvider())
        }

        // SECOND joint: grab the segment between the first joint and the end
        // and pull it downward — connectors hold any number of joints.
        canvasView.select([edgeElement.id])
        guard let bentRoute = route() else { expect(false, "no bent route"); return }
        let farView = canvasView.viewport.toView(bentRoute.point(atFraction: 0.78))
        drag(from: farView, to: CGPoint(x: farView.x + 10, y: farView.y + 70))
        expect(currentWaypoints().count == 2, "grabbing a segment grows a second joint")
        // A broken bend step must FAIL this one step, not trap the whole
        // battery on an out-of-range joint subscript.
        guard currentWaypoints().count == 2 else {
            expect(false, "bend produced \(currentWaypoints().count) joints, expected 2 — skipping joint sub-steps")
            return
        }

        // Move the FIRST joint on its own — the other joint must not move.
        let secondBefore = currentWaypoints()[1]
        canvasView.select([edgeElement.id])
        let firstView = canvasView.viewport.toView(currentWaypoints()[0])
        drag(from: firstView, to: CGPoint(x: firstView.x - 24, y: firstView.y - 24))
        expect(currentWaypoints().count == 2, "moving a joint keeps the others")
        expect(currentWaypoints()[1] == secondBefore, "the untouched joint stays put")

        // Remove the second joint: drop it on the line between its neighbors.
        canvasView.select([edgeElement.id])
        guard let multiRoute = route() else { expect(false, "no multi route"); return }
        let joints = currentWaypoints()
        guard joints.count == 2 else {
            expect(false, "expected 2 joints before removal, got \(joints.count) — skipping")
            return
        }
        let neighborMid = Point(x: (joints[0].x + multiRoute.end.x) / 2,
                                y: (joints[0].y + multiRoute.end.y) / 2)
        drag(from: canvasView.viewport.toView(joints[1]),
             to: canvasView.viewport.toView(neighborMid))
        expect(currentWaypoints().count == 1, "dropping a joint on the line removes it")

        // Straighten: drag the remaining joint back onto the straight line.
        canvasView.select([edgeElement.id])
        guard let remaining = currentWaypoints().first else {
            expect(false, "no joint left to straighten — skipping"); return
        }
        let bendView = canvasView.viewport.toView(remaining)
        drag(from: bendView, to: midView)
        expect(currentWaypoints().isEmpty, "dropping on the line should straighten")

        for _ in 0..<5 { document.undoManager?.undo() } // 4 joint edits + graph
    }

    /// Dragging a selected connector's END GRIP moves that endpoint: dropping
    /// it on another block reattaches, dropping on empty canvas detaches.
    private func step24DragEndpointToReattach() {
        let layer = document.board.layers[0].id
        func node(_ name: String, _ x: Double, _ y: Double) -> Element {
            Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                    content: .node(Node(semantic: NodeSemantic(name: name),
                                        frame: Rect(x: x, y: y, width: 120, height: 60))))
        }
        let a = node("re-a", 0, 3600), b = node("re-b", 420, 3600), c = node("re-c", 420, 3800)
        let edgeElement = Element(
            layerIDs: [layer], sortKey: document.board.topSortKey,
            content: .edge(Edge(from: .element(a.id, side: nil, offset: nil),
                                to: .element(b.id, side: nil, offset: nil))))
        document.perform(.batch([
            .insertElement(a), .insertElement(b), .insertElement(c), .insertElement(edgeElement),
        ]), actionName: "Reattach Test Graph")
        canvasView.reveal(worldRect: Rect(x: -50, y: 3500, width: 700, height: 500))
        canvasView.select([edgeElement.id])
        pumpRunLoop()

        func currentEdge() -> Edge? { document.board.elements[edgeElement.id]?.edge }
        guard let route = EdgeGeometry.route(
            for: edgeElement.edge!, frames: document.board.frameProvider()) else {
            expect(false, "no route for reattach edge")
            return
        }

        // Drag the arrival end (at b) onto c.
        let endView = canvasView.viewport.toView(route.end)
        let cCenter = canvasView.viewport.toView(Point(x: 480, y: 3830))
        send(.leftMouseDown, at: endView, clickCount: 1)
        for step in 1...5 {
            let t = CGFloat(step) / 5
            send(.leftMouseDragged, at: CGPoint(
                x: endView.x + (cCenter.x - endView.x) * t,
                y: endView.y + (cCenter.y - endView.y) * t
            ), clickCount: 1)
        }
        send(.leftMouseUp, at: cCenter, clickCount: 1)
        pumpRunLoop()
        expect(currentEdge()?.to.elementID == c.id,
               "dropping the end grip on another block reattaches the connector")

        // Drag it off to empty canvas — the connector detaches (dangles).
        canvasView.select([edgeElement.id])
        pumpRunLoop()
        guard let rerouted = EdgeGeometry.route(
            for: currentEdge()!, frames: document.board.frameProvider()) else {
            expect(false, "no rerouted route")
            return
        }
        let endView2 = canvasView.viewport.toView(rerouted.end)
        let empty = canvasView.viewport.toView(Point(x: 250, y: 3980))
        send(.leftMouseDown, at: endView2, clickCount: 1)
        for step in 1...5 {
            let t = CGFloat(step) / 5
            send(.leftMouseDragged, at: CGPoint(
                x: endView2.x + (empty.x - endView2.x) * t,
                y: endView2.y + (empty.y - endView2.y) * t
            ), clickCount: 1)
        }
        send(.leftMouseUp, at: empty, clickCount: 1)
        pumpRunLoop()
        if case .free = currentEdge()?.to {
            expect(true, "")
        } else {
            expect(false, "dropping the end grip on canvas should detach the connector")
        }

        document.undoManager?.undo() // detach
        document.undoManager?.undo() // reattach
        document.undoManager?.undo() // test graph
    }

    /// Connecting an already-connected pair again creates a PARALLEL
    /// connector — never a silent absorb or bidirectional merge.
    private func step23RepeatConnectionCreatesParallel() {
        let layer = document.board.layers[0].id
        func node(_ name: String, _ x: Double) -> Element {
            Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                    content: .node(Node(semantic: NodeSemantic(name: name),
                                        frame: Rect(x: x, y: 4000, width: 120, height: 60))))
        }
        let a = node("par-a", 0), b = node("par-b", 420)
        document.perform(.batch([.insertElement(a), .insertElement(b)]), actionName: "Parallel Test")
        canvasView.reveal(worldRect: Rect(x: -50, y: 3900, width: 700, height: 260))
        pumpRunLoop()

        func edgesBetween() -> [DesignerModel.Edge] {
            document.board.elements.values.compactMap(\.edge).filter {
                ($0.from.elementID == a.id && $0.to.elementID == b.id)
                    || ($0.from.elementID == b.id && $0.to.elementID == a.id)
            }
        }
        func dragConnection(from: Element, to: Element) {
            guard let fromFrame = document.board.elements[from.id]?.node?.frame,
                  let toFrame = document.board.elements[to.id]?.node?.frame else { return }
            let fromEdgeX = from.id == a.id ? fromFrame.maxX - 2 : fromFrame.x + 2
            let start = canvasView.viewport.toView(Point(x: fromEdgeX, y: fromFrame.midY))
            let end = canvasView.viewport.toView(Point(x: toFrame.midX, y: toFrame.midY))
            send(.leftMouseDown, at: start, clickCount: 1)
            for step in 1...6 {
                let t = CGFloat(step) / 6
                send(.leftMouseDragged, at: CGPoint(
                    x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t
                ), clickCount: 1)
            }
            send(.leftMouseUp, at: end, clickCount: 1)
            pumpRunLoop()
            key(53) // escape dismisses the edge editor popover
            pumpRunLoop()
            // Deselect the fresh connector (a real user's dismiss-click does
            // this) — while it stays selected its END GRIPS own the border
            // spot, and the next drag would move an endpoint instead of
            // creating the parallel.
            click(at: canvasView.viewport.toView(Point(x: 210, y: 3920)), clickCount: 1)
            pumpRunLoop()
        }

        dragConnection(from: a, to: b)
        expect(edgesBetween().count == 1, "first connection created")
        dragConnection(from: a, to: b)
        expect(edgesBetween().count == 2, "repeat connection creates a parallel connector")
        dragConnection(from: b, to: a)
        let all = edgesBetween()
        expect(all.count == 3, "reverse connection creates its own connector")
        expect(all.allSatisfy { $0.semantic.direction == .forward },
               "no silent bidirectional upgrade")

        for _ in 0..<4 { document.undoManager?.undo() } // 3 connects + test nodes
    }

    /// Shapes tool + style pipeline: drag-create at the dragged size with
    /// the pending (no-fill) style, aspect lock, pencil style on new ink,
    /// selection restyle, send-to-back — the whole v0.8.0 surface.
    private func step25ShapeToolAndStyles() {
        canvasView.reveal(worldRect: Rect(x: -50, y: 4300, width: 900, height: 500))
        pumpRunLoop()

        func drag(fromWorld: Point, toWorld: Point) {
            let from = canvasView.viewport.toView(fromWorld)
            let to = canvasView.viewport.toView(toWorld)
            send(.leftMouseDown, at: from, clickCount: 1)
            for step in 1...5 {
                let t = CGFloat(step) / 5
                send(.leftMouseDragged, at: CGPoint(
                    x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t
                ), clickCount: 1)
            }
            send(.leftMouseUp, at: to, clickCount: 1)
            pumpRunLoop()
        }
        func newestNode() -> (id: ElementID, node: Node)? {
            document.board.elementsInZOrder.reversed()
                .compactMap { element in element.node.map { (element.id, $0) } }
                .first
        }

        // Drag-create a no-fill rectangle at the dragged frame.
        canvasView.pendingShapeStyle = Style(fill: Style.noFill, opacity: 0.5)
        canvasView.activateShapeTool(shape: .rectangle, lockAspect: false)
        drag(fromWorld: Point(x: 0, y: 4400), toWorld: Point(x: 300, y: 4560))
        guard let rect = newestNode() else { expect(false, "no shape created"); return }
        expect(rect.node.semantic.name.isEmpty, "shapes start unlabeled")
        expect(rect.node.style.fill == Style.noFill, "pending no-fill style applied")
        expect(rect.node.style.opacity == 0.5, "pending opacity applied")
        expect(abs(rect.node.frame.width - 300) < 3 && abs(rect.node.frame.height - 160) < 3,
               "shape matches the dragged size (got \(rect.node.frame))")
        expect(canvasView.tool == .select, "tool reverts to Select after drawing")

        // Aspect-locked circle: drag a non-square rect, get a square frame.
        canvasView.activateShapeTool(shape: .ellipse, lockAspect: true)
        drag(fromWorld: Point(x: 400, y: 4400), toWorld: Point(x: 560, y: 4470))
        guard let circle = newestNode() else { expect(false, "no circle created"); return }
        expect(circle.node.shape == .ellipse, "picker shape respected")
        expect(abs(circle.node.frame.width - circle.node.frame.height) < 1,
               "lock-aspect drag yields equal sides (got \(circle.node.frame))")

        // Send the big rect to the back: its sortKey drops below everything.
        canvasView.select([rect.id])
        canvasView.sendSelectionToBack()
        pumpRunLoop()
        let backKey = document.board.elements[rect.id]!.sortKey
        expect(document.board.elements.values.allSatisfy { $0.id == rect.id || $0.sortKey > backKey },
               "send-to-back drops below every other element")

        // Pencil style: new ink carries the pending ink style.
        canvasView.pendingInkStyle = Style(stroke: "#D95757", strokeWidth: 4.5)
        canvasView.activateDrawTool(nil)
        drag(fromWorld: Point(x: 20, y: 4700), toWorld: Point(x: 200, y: 4740))
        let ink = document.board.elementsInZOrder.reversed().first { element in
            if case .ink = element.content { return true }
            return false
        }
        if case .ink(let stroke)? = ink?.content {
            expect(stroke.style.stroke == "#D95757" && stroke.style.strokeWidth == 4.5,
                   "pencil style applied to new ink")
        } else {
            expect(false, "no ink stroke created")
        }
        canvasView.activateSelectTool(nil)

        // Selection restyle through the style panel model path.
        canvasView.select([circle.id])
        if var element = document.board.elements[circle.id], var node = element.node {
            node.style = Style(fill: "#4A90D9", opacity: 0.3)
            element.content = .node(node)
            document.perform(.replaceElement(element), actionName: "Edit Style")
        }
        expect(document.board.elements[circle.id]?.node?.style.fill == "#4A90D9",
               "selection restyle lands")
        document.undoManager?.undo()
        expect(document.board.elements[circle.id]?.node?.style.fill == Style.noFill,
               "restyle is one undo step (fill back to the drawn no-fill)")

        // Cleanup: ink, circle, send-to-back, rect.
        for _ in 0..<4 { document.undoManager?.undo() }
        canvasView.pendingInkStyle = Style(strokeWidth: 2)
        canvasView.pendingShapeStyle = Style(fill: Style.noFill)
    }

    /// Regression: at high zoom the auto-opened label editor used to balloon
    /// (sized from the zoomed rect) and blanket the toolbar, swallowing clicks
    /// to Layers/Assistant. The field must stay clamped + clear of the toolbar
    /// band, and the panels must still open.
    private func step26LabelEditorNeverBlanketsToolbar() {
        guard let controller = window.contentViewController as? CanvasViewController else {
            expect(false, "no controller for editor-clamp test"); return
        }
        let savedViewport = canvasView.viewport
        canvasView.viewport = CanvasViewport(origin: Point(x: -20, y: 4900), scale: 13)
        pumpRunLoop()

        // Create a block near the TOP of the view (double-click) — opens the
        // label editor; a naive field would cover the toolbar.
        let topPoint = CGPoint(x: canvasView.bounds.midX, y: 96)
        click(at: topPoint, clickCount: 1)
        click(at: topPoint, clickCount: 2)
        pumpRunLoop()

        if let field = canvasView.labelEditorFrameForTesting {
            expect(field.width <= 341, "label editor width is clamped (got \(field.width))")
            expect(field.height <= 42, "label editor height is clamped (got \(field.height))")
            expect(field.minY >= 60, "label editor stays below the toolbar band (minY=\(field.minY))")
            expect(field.maxY <= canvasView.bounds.height + 1, "label editor stays in view")
        } else {
            expect(false, "expected an open label editor after creating a block at high zoom")
        }

        // Commit the editor (click empty canvas), then the Layers panel must
        // still open on demand.
        canvasView.viewport = savedViewport
        pumpRunLoop()
        canvasView.commitLabelEditor()
        pumpRunLoop()
        controller.toggleLayersPanel(nil)
        pumpRunLoop()
        expect(controller.layersPanelIsOpenForTesting, "Layers panel opens after high-zoom editing")
        controller.toggleLayersPanel(nil)
        pumpRunLoop()
        document.undoManager?.undo() // remove the test block
        pumpRunLoop()
    }

    /// Real synthesized mouse movement (not model inserts): dragging a shape
    /// MOVES it, a drag next to another shape SNAPS into edge alignment, and
    /// dragging one onto another produces an OVERLAP. (Connector-vs-shape
    /// recognition by real stroke is covered by steps 10/11.)
    private func step27SnapOverlapDragByMouse() {
        let layer = document.board.layers[0].id
        func node(_ name: String, _ x: Double, _ y: Double) -> Element {
            Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                    content: .node(Node(semantic: NodeSemantic(name: name),
                                        frame: Rect(x: x, y: y, width: 120, height: 60))))
        }
        // Two isolated, non-overlapping subjects in a clear region.
        let c = node("mm-c", 0, 5460), d = node("mm-d", 320, 5460)
        document.perform(.batch([.insertElement(c), .insertElement(d)]), actionName: "Mouse Drag Subjects")
        // Explicit 1x viewport with the subjects mid-screen, clear of the
        // toolbar band (reveal would zoom far out on the cluttered board).
        canvasView.viewport = CanvasViewport(origin: Point(x: -320, y: 5300), scale: 1)
        canvasView.select([])
        pumpRunLoop()

        func frame(_ id: ElementID) -> Rect { document.board.elements[id]!.node!.frame }
        func drag(fromWorld: Point, toWorld: Point, steps: Int = 8) {
            let from = canvasView.viewport.toView(fromWorld)
            let to = canvasView.viewport.toView(toWorld)
            send(.leftMouseDown, at: from, clickCount: 1)
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                send(.leftMouseDragged, at: CGPoint(
                    x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), clickCount: 1)
            }
            send(.leftMouseUp, at: to, clickCount: 1)
            pumpRunLoop()
        }

        // (1) Drag D so its left edge lands a few units off C's left edge
        // (x=0): the node MOVES, and SnapEngine pulls the edges into exact
        // alignment. Target center = 4 (left edge) + 60 (half-width).
        let dBefore = frame(d.id)
        drag(fromWorld: Point(x: frame(d.id).midX, y: frame(d.id).midY),
             toWorld: Point(x: 64, y: 5620))
        expect(frame(d.id) != dBefore, "dragging a shape moves it")
        expect(abs(frame(d.id).x - frame(c.id).x) < 1.5,
               "dragging D beside C snaps their left edges into alignment (dx=\(frame(d.id).x - frame(c.id).x))")

        // (2) Drag D fully onto C -> the frames OVERLAP.
        canvasView.select([])
        pumpRunLoop()
        drag(fromWorld: Point(x: frame(d.id).midX, y: frame(d.id).midY),
             toWorld: Point(x: frame(c.id).midX, y: frame(c.id).midY))
        expect(frame(c.id).intersects(frame(d.id)), "shapes dragged together overlap")

        for _ in 0..<3 { document.undoManager?.undo() } // 2 drags + insert
        pumpRunLoop()
    }

    /// Style-panel polish round: S pops the shape picker like the toolbar
    /// button, undoing a fresh shape keeps the panel open, web SVG paste
    /// lands as an image block, connector selection styles through the
    /// panel's connector mode.
    private func step28StylePanelPolish() {
        guard let controller = window.contentViewController as? CanvasViewController else {
            expect(false, "no controller for style-panel polish"); return
        }

        // (1) "s" requests the shape picker popup, same as the button.
        key(1, characters: "s")
        pumpRunLoop()
        expect(controller.shapePickerVisibleForTesting, "'s' pops the shape picker")
        key(1, characters: "s")
        pumpRunLoop()
        expect(!controller.shapePickerVisibleForTesting, "'s' toggles the picker closed")

        // (2) Undo after creating a shape empties the selection, which hides
        // the style panel (nothing stylable is selected in the select tool).
        canvasView.viewport = CanvasViewport(origin: Point(x: -320, y: 5900), scale: 1)
        canvasView.pendingShapeStyle = Style(fill: Style.noFill)
        canvasView.activateShapeTool(shape: .rectangle, lockAspect: false)
        pumpRunLoop()
        let from = canvasView.viewport.toView(Point(x: 40, y: 6000))
        let to = canvasView.viewport.toView(Point(x: 260, y: 6120))
        send(.leftMouseDown, at: from, clickCount: 1)
        for step in 1...5 {
            let t = CGFloat(step) / 5
            send(.leftMouseDragged, at: CGPoint(
                x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), clickCount: 1)
        }
        send(.leftMouseUp, at: to, clickCount: 1)
        pumpRunLoop()
        expect(controller.stylePanelModel.isVisible, "panel visible after drawing a shape")
        document.undoManager?.undo()
        pumpRunLoop()
        expect(!controller.stylePanelModel.isVisible,
               "undoing the fresh shape empties the selection, hiding the style panel")

        // (3) A web-copied SVG pastes as an image block.
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"80\" height=\"60\"><rect width=\"80\" height=\"60\" fill=\"#4A90D9\"/></svg>"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("some page text \(svg) trailing", forType: .string)
        let nodesBefore = document.board.elements.values.filter { $0.node != nil }.count
        canvasView.paste(nil)
        pumpRunLoop()
        let pasted = document.board.elementsInZOrder.reversed()
            .compactMap(\.node).first
        expect(document.board.elements.values.filter { $0.node != nil }.count == nodesBefore + 1,
               "SVG paste creates a block")
        expect(pasted?.style.image?.hasPrefix("data:image/svg") == true,
               "pasted block carries the SVG as its image")
        document.undoManager?.undo()
        pumpRunLoop()

        // (4) Selecting a connector puts the panel in connector mode.
        let layer = document.board.layers[0].id
        let a = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                        content: .node(Node(semantic: NodeSemantic(name: "cs-a"),
                                            frame: Rect(x: 0, y: 6300, width: 120, height: 60))))
        let b = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                        content: .node(Node(semantic: NodeSemantic(name: "cs-b"),
                                            frame: Rect(x: 400, y: 6300, width: 120, height: 60))))
        let e = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                        content: .edge(Edge(from: .element(a.id, side: nil, offset: nil),
                                            to: .element(b.id, side: nil, offset: nil))))
        document.perform(.batch([.insertElement(a), .insertElement(b), .insertElement(e)]),
                         actionName: "Connector Style Graph")
        canvasView.select([e.id])
        pumpRunLoop()
        expect(controller.stylePanelModel.mode == .connector,
               "selecting a connector switches the panel to connector mode")
        document.undoManager?.undo()
        pumpRunLoop()
        canvasView.select([])
        pumpRunLoop()
        expect(!controller.stylePanelModel.isVisible,
               "deselecting a connector hides the style panel (no revert to shape mode)")
    }

    /// Caption visibility mode (Always / On Focus / Off) plus the one-time
    /// density nudge that suggests On Focus once a board gets busy.
    private func step30CaptionModeAndDensityNudge() {
        guard let controller = window.contentViewController as? CanvasViewController else {
            expect(false, "no controller for caption/density"); return
        }
        let layer = document.board.layers[0].id
        let a = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                        content: .node(Node(semantic: NodeSemantic(name: "dense-a"),
                                            frame: Rect(x: 0, y: 6600, width: 120, height: 60))))
        let b = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                        content: .node(Node(semantic: NodeSemantic(name: "dense-b"),
                                            frame: Rect(x: 400, y: 6600, width: 120, height: 60))))
        var ops: [BoardOperation] = [.insertElement(a), .insertElement(b)]
        var edgeIDs: [ElementID] = []
        // One past the threshold — enough to trip the nudge.
        for _ in 0...CanvasViewController.densitySuggestionThreshold {
            let e = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                            content: .edge(Edge(from: .element(a.id, side: nil, offset: nil),
                                                to: .element(b.id, side: nil, offset: nil))))
            edgeIDs.append(e.id)
            ops.append(.insertElement(e))
        }
        document.perform(.batch(ops), actionName: "Dense Graph")
        pumpRunLoop()
        expect(controller.densitySuggestionModel.isVisible,
               "density nudge appears once the connector count crosses the threshold")

        // Dismiss, add one more connector: it must NOT re-fire (shown once).
        controller.densitySuggestionModel.isVisible = false
        let extra = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                            content: .edge(Edge(from: .element(a.id, side: nil, offset: nil),
                                                to: .element(b.id, side: nil, offset: nil))))
        document.perform(.insertElement(extra), actionName: "One More Connector")
        pumpRunLoop()
        expect(!controller.densitySuggestionModel.isVisible,
               "the nudge does not re-fire for every new connector past the threshold")

        // Caption mode cycles through all three states (undoable, via extra).
        controller.applyCaptionMode(.onFocus)
        expect(document.board.captionMode == .onFocus, "switch to On Focus")
        controller.applyCaptionMode(.off)
        expect(document.board.captionMode == .off, "switch to Off")
        controller.applyCaptionMode(.always)
        expect(document.board.captionMode == .always, "back to Always clears the setting")

        let cleanup = (edgeIDs + [extra.id, a.id, b.id]).filter { document.board.elements[$0] != nil }
        document.perform(.batch(cleanup.map { .removeElement($0) }), actionName: "Cleanup Dense Graph")
        pumpRunLoop()
    }

    /// Rubber-band selection must test the connector's actual line, not its
    /// (endpoint-spanning) bounding box — a band in the empty diagonal space
    /// a connector crosses used to grab it.
    private func step31RubberBandExcludesDistantConnector() {
        let layer = document.board.layers[0].id
        let a = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                        content: .node(Node(semantic: NodeSemantic(name: "rb-a"),
                                            frame: Rect(x: 0, y: 7100, width: 20, height: 20))))
        let b = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                        content: .node(Node(semantic: NodeSemantic(name: "rb-b"),
                                            frame: Rect(x: 600, y: 6900, width: 20, height: 20))))
        let edge = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                           content: .edge(Edge(from: .element(a.id, side: nil, offset: nil),
                                               to: .element(b.id, side: nil, offset: nil))))
        document.perform(.batch([.insertElement(a), .insertElement(b), .insertElement(edge)]),
                         actionName: "Rubber-band Graph")
        canvasView.reveal(worldRect: Rect(x: -40, y: 6850, width: 720, height: 480))
        pumpRunLoop()

        func rubberBand(from w1: Point, to w2: Point) {
            canvasView.select([])
            pumpRunLoop()
            let p1 = canvasView.viewport.toView(w1)
            let p2 = canvasView.viewport.toView(w2)
            send(.leftMouseDown, at: p1, clickCount: 1)
            for step in 1...5 {
                let t = CGFloat(step) / 5
                send(.leftMouseDragged, at: CGPoint(
                    x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t), clickCount: 1)
            }
            send(.leftMouseUp, at: p2, clickCount: 1)
            pumpRunLoop()
        }

        // A box in the top-left empty space: inside the route's bbox, far from
        // the line.
        rubberBand(from: Point(x: 60, y: 6900), to: Point(x: 120, y: 6960))
        expect(!canvasView.selection.contains(edge.id),
               "rubber-band over empty diagonal space does NOT grab the connector")
        // A box straddling the line near its midpoint really crosses it.
        rubberBand(from: Point(x: 250, y: 6960), to: Point(x: 360, y: 7040))
        expect(canvasView.selection.contains(edge.id),
               "rubber-band crossing the connector line selects it")
        // Nodes still select on partial overlap (intentional, unchanged).
        rubberBand(from: Point(x: 560, y: 6880), to: Point(x: 612, y: 6912))
        expect(canvasView.selection.contains(b.id),
               "rubber-band partially overlapping a node still selects it")

        canvasView.select([])
        document.perform(.batch([.removeElement(edge.id), .removeElement(a.id), .removeElement(b.id)]),
                         actionName: "Cleanup Rubber-band Graph")
        pumpRunLoop()
    }

    /// Dragging a connector endpoint onto a block pins it to a discrete anchor
    /// slot (fixed side + offset) rather than the auto (nil) anchor, so it can
    /// be re-placed to de-clutter a busy attachment.
    private func step32EndpointSnapsToDiscreteSlot() {
        let layer = document.board.layers[0].id
        let a = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                        content: .node(Node(semantic: NodeSemantic(name: "slot-a"),
                                            frame: Rect(x: 0, y: 7400, width: 120, height: 120))))
        let b = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                        content: .node(Node(semantic: NodeSemantic(name: "slot-b"),
                                            frame: Rect(x: 420, y: 7400, width: 120, height: 120))))
        let edge = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                           content: .edge(Edge(from: .element(a.id, side: nil, offset: nil),
                                               to: .element(b.id, side: nil, offset: nil))))
        document.perform(.batch([.insertElement(a), .insertElement(b), .insertElement(edge)]),
                         actionName: "Anchor-slot Graph")
        canvasView.reveal(worldRect: Rect(x: -40, y: 7350, width: 640, height: 240))
        canvasView.select([edge.id])
        pumpRunLoop()

        func currentEdge() -> Edge? { document.board.elements[edge.id]?.edge }
        guard let route = EdgeGeometry.route(
            for: currentEdge()!, frames: document.board.frameProvider()) else {
            expect(false, "no route for anchor-slot edge"); return
        }
        // Grab the arrival grip (at b) and drag it up toward b's top edge, so it
        // snaps to a top-face slot rather than the default facing-side midpoint.
        let endView = canvasView.viewport.toView(route.end)
        let target = canvasView.viewport.toView(Point(x: 450, y: 7402))
        send(.leftMouseDown, at: endView, clickCount: 1)
        for step in 1...5 {
            let t = CGFloat(step) / 5
            send(.leftMouseDragged, at: CGPoint(
                x: endView.x + (target.x - endView.x) * t,
                y: endView.y + (target.y - endView.y) * t), clickCount: 1)
        }
        send(.leftMouseUp, at: target, clickCount: 1)
        pumpRunLoop()

        if case .element(let id, let side, let offset)? = currentEdge()?.to {
            expect(id == b.id, "endpoint stays attached to the target block")
            expect(side != nil && offset != nil,
                   "dropping on a block pins the endpoint to a discrete slot (non-nil side+offset)")
            expect(side == .top, "dragging toward the top edge snaps to the top face")
        } else {
            expect(false, "endpoint should remain attached to a block, not detach")
        }

        canvasView.select([])
        document.perform(.batch([.removeElement(edge.id), .removeElement(a.id), .removeElement(b.id)]),
                         actionName: "Cleanup Anchor-slot Graph")
        pumpRunLoop()
    }

    /// I1: a no-fill (grouping) rectangle's BORDER selects + moves — it must
    /// NOT be hijacked into starting a connector, and no connector is created.
    private func step33NoFillRectBorderMovesNotConnect() {
        let layer = document.board.layers[0].id
        let rectEl = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
            content: .node(Node(semantic: NodeSemantic(name: ""),
                                frame: Rect(x: 100, y: 7000, width: 260, height: 160),
                                shape: .rectangle, style: Style(fill: Style.noFill))))
        document.perform(.insertElement(rectEl), actionName: "No-fill Move Test")
        // 1x viewport, rect mid-screen, clear of the left style panel (view x > 300).
        canvasView.viewport = CanvasViewport(origin: Point(x: -320, y: 6900), scale: 1)
        canvasView.select([])
        pumpRunLoop()

        func frame() -> Rect { document.board.elements[rectEl.id]!.node!.frame }
        let edgesBefore = document.board.elements.values.compactMap(\.edge).count
        let before = frame()
        // Mousedown on the TOP BORDER (not the hollow interior), then drag.
        let border = canvasView.viewport.toView(Point(x: before.midX, y: before.y))
        let target = CGPoint(x: border.x + 90, y: border.y + 70)
        send(.leftMouseDown, at: border, clickCount: 1)
        for step in 1...6 {
            let t = CGFloat(step) / 6
            send(.leftMouseDragged, at: CGPoint(x: border.x + (target.x - border.x) * t,
                                                y: border.y + (target.y - border.y) * t), clickCount: 1)
        }
        send(.leftMouseUp, at: target, clickCount: 1)
        pumpRunLoop()

        expect(frame() != before, "dragging a no-fill rect's border MOVES it (was \(before), now \(frame()))")
        expect(abs(frame().x - (before.x + 90)) < 8 && abs(frame().y - (before.y + 70)) < 8,
               "no-fill rect moved by ~the drag delta (got \(frame()))")
        expect(document.board.elements.values.compactMap(\.edge).count == edgesBefore,
               "border-drag on a no-fill rect does NOT create a connector")

        document.undoManager?.undo() // move
        document.undoManager?.undo() // insert
        pumpRunLoop()
    }

    /// I4: dragging a freehand DRAWING renders the stroke at the moved position
    /// mid-drag (not stuck at the origin with only the snap guides moving).
    private func step34InkDragShowsStrokeMoving() {
        let layer = document.board.layers[0].id
        var pts: [StrokePoint] = []
        for i in 0...12 {
            let f = Double(i) / 12
            pts.append(StrokePoint(x: 160 + f * 180, y: 7420 + f * 30))
        }
        let inkEl = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
            content: .ink(Ink(points: pts, style: Style(stroke: "#D95757", strokeWidth: 4))))
        document.perform(.insertElement(inkEl), actionName: "Ink Move Test")
        canvasView.viewport = CanvasViewport(origin: Point(x: -320, y: 7320), scale: 1)
        canvasView.select([inkEl.id]) // selected → movable
        pumpRunLoop()

        let from = canvasView.viewport.toView(Point(x: 250, y: 7430)) // a point on the stroke
        let to = CGPoint(x: from.x + 130, y: from.y + 90)
        send(.leftMouseDown, at: from, clickCount: 1)
        for step in 1...6 {
            let t = CGFloat(step) / 6
            send(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t,
                                                y: from.y + (to.y - from.y) * t), clickCount: 1)
        }
        // Render MID-DRAG (before mouseUp) and assert the stroke is drawn at the
        // moved position — the I4 fix. Scene is isolated so any non-background
        // pixel near the dragged point is the stroke.
        if let bitmap = canvasView.bitmapImageRepForCachingDisplay(in: canvasView.bounds) {
            canvasView.cacheDisplay(in: canvasView.bounds, to: bitmap)
            let sx = CGFloat(bitmap.pixelsWide) / canvasView.bounds.width
            let sy = CGFloat(bitmap.pixelsHigh) / canvasView.bounds.height
            func px(_ p: CGPoint) -> NSColor? { bitmap.colorAt(x: Int(p.x * sx), y: Int(p.y * sy)) }
            let bg = px(CGPoint(x: 5, y: 5))
            func hasStroke(near c: CGPoint, radius: Int) -> Bool {
                for dx in -radius...radius {
                    for dy in -radius...radius where px(CGPoint(x: c.x + CGFloat(dx), y: c.y + CGFloat(dy))) != bg {
                        return true
                    }
                }
                return false
            }
            expect(hasStroke(near: to, radius: 9),
                   "mid-drag: the ink stroke renders at the moved position (I4)")
        } else {
            expect(false, "no bitmap for ink-drag render")
        }
        send(.leftMouseUp, at: to, clickCount: 1)
        pumpRunLoop()
        if case .ink(let ink)? = document.board.elements[inkEl.id]?.content, let first = ink.points.first {
            expect(first.x > pts[0].x + 60, "ink committed to the moved position (got x=\(first.x))")
        } else {
            expect(false, "ink stroke missing after move")
        }
        document.undoManager?.undo() // move
        document.undoManager?.undo() // insert
        pumpRunLoop()
    }

    /// I5: dragging a connector endpoint into the HOLLOW interior of a no-fill
    /// grouping rectangle must NOT snap onto that rect (it stays free).
    private func step35EndpointIgnoresNoFillGroupRect() {
        let layer = document.board.layers[0].id
        func node(_ name: String, _ x: Double) -> Element {
            Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                    content: .node(Node(semantic: NodeSemantic(name: name),
                                        frame: Rect(x: x, y: 7900, width: 100, height: 56))))
        }
        let a = node("ep-a", 100), b = node("ep-b", 560)
        let group = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
            content: .node(Node(semantic: NodeSemantic(name: ""),
                                frame: Rect(x: 250, y: 7820, width: 240, height: 220),
                                shape: .rectangle, style: Style(fill: Style.noFill))))
        document.perform(.batch([.insertElement(a), .insertElement(b), .insertElement(group)]),
                         actionName: "Endpoint Snap Test")
        let edge = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
            content: .edge(Edge(from: .element(a.id, side: nil, offset: nil),
                                to: .element(b.id, side: nil, offset: nil))))
        document.perform(.insertElement(edge), actionName: "Endpoint Snap Edge")
        canvasView.viewport = CanvasViewport(origin: Point(x: -320, y: 7760), scale: 1)
        canvasView.select([edge.id])
        pumpRunLoop()

        func currentEdge() -> DesignerModel.Edge? { document.board.elements[edge.id]?.edge }
        guard let route = EdgeGeometry.route(for: currentEdge()!, frames: document.board.frameProvider()) else {
            expect(false, "no route for endpoint test"); return
        }
        // Drag the 'to' grip into the group rect's hollow interior (away from
        // a/b and away from the group's own border).
        let endView = canvasView.viewport.toView(route.end)
        let intoGroup = canvasView.viewport.toView(Point(x: 370, y: 7930))
        send(.leftMouseDown, at: endView, clickCount: 1)
        for step in 1...6 {
            let t = CGFloat(step) / 6
            send(.leftMouseDragged, at: CGPoint(x: endView.x + (intoGroup.x - endView.x) * t,
                                                y: endView.y + (intoGroup.y - endView.y) * t), clickCount: 1)
        }
        send(.leftMouseUp, at: intoGroup, clickCount: 1)
        pumpRunLoop()
        expect(currentEdge()?.to.elementID != group.id,
               "endpoint dropped in a no-fill group's interior does NOT attach to the group (I5)")
        expect(currentEdge()?.to.elementID == nil,
               "endpoint in the hollow interior stays free/dangling (I5)")

        document.undoManager?.undo() // detach
        document.undoManager?.undo() // edge insert
        document.undoManager?.undo() // nodes
        pumpRunLoop()
    }

    /// Linked boards: link a node to another board, dive in via the badge
    /// (double-click), verify the read-only nested view + banner, verify
    /// Back restores the EXACT camera, and that nesting depth works.
    private func step29LinkedBoards() {
        guard let controller = window.contentViewController as? CanvasViewController else {
            expect(false, "no controller for linked boards"); return
        }

        // A target board saved into the managed catalog folder.
        var target = Board(title: "UI-Test Linked Target")
        try? target.apply(.insertElement(Element(
            layerIDs: [target.layers[0].id], sortKey: target.topSortKey,
            content: .node(Node(semantic: NodeSemantic(name: "inner-block"),
                                frame: Rect(x: 100, y: 100, width: 160, height: 80))))))
        let folder = BoardCatalog.boardsFolder()
        let targetURL = folder.appendingPathComponent("ui-test-linked-\(UUID().uuidString.prefix(6)).designerboard")
        defer { try? FileManager.default.trashItem(at: targetURL, resultingItemURL: nil) }
        do { try BoardPackage.write(target, to: targetURL) } catch {
            expect(false, "couldn't write linked target board"); return
        }

        // A linked node on the working board.
        let layer = document.board.layers[0].id
        var semantic = NodeSemantic(name: "drill-me")
        semantic.linkedBoardID = target.id
        let node = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                           content: .node(Node(semantic: semantic,
                                               frame: Rect(x: 100, y: 6600, width: 140, height: 70))))
        document.perform(.insertElement(node), actionName: "Linked Node")
        canvasView.viewport = CanvasViewport(origin: Point(x: -320, y: 6450), scale: 1)
        canvasView.select([])
        pumpRunLoop()

        // The badge is hit-testable at its rect (outside the node frame).
        let badge = canvasView.linkBadgeRect(forNodeFrame: Rect(x: 100, y: 6600, width: 140, height: 70))
        expect(canvasView.linkBadgeHit(at: CGPoint(x: badge.midX, y: badge.midY)) == node.id,
               "the top-right badge hit-tests to the linked node")

        // Dive in via double-click on the badge; wait out the animation.
        let savedViewport = canvasView.viewport
        let rootElementCount = document.board.elements.count
        click(at: CGPoint(x: badge.midX, y: badge.midY), clickCount: 1)
        click(at: CGPoint(x: badge.midX, y: badge.midY), clickCount: 2)
        var waited = 0.0
        while canvasView.board.id != target.id, waited < 3 {
            pumpRunLoop(); waited += 0.05
        }
        expect(canvasView.board.id == target.id, "double-clicking the badge enters the linked board")
        expect(canvasView.isReadOnly, "the linked view is read-only")
        expect(controller.linkedViewModel.isActive, "the linked-view banner is active")
        expect(controller.linkedViewModel.title == "UI-Test Linked Target", "banner shows the linked title")

        // Edits must not land: a double-click that would create a block does
        // nothing to either board.
        let innerCount = canvasView.board.elements.count
        click(at: CGPoint(x: 700, y: 400), clickCount: 2)
        pumpRunLoop()
        expect(canvasView.board.elements.count == innerCount, "read-only view blocks creation")
        expect(document.board.elements.count == rootElementCount, "the DOCUMENT board is untouched")

        // Back restores the exact camera.
        controller.exitLinkedBoard()
        waited = 0
        while canvasView.viewport != savedViewport, waited < 3 {
            pumpRunLoop(); waited += 0.05
        }
        expect(canvasView.board.id == document.board.id, "Back returns to the document board")
        expect(!canvasView.isReadOnly, "editing is re-enabled after Back")
        expect(canvasView.viewport == savedViewport,
               "Back restores the EXACT prior camera (got \(canvasView.viewport) want \(savedViewport))")
        expect(!controller.linkedViewModel.isActive, "banner dismissed at root")

        // Depth 2: enter, then enter again through a linked node INSIDE the
        // target (link it to the document board is disallowed—link to a third).
        var third = Board(title: "UI-Test Third Level")
        let thirdURL = folder.appendingPathComponent("ui-test-third-\(UUID().uuidString.prefix(6)).designerboard")
        defer { try? FileManager.default.trashItem(at: thirdURL, resultingItemURL: nil) }
        try? BoardPackage.write(third, to: thirdURL)
        var innerSemantic = NodeSemantic(name: "deeper")
        innerSemantic.linkedBoardID = third.id
        try? target.apply(.insertElement(Element(
            layerIDs: [target.layers[0].id], sortKey: target.topSortKey,
            content: .node(Node(semantic: innerSemantic,
                                frame: Rect(x: 400, y: 100, width: 140, height: 70))))))
        try? BoardPackage.write(target, to: targetURL)

        controller.enterLinkedBoard(from: node.id)
        waited = 0
        while canvasView.board.id != target.id, waited < 3 { pumpRunLoop(); waited += 0.05 }
        guard let deeper = canvasView.board.elements.values.first(where: {
            $0.node?.semantic.name == "deeper"
        }) else { expect(false, "no deeper node after re-entry"); return }
        controller.enterLinkedBoard(from: deeper.id)
        waited = 0
        while canvasView.board.id != third.id, waited < 3 { pumpRunLoop(); waited += 0.05 }
        expect(canvasView.board.id == third.id, "nesting to depth 2 works")
        expect(controller.linkedViewModel.depth == 2, "banner reports depth 2")
        controller.exitLinkedBoard()
        pumpRunLoop()
        expect(controller.linkedViewModel.depth == 1, "popping one level reports depth 1")
        controller.exitLinkedBoard()
        waited = 0
        while controller.linkedViewModel.isActive, waited < 3 { pumpRunLoop(); waited += 0.05 }
        expect(!canvasView.isReadOnly, "back at the editable root")

        document.undoManager?.undo() // the linked node
        pumpRunLoop()
    }

    // MARK: Event synthesis

    private func click(at point: CGPoint, clickCount: Int) {
        send(.leftMouseDown, at: point, clickCount: clickCount)
        send(.leftMouseUp, at: point, clickCount: clickCount)
    }

    private func send(_ type: NSEvent.EventType, at viewPoint: CGPoint, clickCount: Int) {
        // View is flipped; window coordinates are bottom-left origin.
        let windowPoint = canvasView.convert(viewPoint, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ) else { return }
        window.sendEvent(event)
    }

    private func keyEvent(_ type: NSEvent.EventType, keyCode: UInt16, characters: String) {
        guard let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ) else { return }
        window.sendEvent(event)
    }

    private func key(_ keyCode: UInt16, characters: String = "\r") {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ) else { continue }
            window.sendEvent(event)
        }
    }

    private func pumpRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func expect(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }
}
