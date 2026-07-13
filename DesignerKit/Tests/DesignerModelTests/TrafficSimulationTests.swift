import XCTest
@testable import DesignerModel

final class TrafficSimulationTests: XCTestCase {
    private var board = Board(title: "Flow")
    private var layer: LayerID { board.layers[0].id }
    private var nodeByName: [String: ElementID] = [:]

    private func node(_ name: String) -> ElementID {
        if let id = nodeByName[name] { return id }
        let element = Element(
            layerIDs: [layer], sortKey: board.topSortKey,
            content: .node(Node(semantic: NodeSemantic(name: name), frame: Rect(x: 0, y: 0, width: 80, height: 40)))
        )
        try! board.apply(.insertElement(element))
        nodeByName[name] = element.id
        return element.id
    }

    @discardableResult
    private func connect(_ from: String, _ to: String, _ dir: EdgeDirection = .forward) -> ElementID {
        let element = Element(
            layerIDs: [layer], sortKey: board.topSortKey,
            content: .edge(Edge(
                semantic: EdgeSemantic(direction: dir),
                from: .element(node(from), side: nil, offset: nil),
                to: .element(node(to), side: nil, offset: nil)
            ))
        )
        try! board.apply(.insertElement(element))
        return element.id
    }

    private func names(_ ids: [ElementID]) -> Set<String> {
        Set(ids.compactMap { id in nodeByName.first { $0.value == id }?.key })
    }

    func testLinearChain() {
        connect("a", "b"); connect("b", "c"); connect("c", "d")
        let steps = TrafficSimulation.steps(from: node("a"), in: board)
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(names(steps[0].nodes), ["b"])
        XCTAssertEqual(names(steps[1].nodes), ["c"])
        XCTAssertEqual(names(steps[2].nodes), ["d"])
    }

    func testFanOut() {
        connect("gw", "a"); connect("gw", "b"); connect("gw", "c")
        let steps = TrafficSimulation.steps(from: node("gw"), in: board)
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(names(steps[0].nodes), ["a", "b", "c"])
        XCTAssertEqual(steps[0].edges.count, 3)
    }

    func testDirectionRespected() {
        // a → b, but from b nothing flows back (forward only).
        connect("a", "b")
        XCTAssertTrue(TrafficSimulation.steps(from: node("b"), in: board).isEmpty)
        XCTAssertEqual(TrafficSimulation.steps(from: node("a"), in: board).count, 1)
    }

    func testBackwardEdge() {
        connect("a", "b", .backward) // arrow points at a; flow b → a
        XCTAssertEqual(names(TrafficSimulation.steps(from: node("b"), in: board).first?.nodes ?? []), ["a"])
        XCTAssertTrue(TrafficSimulation.steps(from: node("a"), in: board).isEmpty)
    }

    func testBidirectionalEdgeFlowsBothWays() {
        connect("a", "b", .both)
        XCTAssertEqual(names(TrafficSimulation.steps(from: node("a"), in: board).first?.nodes ?? []), ["b"])
        XCTAssertEqual(names(TrafficSimulation.steps(from: node("b"), in: board).first?.nodes ?? []), ["a"])
    }

    func testCycleTerminatesButShowsClosingEdge() {
        connect("a", "b"); connect("b", "c"); let closing = connect("c", "a")
        let steps = TrafficSimulation.steps(from: node("a"), in: board)
        // a→b, b→c, then c→a lights the closing edge but adds no new node.
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(names(steps[0].nodes), ["b"])
        XCTAssertEqual(names(steps[1].nodes), ["c"])
        XCTAssertTrue(steps[2].nodes.isEmpty, "closing step re-lights no node")
        XCTAssertEqual(steps[2].edges, [closing], "the loop-closing edge still animates")
    }

    func testEdgeAnimatesOnlyOnce() {
        // Diamond a→b, a→c, b→d, c→d: d reached once; both incoming edges show.
        connect("a", "b"); connect("a", "c"); connect("b", "d"); connect("c", "d")
        let steps = TrafficSimulation.steps(from: node("a"), in: board)
        let allEdges = steps.flatMap(\.edges)
        XCTAssertEqual(allEdges.count, Set(allEdges).count, "no edge animates twice")
        XCTAssertEqual(allEdges.count, 4, "all four edges animate")
    }

    func testNoneDirectionCarriesNoFlow() {
        connect("a", "b", .none)
        XCTAssertTrue(TrafficSimulation.steps(from: node("a"), in: board).isEmpty)
    }

    func testIsolatedNode() {
        node("lonely")
        XCTAssertTrue(TrafficSimulation.steps(from: node("lonely"), in: board).isEmpty)
    }

    func testReachedSummary() {
        connect("a", "b"); connect("b", "c"); connect("x", "y") // separate component
        let reached = TrafficSimulation.reached(from: node("a"), in: board)
        XCTAssertEqual(names(Array(reached.nodes)), ["a", "b", "c"])
        XCTAssertEqual(reached.edges.count, 2)
    }

    func testDanglingEdgeIgnored() {
        let a = node("a")
        let dangling = Element(
            layerIDs: [layer], sortKey: board.topSortKey,
            content: .edge(Edge(from: .element(a, side: nil, offset: nil), to: .free(Point(x: 200, y: 200))))
        )
        try! board.apply(.insertElement(dangling))
        XCTAssertTrue(TrafficSimulation.steps(from: a, in: board).isEmpty)
    }
}
