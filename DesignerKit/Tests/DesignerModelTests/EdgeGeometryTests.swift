import XCTest
@testable import DesignerModel

final class EdgeGeometryTests: XCTestCase {
    private var board = Board(title: "Edges")
    private var layerID: LayerID { board.layers[0].id }

    @discardableResult
    private func addNode(_ name: String, frame: Rect) -> Element {
        let element = Element(
            layerIDs: [layerID],
            sortKey: board.topSortKey,
            content: .node(Node(semantic: NodeSemantic(name: name), frame: frame))
        )
        try! board.apply(.insertElement(element))
        return element
    }

    @discardableResult
    private func connect(
        _ from: Element, _ to: Element,
        routing: RoutingMode = .straight,
        fromSide: Anchor.Side? = nil, toSide: Anchor.Side? = nil
    ) -> Element {
        let edge = Element(
            layerIDs: [layerID],
            sortKey: board.topSortKey,
            content: .edge(Edge(
                from: .element(from.id, side: fromSide, offset: fromSide == nil ? nil : 0.5),
                to: .element(to.id, side: toSide, offset: toSide == nil ? nil : 0.5),
                routing: routing
            ))
        )
        try! board.apply(.insertElement(edge))
        return edge
    }

    private func route(_ edgeElement: Element, overrides: [ElementID: Rect] = [:]) -> EdgeGeometry.Route? {
        guard let edge = board.elements[edgeElement.id]?.edge else { return nil }
        return EdgeGeometry.route(for: edge, frames: board.frameProvider(overrides: overrides))
    }

    // MARK: Auto-side + anchoring

    func testAutoSideFacesTheOtherNode() throws {
        let left = addNode("a", frame: Rect(x: 0, y: 0, width: 100, height: 60))
        let right = addNode("b", frame: Rect(x: 400, y: 0, width: 100, height: 60))
        let edge = connect(left, right)

        let resolved = try XCTUnwrap(route(edge))
        // Leaves a's right side, enters b's left side.
        XCTAssertEqual(resolved.start.x, 100, accuracy: 1e-9)
        XCTAssertEqual(resolved.start.y, 30, accuracy: 1e-9)
        XCTAssertEqual(resolved.end.x, 400, accuracy: 1e-9)
        XCTAssertEqual(resolved.end.y, 30, accuracy: 1e-9)
    }

    func testVerticalAutoSide() throws {
        let top = addNode("a", frame: Rect(x: 0, y: 0, width: 100, height: 60))
        let bottom = addNode("b", frame: Rect(x: 0, y: 300, width: 100, height: 60))
        let edge = connect(top, bottom)

        let resolved = try XCTUnwrap(route(edge))
        XCTAssertEqual(resolved.start.y, 60, accuracy: 1e-9, "should leave bottom side")
        XCTAssertEqual(resolved.end.y, 300, accuracy: 1e-9, "should enter top side")
    }

