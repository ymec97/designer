import XCTest
import DesignerModel
@testable import DesignerCanvas

/// Throwaway visual check for P3 — renders a hand-drawn board to a PNG.
/// Always skipped unless SKETCHY_PNG is set. (Delete freely.)
final class SketchyVisualCheck: XCTestCase {
    func testRenderSketchyScenario() throws {
        guard let outPath = ProcessInfo.processInfo.environment["SKETCHY_PNG"] else {
            throw XCTSkip("set SKETCHY_PNG to render")
        }
        var board = Board(title: "Sketchy")
        try board.apply(.setExtra(key: Board.sketchyExtraKey, value: .bool(true)))
        let layer = board.layers[0].id
        func node(_ name: String, kind: NodeKind, shape: NodeShape = .rectangle, _ x: Double, _ y: Double) -> ElementID {
            let e = Element(layerIDs: [layer], sortKey: board.topSortKey,
                            content: .node(Node(semantic: NodeSemantic(kind: kind, name: name),
                                                frame: Rect(x: x, y: y, width: 150, height: 64), shape: shape)))
            try! board.apply(.insertElement(e))
            return e.id
        }
        func edge(_ from: ElementID, _ to: ElementID, _ label: String) {
            let e = Element(layerIDs: [layer], sortKey: board.topSortKey,
                            content: .edge(Edge(semantic: EdgeSemantic(label: label, properties: ["protocol": "gRPC"]),
                                                from: .element(from, side: nil, offset: nil),
                                                to: .element(to, side: nil, offset: nil))))
            try! board.apply(.insertElement(e))
        }
        let client = node("client", kind: .client, 0, 150)
        let gw = node("gateway", kind: .gateway, 320, 150)
        let db = node("Postgres", kind: .database, shape: .ellipse, 660, 20)
        let queue = node("events", kind: .queue, shape: .diamond, 660, 300)
        edge(client, gw, "checkout")
        edge(gw, db, "persist")
        edge(gw, queue, "publish")

        let image = try XCTUnwrap(BoardSnapshot.image(of: board, pointSize: CGSize(width: 950, height: 480)))
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outPath))
    }
}
