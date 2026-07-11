import AppKit
import DesignerCanvas
import DesignerModel
import DesignerPersistence

final class BoardDocument: NSDocument, ObservableObject {
    @Published var board = Board(title: "Untitled")

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let window = NSWindow(contentViewController: CanvasViewController(document: self))
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.styleMask.insert([.resizable, .miniaturizable, .closable, .titled])
        window.center()
        addWindowController(NSWindowController(window: window))
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        var snapshot = board
        snapshot.modifiedAt = Date().millisecondRounded
        return try BoardPackage.fileWrapper(for: snapshot)
    }

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        let loaded = try BoardPackage.board(from: fileWrapper)
        if Thread.isMainThread {
            board = loaded
        } else {
            DispatchQueue.main.sync { board = loaded }
        }
    }

    // MARK: Mutations

    /// All document changes flow through here: applies the operation and
    /// registers its inverse with the undo manager, which also drives
    /// NSDocument's change tracking and autosave.
    func perform(_ operation: BoardOperation, actionName: String) {
        DesignerCanvas.CanvasView.debugTrace?("document.perform \(actionName)")
        do {
            let inverse = try board.apply(operation)
            guard let undoManager else { return }
            // One operation = exactly one undo step. AppKit's default
            // per-event grouping would merge operations that happen to share
            // a runloop cycle (e.g. a label commit followed by a connect in
            // one event, or future agent batches) into a single undo.
            undoManager.groupsByEvent = false
            let needsGroup = !undoManager.isUndoing && !undoManager.isRedoing
            if needsGroup { undoManager.beginUndoGrouping() }
            undoManager.registerUndo(withTarget: self) { document in
                document.perform(inverse, actionName: actionName)
            }
            undoManager.setActionName(actionName)
            if needsGroup { undoManager.endUndoGrouping() }
        } catch {
            presentError(error)
        }
    }

    func addSampleNode() {
        let baseLayer = board.layers[0]
        let count = board.elements.count
        let node = Element(
            layerIDs: [baseLayer.id],
            sortKey: board.topSortKey,
            content: .node(Node(
                semantic: NodeSemantic(kind: .service, name: "service-\(count + 1)"),
                frame: Rect(
                    x: 80 + Double(count % 8) * 190,
                    y: 80 + Double(count / 8) * 120,
                    width: 160, height: 80
                )
            ))
        )
        perform(.insertElement(node), actionName: "Add Block")
    }
}
