import AppKit
import SwiftUI
import DesignerModel
import DesignerPersistence

final class BoardDocument: NSDocument, ObservableObject {
    @Published var board = Board(title: "Untitled")

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let hostingController = NSHostingController(
            rootView: BoardPlaceholderView(document: self)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 960, height: 640))
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

    // MARK: Temporary M0 mutations (replaced by the operation layer in M1)

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
        board.elements.append(node)
        updateChangeCount(.changeDone)
    }
}
