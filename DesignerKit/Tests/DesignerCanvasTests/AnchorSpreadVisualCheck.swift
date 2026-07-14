import XCTest
import DesignerModel
@testable import DesignerCanvas

/// Throwaway visual check — renders the anchor-spread scenario to a PNG for
/// eyeballing. Kept out of CI semantics: it always passes; the artifact is
/// the point. (Delete freely.)
final class AnchorSpreadVisualCheck: XCTestCase {
    func testRenderSpreadScenario() throws {
        guard let outPath = ProcessInfo.processInfo.environment["SPREAD_PNG"] else {
            throw XCTSkip("set SPREAD_PNG to render")
        }
        var board = Board(title: "Spread")
        let layer = board.layers[0].id
        func node(_ name: String, _ x: Double, _ y: Double) -> ElementID {
            let e = Element(layerIDs: [layer], sortKey: board.topSortKey,
                            content: .node(Node(semantic: NodeSemantic(name: name),
                                                frame: Rect(x: x, y: y, width: 120, height: 56))))
            try! board.apply(.insertElement(e))
            return e.id
        }
        func edge(_ from: ElementID, _ to: ElementID, _ label: String) {
            let e = Element(layerIDs: [layer], sortKey: board.topSortKey,
                            content: .edge(Edge(semantic: EdgeSemantic(label: label),
                                                from: .element(from, side: nil, offset: nil),
                                                to: .element(to, side: nil, offset: nil))))
            try! board.apply(.insertElement(e))
        }
        let gw = node("gateway", 0, 150)
        let svc = node("orders-svc", 420, 150)
        let auth = node("auth", 0, 0)
        let billing = node("billing", 0, 320)
        let db = node("Postgres", 840, 150)
        edge(gw, svc, "gRPC")
        edge(gw, svc, "HTTP")
        edge(auth, svc, "verify")
        edge(billing, svc, "charge")
        edge(svc, db, "SQL")

        let image = try XCTUnwrap(BoardSnapshot.image(of: board, pointSize: CGSize(width: 1100, height: 560)))
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outPath))
    }
}