    func testEdgeFollowsNodeMove() throws {
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 100, height: 60))
        let b = addNode("b", frame: Rect(x: 400, y: 0, width: 100, height: 60))
        let edge = connect(a, b)

        // Move b far below a — the route must re-anchor (auto sides flip).
        var moved = board.elements[b.id]!
        var node = moved.node!
        node.frame = Rect(x: 0, y: 500, width: 100, height: 60)
        moved.content = .node(node)
        try board.apply(.replaceElement(moved))

        let resolved = try XCTUnwrap(route(edge))
        XCTAssertEqual(resolved.start.y, 60, accuracy: 1e-9, "now leaves a's bottom")
        XCTAssertEqual(resolved.end.y, 500, accuracy: 1e-9, "now enters b's top")
    }

    func testTransientOverridesDriveRouting() throws {
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 100, height: 60))
        let b = addNode("b", frame: Rect(x: 400, y: 0, width: 100, height: 60))
        let edge = connect(a, b)

        let dragged = Rect(x: 800, y: 400, width: 100, height: 60)
        let resolved = try XCTUnwrap(route(edge, overrides: [b.id: dragged]))
        XCTAssertEqual(resolved.end.x, 800, accuracy: 1e-9, "route must use the in-flight frame")
    }

    func testFixedSideAndOffsetAreRespected() throws {
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 100, height: 60))
        let b = addNode("b", frame: Rect(x: 400, y: 0, width: 100, height: 60))
        let edgeElement = connect(a, b, fromSide: .top, toSide: .bottom)

        var element = board.elements[edgeElement.id]!
        var edge = element.edge!
        edge.from = .element(a.id, side: .top, offset: 0.25)
        element.content = .edge(edge)
        try board.apply(.replaceElement(element))

        let resolved = try XCTUnwrap(route(element))
        XCTAssertEqual(resolved.start.x, 25, accuracy: 1e-9)
        XCTAssertEqual(resolved.start.y, 0, accuracy: 1e-9)
        XCTAssertEqual(resolved.end.y, 60, accuracy: 1e-9)
    }

    func testDanglingAnchorYieldsNilRoute() {
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 100, height: 60))
        let ghost = Element(
            layerIDs: [layerID],
            sortKey: board.topSortKey,
            content: .edge(Edge(
                from: .element(a.id, side: nil, offset: nil),
                to: .element(ElementID(), side: nil, offset: nil)
            ))
        )
        try! board.apply(.insertElement(ghost))
        XCTAssertNil(route(ghost), "route to a missing element must be nil, not garbage")
    }

    // MARK: Orthogonal routing

    func testOrthogonalRouteHasOnlyAxisAlignedSegments() throws {
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 100, height: 60))
        let b = addNode("b", frame: Rect(x: 400, y: 300, width: 100, height: 60))
        let edge = connect(a, b, routing: .orthogonal)

        let resolved = try XCTUnwrap(route(edge))
        XCTAssertGreaterThanOrEqual(resolved.points.count, 4)
        for (p, q) in zip(resolved.points, resolved.points.dropFirst()) {
            XCTAssertTrue(
                abs(p.x - q.x) < 1e-9 || abs(p.y - q.y) < 1e-9,
                "orthogonal segment (\(p) → \(q)) must be axis-aligned"
            )
        }
    }

    func testManualWaypointsOverrideOrthogonal() throws {
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 100, height: 60))
        let b = addNode("b", frame: Rect(x: 400, y: 0, width: 100, height: 60))
        let edgeElement = connect(a, b, routing: .orthogonal)

        var element = board.elements[edgeElement.id]!
        var edge = element.edge!
        edge.waypoints = [Point(x: 250, y: 200)]
        element.content = .edge(edge)
        try board.apply(.replaceElement(element))

        let resolved = try XCTUnwrap(route(element))
        XCTAssertTrue(resolved.points.contains(Point(x: 250, y: 200)))
    }

    // MARK: Route math

    func testMidpointAndDistance() {
        let route = EdgeGeometry.Route(points: [
            Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 100),
        ])
        let mid = route.midpoint
        XCTAssertEqual(mid.x, 100, accuracy: 1e-9)
        XCTAssertEqual(mid.y, 0, accuracy: 1e-9)

        XCTAssertEqual(route.distance(to: Point(x: 50, y: 10)), 10, accuracy: 1e-9)
        XCTAssertEqual(route.distance(to: Point(x: 110, y: 50)), 10, accuracy: 1e-9)
        XCTAssertEqual(route.distance(to: Point(x: -10, y: 0)), 10, accuracy: 1e-9)
    }

    // MARK: Torture: anchors never detach

    func testMoveResizeUndoStormNeverDetaches() throws {
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 100, height: 60))
        let b = addNode("b", frame: Rect(x: 400, y: 0, width: 100, height: 60))
        let edge = connect(a, b, routing: .straight)

        var undoStack: [BoardOperation] = []
        var generator = SystemRandomNumberGenerator()

        for step in 0..<300 {
            let targetID = Bool.random(using: &generator) ? a.id : b.id
            var element = board.elements[targetID]!
            var node = element.node!
            if Bool.random(using: &generator) {
                node.frame = Rect(
                    x: Double.random(in: -2000...2000, using: &generator),
                    y: Double.random(in: -2000...2000, using: &generator),
                    width: node.frame.width, height: node.frame.height
                )
            } else {
                node.frame = Rect(
                    x: node.frame.x, y: node.frame.y,
                    width: Double.random(in: 24...600, using: &generator),
                    height: Double.random(in: 24...400, using: &generator)
                )
            }
            element.content = .node(node)
            undoStack.append(try board.apply(.replaceElement(element)))

            // Randomly unwind a few steps.
            if step % 7 == 0 {
                for _ in 0..<Int.random(in: 1...min(3, undoStack.count), using: &generator) {
                    if let inverse = undoStack.popLast() {
                        try board.apply(inverse)
                    }
                }
            }

            // Invariant: the edge always resolves, endpoints always sit on
            // the current node borders.
            let resolved = try XCTUnwrap(route(edge))
            let frameA = board.elements[a.id]!.node!.frame
            let frameB = board.elements[b.id]!.node!.frame
            XCTAssertTrue(onBorder(resolved.start, of: frameA), "step \(step): start detached")
            XCTAssertTrue(onBorder(resolved.end, of: frameB), "step \(step): end detached")
        }
    }

    private func onBorder(_ point: Point, of frame: Rect, tolerance: Double = 1e-6) -> Bool {
        let onVertical = (abs(point.x - frame.x) < tolerance || abs(point.x - frame.maxX) < tolerance)
            && point.y >= frame.y - tolerance && point.y <= frame.maxY + tolerance
        let onHorizontal = (abs(point.y - frame.y) < tolerance || abs(point.y - frame.maxY) < tolerance)
            && point.x >= frame.x - tolerance && point.x <= frame.maxX + tolerance
        return onVertical || onHorizontal
    }
}
