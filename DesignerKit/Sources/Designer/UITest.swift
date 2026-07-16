import AppKit
import DesignerCanvas
import DesignerInterop
import DesignerModel

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

        if failures.isEmpty {
            print("UI-TEST PASS: create, label, drag, render, undo, connect, follow, dangling+snap-in, ink, sketch-to-structure, layers, library, llm+export, simulate, clipboard, agent-proposal, flows, groups+boundaries, inspector, versions, bend, parallel-connect, empty-ghost, space-pan, endpoint-reattach verified")
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

        // Straighten: drag the bend back onto the straight line.
        guard let bentRoute = EdgeGeometry.route(
            for: document.board.elements[edgeElement.id]!.edge!,
            frames: document.board.frameProvider()) else {
            expect(false, "no bent route")
            return
        }
        canvasView.select([edgeElement.id])
        let bendView = canvasView.viewport.toView(bentRoute.point(atFraction: 0.5))
        send(.leftMouseDown, at: bendView, clickCount: 1)
        for step in 1...5 {
            let t = CGFloat(step) / 5
            send(.leftMouseDragged, at: CGPoint(
                x: bendView.x + (midView.x - bendView.x) * t,
                y: bendView.y + (midView.y - bendView.y) * t
            ), clickCount: 1)
        }
        send(.leftMouseUp, at: midView, clickCount: 1)
        pumpRunLoop()
        expect(currentWaypoints().isEmpty, "dropping on the line should straighten")

        document.undoManager?.undo() // straighten
        document.undoManager?.undo() // bend
        document.undoManager?.undo() // test graph
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
