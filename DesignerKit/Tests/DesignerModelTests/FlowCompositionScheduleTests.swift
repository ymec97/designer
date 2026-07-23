import XCTest
@testable import DesignerModel

/// The composition compiler: serial = back-to-back, parallel = overlaid, with
/// nesting, unequal lengths, and stale/dangling children. Uses clean duration
/// constants (edge=1, dwell=0) so a 2-step flow lasts exactly D=2.
final class FlowCompositionScheduleTests: XCTestCase {
    private let edge = 1.0
    private let dwell = 0.0
    private var D: Double { dwell + 2 * (edge + dwell) } // a 2-step out-and-back flow

    private var board = Board(title: "star")
    private var ids: [String: ElementID] = [:]

    private func node(_ name: String) -> ElementID {
        if let id = ids[name] { return id }
        let e = Element(layerIDs: [board.layers[0].id], sortKey: board.topSortKey,
                        content: .node(Node(semantic: NodeSemantic(name: name), frame: Rect(x: 0, y: 0, width: 80, height: 40))))
        try! board.apply(.insertElement(e))
        ids[name] = e.id
        return e.id
    }

    @discardableResult
    private func edgeBetween(_ a: String, _ b: String) -> ElementID {
        let e = Element(layerIDs: [board.layers[0].id], sortKey: board.topSortKey,
                        content: .edge(Edge(semantic: EdgeSemantic(direction: .both),
                                            from: .element(node(a), side: nil, offset: nil),
                                            to: .element(node(b), side: nil, offset: nil))))
        try! board.apply(.insertElement(e))
        return e.id
    }

    /// An out-and-back flow a→x→a over one bidirectional connector: 2 steps.
    private func outAndBack(_ name: String, id: FlowID, hub: String, spoke: String, color: Int) -> FlowID {
        let e = edgeBetween(hub, spoke)
        let flow = Flow(id: id, name: name, source: node(hub), steps: [
            Flow.Step(edges: [e], nodes: [node(spoke)]),
            Flow.Step(edges: [e], nodes: [node(hub)]),
        ], colorIndex: color)
        try! board.apply(.insertFlow(flow, at: board.flows.count))
        return id
    }

    /// Builds the star with three out-and-back flows f1/f2/f3 (a→b, a→c, a→d).
    private func buildStar() {
        outAndBack("ab", id: "f1", hub: "a", spoke: "b", color: 0)
        outAndBack("ac", id: "f2", hub: "a", spoke: "c", color: 1)
        outAndBack("ad", id: "f3", hub: "a", spoke: "d", color: 2)
    }

    private func compile(_ c: FlowComposition) -> FlowCompositionSchedule {
        FlowCompositionSchedule.compile(c, in: board, edgeDuration: edge, nodeDwell: dwell)
    }

    func testSerialStarSchedule() {
        buildStar()
        let c = FlowComposition(name: "serial", mode: .serial,
                                children: [.flow("f1"), .flow("f2"), .flow("f3")])
        let s = compile(c)
        XCTAssertEqual(s.tracks.map(\.flowID), ["f1", "f2", "f3"])
        XCTAssertEqual(s.tracks.map(\.start), [0, D, 2 * D])
        XCTAssertEqual(s.totalDuration, 3 * D)
        XCTAssertEqual(s.tracks.map(\.colorIndex), [0, 1, 2])
        XCTAssertTrue(s.skippedFlowIDs.isEmpty)
    }

    func testParallelStarSchedule() {
        buildStar()
        let c = FlowComposition(name: "parallel", mode: .parallel,
                                children: [.flow("f1"), .flow("f2"), .flow("f3")])
        let s = compile(c)
        XCTAssertEqual(s.tracks.map(\.start), [0, 0, 0])
        XCTAssertEqual(s.totalDuration, D)
        XCTAssertEqual(Set(s.tracks.map(\.colorIndex)), [0, 1, 2])
    }

    func testNestedSerialContainingParallel() {
        buildStar()
        // serial[ parallel[f1, f2], f3 ] → f1,f2 at 0; f3 at max(d1,d2) = D.
        let c = FlowComposition(name: "nested", mode: .serial, children: [
            .group(mode: .parallel, children: [.flow("f1"), .flow("f2")]),
            .flow("f3"),
        ])
        let s = compile(c)
        let starts = Dictionary(uniqueKeysWithValues: s.tracks.map { ($0.flowID, $0.start) })
        XCTAssertEqual(starts["f1"]!, 0)
        XCTAssertEqual(starts["f2"]!, 0)
        XCTAssertEqual(starts["f3"]!, D)
        XCTAssertEqual(s.totalDuration, 2 * D)
    }

    func testParallelUnequalLengthsEndsAtMax() {
        buildStar()
        // Give f1 a third step so it lasts longer than f2.
        var longer = board.flows.first { $0.id == "f1" }!
        let extraEdge = edgeBetween("b", "c")
        longer.steps.append(Flow.Step(edges: [extraEdge], nodes: [node("c")]))
        try! board.apply(.replaceFlow(longer))

        let longD = dwell + 3 * (edge + dwell)
        let c = FlowComposition(name: "p", mode: .parallel, children: [.flow("f1"), .flow("f2")])
        let s = compile(c)
        XCTAssertEqual(s.totalDuration, longD)
    }

    func testStaleChildShortensAndDanglingSkips() {
        buildStar()
        // Delete f2's spoke node 'c' entirely → f2 loses live steps.
        // First delete the a—c edge then the c node (edge must go first).
        let ac = board.elements.values.first { el in
            guard let e = el.edge else { return false }
            let ends = Set([e.from.elementID, e.to.elementID].compactMap { $0 })
            return ends == Set([node("a"), node("c")])
        }!.id
        try! board.apply(.removeElement(ac))

        // f2 now has no live edges → skipped; serial successors shift earlier.
        let c = FlowComposition(name: "s", mode: .serial,
                                children: [.flow("f1"), .flow("f2"), .flow("f3")])
        let s = compile(c)
        XCTAssertEqual(s.skippedFlowIDs, ["f2"])
        let starts = Dictionary(uniqueKeysWithValues: s.tracks.map { ($0.flowID, $0.start) })
        XCTAssertEqual(starts["f1"]!, 0)
        XCTAssertEqual(starts["f3"]!, D, "f2 contributed 0 duration, so f3 follows f1 directly")
        XCTAssertEqual(s.totalDuration, 2 * D)

        // A composition referencing a flow that doesn't exist skips it too.
        let dangling = compile(FlowComposition(name: "d", children: [.flow("nope")]))
        XCTAssertEqual(dangling.skippedFlowIDs, ["nope"])
        XCTAssertTrue(dangling.tracks.isEmpty)
    }
}
