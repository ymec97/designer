import XCTest
import DesignerModel
@testable import DesignerCanvas

/// Throwaway visual check for P5 — renders detours + a manual bend to a PNG.
/// Always skipped unless ROUTING_PNG is set. (Delete freely.)
final class RoutingVisualCheck: XCTestCase {
    func testRenderRoutingScenario() throws {
        guard let outPath = ProcessInfo.processInfo.environment["ROUTING_PNG"] else {
            throw XCTSkip("set ROUTING_PNG to render")
        }
        var board = Board(title: "Routing")
        let layer = board.layers[0].id
        func node(_ name: String, _ x: Double, _ y: Double, w: Double = 130, h: Double = 60) -> ElementID {
            let e = Element(layerIDs: [layer], sortKey: board.topSortKey,
                            content: .node(Node(semantic: NodeSemantic(name: name),
                                                frame: Rect(x: x, y: y, width: w, height: h))))
            try! board.apply(.insertElement(e))
            return e.id
        }
        func edge(_ from: ElementID, _ to: ElementID, _ label: String, waypoints: [Point] = []) {
            let e = Element(layerIDs: [layer], sortKey: board.topSortKey,
                            content: .edge(Edge(semantic: EdgeSemantic(label: label),
                                                from: .element(from, side: nil, offset: nil),
                                                to: .element(to, side: nil, offset: nil),
                                                waypoints: waypoints)))
            try! board.apply(.insertElement(e))
        }
        // Row 1: a → b with a blocker in between (auto detour).
        let a = node("api", 0, 100)
        let b = node("orders", 700, 100)
        _ = node("cache (in the way)", 300, 80)
        edge(a, b, "detours")

        // Row 2: manual bend via waypoint.
        let c = node("web", 0, 400)
        let d = node("auth", 700, 400)
        edge(c, d, "manual bend", waypoints: [Point(x: 400, y: 560)])

        let image = try XCTUnwrap(BoardSnapshot.image(of: board, pointSize: CGSize(width: 1000, height: 620)))
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outPath))
    }
}
