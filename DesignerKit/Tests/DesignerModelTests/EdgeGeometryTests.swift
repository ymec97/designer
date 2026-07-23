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

    // MARK: Curved connectors + node avoidance (P5)

    func testWaypointBendsSmoothlyThroughThePoint() throws {
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 80, height: 40))
        let b = addNode("b", frame: Rect(x: 400, y: 0, width: 80, height: 40))
        var edgeElement = connect(a, b)
        var edge = edgeElement.edge!
        let bend = Point(x: 240, y: -120)
        edge.waypoints = [bend]
        edgeElement.content = .edge(edge)
        try! board.apply(.replaceElement(edgeElement))

        let route = try XCTUnwrap(self.route(edgeElement))
        XCTAssertGreaterThan(route.points.count, 3, "waypoint routes are sampled curves")
        XCTAssertLessThan(route.distance(to: bend), 1.5, "curve passes through the bend")
        // The connector leaves its node toward the bend (above), not toward b.
        XCTAssertEqual(route.start.y, 0, accuracy: 0.001, "exits a's top side")
    }

    /// Regression (the "Postgres" screenshot): connectors into a WIDE, SHORT
    /// node from sources below it must arrive on the bottom border facing the
    /// sources — a detour must not re-anchor them to the TOP edge (arrowhead
    /// poking into the node from above, lines crossing).
    func testWideNodeArrivalStaysOnTheFacingSide() throws {
        // Wide short target up top; two narrow sources below-left; an
        // obstacle between each source and the target forces a detour.
        let postgres = addNode("Postgres", frame: Rect(x: 0, y: 0, width: 1040, height: 48))
        let cloud = addNode("Cloud Collector", frame: Rect(x: 80, y: 400, width: 110, height: 60))
        let gateway = addNode("Gateway Collector", frame: Rect(x: 80, y: 560, width: 110, height: 90))
        _ = addNode("wall1", frame: Rect(x: 280, y: 180, width: 90, height: 90))
        _ = addNode("wall2", frame: Rect(x: 300, y: 300, width: 90, height: 90))
        let e1 = connect(cloud, postgres)
        let e2 = connect(gateway, postgres)

        let obstacles = SpatialIndex.nodeObstacleQuery(for: board)
        let frame = Rect(x: 0, y: 0, width: 1040, height: 48)
        for edge in [e1, e2] {
            let route = try XCTUnwrap(EdgeGeometry.route(
                for: edge.edge!, frames: board.frameProvider(), obstacles: obstacles))
            XCTAssertGreaterThan(route.points.count, 2, "a detour must actually fire (exercises re-anchor)")
            // Arrives on the BOTTOM edge (facing the sources), never the top.
            XCTAssertEqual(route.end.y, frame.maxY, accuracy: 1.0,
                           "arrival is on the bottom border, not the top (got \(route.end))")
            // And the last segment approaches from BELOW/outside — no poke.
            let prev = route.points[route.points.count - 2]
            XCTAssertGreaterThan(prev.y, route.end.y - 1,
                                 "final segment approaches the border from outside the node")
        }
    }

    func testStraightRouteDetoursAroundBlockingNode() throws {
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 80, height: 40))
        let b = addNode("b", frame: Rect(x: 500, y: 0, width: 80, height: 40))
        let blocker = Rect(x: 250, y: -20, width: 90, height: 80)
        _ = addNode("wall", frame: blocker)
        let edgeElement = connect(a, b)

        let obstacles = SpatialIndex.nodeObstacleQuery(for: board)
        let route = try XCTUnwrap(EdgeGeometry.route(
            for: edgeElement.edge!, frames: board.frameProvider(), obstacles: obstacles))
        XCTAssertGreaterThan(route.points.count, 2, "blocked line curves")
        for point in route.points {
            XCTAssertFalse(blocker.contains(point), "route stays out of the blocking node")
        }

        // Without the blocker in the query, the same edge is a straight line.
        let straight = try XCTUnwrap(EdgeGeometry.route(
            for: edgeElement.edge!, frames: board.frameProvider()))
        XCTAssertEqual(straight.points.count, 2)
    }

    func testAvoidanceGivesUpOnHugeBlockers() {
        let wall = Rect(x: 200, y: -400, width: 60, height: 800)
        let waypoints = EdgeGeometry.avoidanceWaypoints(
            from: Point(x: 0, y: 0), to: Point(x: 500, y: 0),
            obstacles: { _ in [wall] }
        )
        XCTAssertTrue(waypoints.isEmpty, "a wild swing is worse than a crossing")
    }

    func testLongRouteWeavesPastSeveralBlockers() throws {
        // A long connector over a ROW of nodes (the agent-layout case): one
        // waypoint per blocker cluster, and the sampled route clears both.
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 80, height: 40))
        let b = addNode("b", frame: Rect(x: 900, y: 0, width: 80, height: 40))
        let blocker1 = Rect(x: 250, y: -20, width: 90, height: 80)
        let blocker2 = Rect(x: 600, y: -20, width: 90, height: 80)
        _ = addNode("wall1", frame: blocker1)
        _ = addNode("wall2", frame: blocker2)
        let edgeElement = connect(a, b)

        let waypoints = EdgeGeometry.avoidanceWaypoints(
            from: Point(x: 80, y: 20), to: Point(x: 900, y: 20),
            obstacles: SpatialIndex.nodeObstacleQuery(for: board)
        )
        XCTAssertEqual(waypoints.count, 2, "separated blockers get separate waypoints")

        let route = try XCTUnwrap(EdgeGeometry.route(
            for: edgeElement.edge!, frames: board.frameProvider(),
            obstacles: SpatialIndex.nodeObstacleQuery(for: board)))
        for point in route.points {
            XCTAssertFalse(blocker1.contains(point), "route clears the first blocker")
            XCTAssertFalse(blocker2.contains(point), "route clears the second blocker")
        }
    }

    func testCaptionSlidesOffBlockingNode() {
        // A node sits exactly at the route midpoint: the caption fraction
        // moves to a clear spot; with no obstruction it stays at preferred.
        let route = EdgeGeometry.Route(points: [Point(x: 0, y: 0), Point(x: 600, y: 0)])
        let nodeAtMid = Rect(x: 250, y: -30, width: 100, height: 60)
        let pill = Size(width: 90, height: 30)

        var placer = EdgeGeometry.CaptionPlacer()
        let center = placer.place(preferred: 0.5, route: route, pillSize: pill,
                                  obstacles: { _ in [nodeAtMid] })
        let pillRect = Rect(x: center.x - pill.width / 2, y: center.y - pill.height / 2,
                            width: pill.width, height: pill.height)
        XCTAssertFalse(nodeAtMid.intersects(pillRect), "caption slides off the node")

        var clearPlacer = EdgeGeometry.CaptionPlacer()
        let clear = clearPlacer.place(preferred: 0.5, route: route, pillSize: pill,
                                      obstacles: { _ in [] })
        XCTAssertEqual(clear, route.midpoint, "unobstructed captions stay at the preferred spot")
    }

    func testCaptionsNeverStackOnEachOther() {
        // Two captions preferring the SAME spot (parallel short edges on a
        // dense board): the second must land clear of the first.
        let route = EdgeGeometry.Route(points: [Point(x: 0, y: 0), Point(x: 300, y: 0)])
        let pill = Size(width: 140, height: 34)
        var placer = EdgeGeometry.CaptionPlacer()
        let first = placer.place(preferred: 0.5, route: route, pillSize: pill, obstacles: { _ in [] })
        let second = placer.place(preferred: 0.5, route: route, pillSize: pill, obstacles: { _ in [] })
        let a = Rect(x: first.x - pill.width / 2, y: first.y - pill.height / 2,
                     width: pill.width, height: pill.height)
        let b = Rect(x: second.x - pill.width / 2, y: second.y - pill.height / 2,
                     width: pill.width, height: pill.height)
        XCTAssertFalse(a.intersects(b), "second caption dodges the first")
    }

    // MARK: Anchor spreading (arrows sharing a node side)

    func testAnchorSpreadSeparatesArrowsIntoTheSameSide() {
        // Two sources left of one target: both edges land on the target's
        // left side and must not share an anchor point.
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 80, height: 40))
        let b = addNode("b", frame: Rect(x: 0, y: 200, width: 80, height: 40))
        let target = addNode("t", frame: Rect(x: 300, y: 100, width: 80, height: 40))
        let ea = connect(a, target), eb = connect(b, target)

        let spread = EdgeGeometry.anchorSpread(in: board)
        let ta = try! XCTUnwrap(spread[ea.id]?.to)
        let tb = try! XCTUnwrap(spread[eb.id]?.to)
        XCTAssertNotEqual(ta, tb, "shared side distributes, never stacks")
        XCTAssertLessThan(ta, tb, "upper source keeps the upper slot (no crossing)")
        XCTAssertNil(spread[ea.id]?.from, "a's own side has one edge — no spread needed")

        // Removing one connector re-flows the survivor back to the midpoint.
        try! board.apply(.removeElement(eb.id))
        XCTAssertNil(EdgeGeometry.anchorSpread(in: board)[ea.id])
    }

    func testAnchorSpreadSkipsPinnedAnchors() {
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 80, height: 40))
        let b = addNode("b", frame: Rect(x: 0, y: 200, width: 80, height: 40))
        let target = addNode("t", frame: Rect(x: 300, y: 100, width: 80, height: 40))
        let pinned = connect(a, target, toSide: .left)
        let auto = connect(b, target)

        let spread = EdgeGeometry.anchorSpread(in: board)
        XCTAssertNil(spread[pinned.id]?.to, "user-pinned anchors are never moved")
        XCTAssertNil(spread[auto.id]?.to, "a single auto edge on the side stays at the midpoint")
    }

    func testParallelEdgesSpreadAlongBothSides() {
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 80, height: 40))
        let b = addNode("b", frame: Rect(x: 300, y: 0, width: 80, height: 40))
        let grpc = connect(a, b), http = connect(a, b)

        let spread = EdgeGeometry.anchorSpread(in: board)
        let g = try! XCTUnwrap(spread[grpc.id]), h = try! XCTUnwrap(spread[http.id])
        XCTAssertNotEqual(g.from, h.from)
        XCTAssertNotEqual(g.to, h.to)

        // And the resolved routes must start/end at distinct points.
        let frames = board.frameProvider()
        let rg = EdgeGeometry.route(for: board.elements[grpc.id]!.edge!, frames: frames, anchorOffsets: g)!
        let rh = EdgeGeometry.route(for: board.elements[http.id]!.edge!, frames: frames, anchorOffsets: h)!
        XCTAssertNotEqual(rg.start, rh.start)
        XCTAssertNotEqual(rg.points.last, rh.points.last)
    }

    func testParallelEdgesGetStaggeredCaptions() {
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 80, height: 40))
        let b = addNode("b", frame: Rect(x: 300, y: 0, width: 80, height: 40))
        let grpc = connect(a, b), http = connect(a, b)
        let single = connect(a, addNode("c", frame: Rect(x: 0, y: 200, width: 80, height: 40)))

        let spread = EdgeGeometry.anchorSpread(in: board)
        let g = spread[grpc.id]?.captionT, h = spread[http.id]?.captionT
        XCTAssertNotNil(g); XCTAssertNotNil(h)
        XCTAssertNotEqual(g, h, "parallel captions never share a spot")
        XCTAssertNil(spread[single.id]?.captionT, "lone edges keep the midpoint")
    }

    func testPointAtFractionWalksArcLength() {
        let route = EdgeGeometry.Route(points: [
            Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 10, y: 10), Point(x: 20, y: 10),
        ])
        // Total length 30; fraction 0.5 = 15 along = middle of second segment.
        XCTAssertEqual(route.midpoint, Point(x: 10, y: 5))
        XCTAssertEqual(route.point(atFraction: 0), Point(x: 0, y: 0))
        XCTAssertEqual(route.point(atFraction: 1), Point(x: 20, y: 10))
        XCTAssertEqual(route.point(atFraction: 2.0 / 3.0), Point(x: 10, y: 10))
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

    // MARK: Discrete anchor slots (endpoint re-targeting)

    func testAnchorSlotsCoverEveryFace() {
        let frame = Rect(x: 10, y: 20, width: 80, height: 40)
        let slots = EdgeGeometry.anchorSlots(for: frame)
        XCTAssertEqual(slots.count, 12, "4 faces × 3 offsets")
        for slot in slots {
            XCTAssertTrue(onBorder(slot.point, of: frame), "every slot sits on the border")
        }
    }

    func testNearestAnchorSlotSnapsToTheClosestFacePoint() {
        let frame = Rect(x: 0, y: 0, width: 100, height: 60)
        // Just outside the right face, low down → right / far (0.75) slot.
        let right = EdgeGeometry.nearestAnchorSlot(to: Point(x: 112, y: 46), on: frame)
        XCTAssertEqual(right.side, .right)
        XCTAssertEqual(right.offset, 0.75, accuracy: 1e-9)
        // Above the top-middle → top / center (0.5) slot.
        let top = EdgeGeometry.nearestAnchorSlot(to: Point(x: 50, y: -12), on: frame)
        XCTAssertEqual(top.side, .top)
        XCTAssertEqual(top.offset, 0.5, accuracy: 1e-9)
        // Left of the upper-left → left / near (0.25) slot.
        let left = EdgeGeometry.nearestAnchorSlot(to: Point(x: -6, y: 10), on: frame)
        XCTAssertEqual(left.side, .left)
        XCTAssertEqual(left.offset, 0.25, accuracy: 1e-9)
    }

    // MARK: Rubber-band route intersection

    /// A connector's bounding box spans both endpoints, so a selection band in
    /// the empty space it diagonally crosses overlaps the box but not the line.
    /// Rubber-band selection must test the line, not the box.
    func testRouteIntersectionIgnoresBoundingBoxGaps() throws {
        let a = addNode("a", frame: Rect(x: 0, y: 200, width: 20, height: 20))
        let b = addNode("b", frame: Rect(x: 400, y: 0, width: 20, height: 20))
        let edge = connect(a, b)
        let route = try XCTUnwrap(self.route(edge))

        // Top-left empty space: inside the route's bbox, far from the line.
        let farBand = Rect(x: 20, y: 20, width: 30, height: 30)
        XCTAssertTrue(route.boundingRect.intersects(farBand), "bbox overlaps — the bug's cause")
        XCTAssertFalse(EdgeGeometry.route(route, intersects: farBand), "line does not cross the band")

        // A band straddling the midpoint really crosses the line.
        let mid = route.midpoint
        let onBand = Rect(x: mid.x - 10, y: mid.y - 10, width: 20, height: 20)
        XCTAssertTrue(EdgeGeometry.route(route, intersects: onBand))
    }
}
