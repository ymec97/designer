import AppKit
import DesignerCanvas
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
        step1CreateBlockByDoubleClick()
        step2TypeLabelAndCommit()
        step3DragBlock()
        step4RenderedPixels()
        step5UndoRedo()

        if failures.isEmpty {
            print("UI-TEST PASS: create, label, drag, render, undo all verified through sendEvent")
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

    private func key(_ keyCode: UInt16) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
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
