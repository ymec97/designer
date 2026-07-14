import XCTest
import DesignerModel
@testable import DesignerCanvas

/// P1 (zoom drift): new blocks are sized for the context you SEE — matching
/// visible neighbors, or readable at the current zoom on empty space.
final class CreationScaleTests: XCTestCase {
    private final class ApplyingDelegate: NSObject, CanvasViewDelegate {
        func canvasView(_ view: CanvasView, perform operation: BoardOperation, actionName: String) {
            var board = view.board
            try? board.apply(operation)
            view.board = board
        }
        func canvasViewDidChangeSelection(_ view: CanvasView) {}
    }

    private var view: CanvasView!
    private var delegate: ApplyingDelegate!

    override func setUp() {
        super.setUp()
        view = CanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        delegate = ApplyingDelegate()
        view.delegate = delegate
        view.board = Board(title: "P1")
    }

    private var insertedWidths: [Double] {
        view.board.elements.values.compactMap { $0.node?.frame.width }
    }

    func testDefaultSizeAtHundredPercent() {
        view.addBlock(kind: .service, shape: .rectangle)
        XCTAssertEqual(insertedWidths, [160])
    }

    func testEmptySpaceSizesForCurrentZoom() {
        view.viewport = CanvasViewport(origin: .zero, scale: 0.5)
        view.addBlock(kind: .service, shape: .rectangle)
        XCTAssertEqual(insertedWidths, [320], "zoomed out 2x → block twice as big in world space")
    }

    func testMatchesVisibleNeighborsOverZoomRule() {
        var board = Board(title: "P1")
        try! board.apply(.insertElement(Element(
            layerIDs: [board.layers[0].id], sortKey: board.topSortKey,
            content: .node(Node(semantic: NodeSemantic(name: "big"),
                                frame: Rect(x: 100, y: 100, width: 320, height: 160)))
        )))
        view.board = board
        view.viewport = CanvasViewport(origin: .zero, scale: 1)
        view.addBlock(kind: .service, shape: .rectangle)
        XCTAssertEqual(insertedWidths.sorted(), [320, 320],
                       "new block matches the visible neighbor, not the zoom rule")
    }

    func testExtremeZoomIsClamped() {
        view.viewport = CanvasViewport(origin: .zero, scale: 16)
        view.addBlock(kind: .service, shape: .rectangle)
        XCTAssertEqual(insertedWidths, [160 * 0.25], "creation factor clamps at 1/4")
    }
}
