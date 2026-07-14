import XCTest
@testable import DesignerModel

final class FlowTests: XCTestCase {
    private var board = Board(title: "Flows")
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
    private func connect(_ from: String, _ to: String, _ dir: EdgeDirection = .forward, label: String? = nil) -> ElementID {
        let element = Element(
            layerIDs: [layer], sortKey: board.topSortKey,
            content: .edge(Edge(
                semantic: EdgeSemantic(label: label, direction: dir),
                from: .element(node(from), side: nil, offset: nil),
                to: .element(node(to), side: nil, offset: nil)
            ))
        )
        try! board.apply(.insertElement(element))
        return element.id
    }

    // MARK: Operations

    func testInsertRemoveReplaceFlowRoundTrip() {
        let flow = Flow(name: "checkout", source: node("a"), steps: [], colorIndex: 1)
        let inverse = try! board.apply(.insertFlow(flow, at: 0))
        XCTAssertEqual(board.flows.count, 1)

        var renamed = flow
        renamed.name = "checkout v2"
        let replaceInverse = try! board.apply(.replaceFlow(renamed))
        XCTAssertEqual(board.flows.first?.name, "checkout v2")
        try! board.apply(replaceInverse)
        XCTAssertEqual(board.flows.first?.name, "checkout")

        try! board.apply(inverse) // removeFlow
        XCTAssertTrue(board.flows.isEmpty)
    }

    func testDuplicateFlowInsertThrows() {
        let flow = Flow(name: "f", source: node("a"), steps: [])
        try! board.apply(.insertFlow(flow, at: 0))
        XCTAssertThrowsError(try board.apply(.insertFlow(flow, at: 0)))
    }

    // MARK: Codable

    func testFlowsPersistThroughEncodeDecode() throws {
        let edge = connect("a", "b")
        let flow = Flow(name: "path", source: node("a"),
                        steps: [Flow.Step(edges: [edge], nodes: [node("b")])], colorIndex: 2)
        try board.apply(.insertFlow(flow, at: 0))

        let data = try JSONEncoder().encode(board)
        let decoded = try JSONDecoder().decode(Board.self, from: data)
        XCTAssertEqual(decoded.flows, board.flows)
    }

    func testOldBoardWithoutFlowsDecodes() throws {
        var old = board
        old.flows = []
        var data = try JSONEncoder().encode(old)
        // Strip the flows key entirely, simulating a pre-F5 board file.
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "flows")
        data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(Board.self, from: data)
        XCTAssertTrue(decoded.flows.isEmpty)
    }

    // MARK: Staleness

    func testLiveStepsSkipDeletedEdges() {
        let e1 = connect("a", "b")
        let e2 = connect("b", "c")
        let flow = Flow(name: "f", source: node("a"), steps: [
            Flow.Step(edges: [e1], nodes: [node("b")]),
            Flow.Step(edges: [e2], nodes: [node("c")]),
        ])
        XCTAssertFalse(flow.isStale(in: board))
        try! board.apply(.removeElement(e2))
        XCTAssertTrue(flow.isStale(in: board))
        let live = flow.liveSteps(in: board)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.edges, [e1])
    }

    // MARK: Recorder

    func testRecorderWalksAChain() {
        let e1 = connect("a", "b"), e2 = connect("b", "c")
        var recorder = FlowRecorder(source: node("a"))

        var candidates = recorder.candidates(in: board)
        XCTAssertEqual(candidates.map(\.edge), [e1])
        XCTAssertTrue(recorder.record(candidates[0], in: board))

        candidates = recorder.candidates(in: board)
        XCTAssertEqual(candidates.map(\.edge), [e2])
        XCTAssertTrue(recorder.record(candidates[0], in: board))

        let steps = recorder.steps
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].edges, [e1])
        XCTAssertEqual(steps[1].edges, [e2])
    }

    func testParallelEdgesAreDistinctCandidates() {
        // Yarden's example: gRPC and HTTP both connect a→b; the flow picks one.
        let grpc = connect("a", "b", label: "gRPC")
        let http = connect("a", "b", label: "HTTP")
        _ = connect("b", "c", label: "gRPC")
        _ = connect("b", "c", label: "HTTP")

        var recorder = FlowRecorder(source: node("a"))
        let first = recorder.candidates(in: board)
        XCTAssertEqual(Set(first.map(\.edge)), [grpc, http], "both parallel edges offered")

        // Choose the gRPC edge; next hop offers b's two outgoing edges.
        recorder.record(first.first { $0.edge == grpc }!, in: board)
        let second = recorder.candidates(in: board)
        XCTAssertEqual(second.count, 3, "b→c pair plus the unused a→b HTTP edge")
        XCTAssertTrue(second.contains { $0.from == node("b") })
        XCTAssertFalse(second.contains { $0.edge == grpc }, "an edge fires once per flow")
    }

    func testCandidateTargetsAreTheClickableNextBlocks() {
        // Node-first recording: the gesture is "click the next block".
        let grpc = connect("a", "b", label: "gRPC")
        let http = connect("a", "b", label: "HTTP")
        _ = connect("a", "c")

        let recorder = FlowRecorder(source: node("a"))
        XCTAssertEqual(recorder.candidateTargets(in: board), [node("b"), node("c")],
                       "targets deduplicate parallel connectors")

        let toB = recorder.candidates(to: node("b"), in: board)
        XCTAssertEqual(Set(toB.map(\.edge)), [grpc, http],
                       "clicking b offers the parallel-connector choice")
        XCTAssertEqual(recorder.candidates(to: node("c"), in: board).count, 1,
                       "a single connector records directly")
    }

    func testFanOutMergesIntoOneStep() {
        let ea = connect("gw", "a"), eb = connect("gw", "b")
        var recorder = FlowRecorder(source: node("gw"))
        let candidates = recorder.candidates(in: board)
        recorder.record(candidates.first { $0.edge == ea }!, in: board)
        recorder.record(candidates.first { $0.edge == eb }!, in: board)
        XCTAssertEqual(recorder.steps.count, 1, "same-departure recordings fire together")
        XCTAssertEqual(Set(recorder.steps[0].edges), [ea, eb])
    }

    func testBranchRemainsRecordableAfterOtherBranchAdvances() {
        // gw fans out to a and b; after recording a→x, b→y must still be offered.
        connect("gw", "a"); connect("gw", "b")
        let ax = connect("a", "x"), by = connect("b", "y")
        var recorder = FlowRecorder(source: node("gw"))
        for candidate in recorder.candidates(in: board) where candidate.to != node("x") && candidate.to != node("y") {
            recorder.record(candidate, in: board)
        }
        recorder.record(recorder.candidates(in: board).first { $0.edge == ax }!, in: board)
        XCTAssertTrue(recorder.candidates(in: board).contains { $0.edge == by },
                      "the other branch stays recordable")
    }

    func testDirectionRespected() {
        connect("a", "b", .backward) // flow runs b → a
        var recorder = FlowRecorder(source: node("a"))
        XCTAssertTrue(recorder.candidates(in: board).isEmpty)
        var fromB = FlowRecorder(source: node("b"))
        XCTAssertEqual(fromB.candidates(in: board).count, 1)
        XCTAssertTrue(fromB.record(fromB.candidates(in: board)[0], in: board))
    }

    func testUndoLastRemovesOneConnector() {
        let e1 = connect("a", "b"), e2 = connect("b", "c")
        var recorder = FlowRecorder(source: node("a"))
        recorder.record(recorder.candidates(in: board)[0], in: board)
        recorder.record(recorder.candidates(in: board)[0], in: board)
        XCTAssertEqual(recorder.steps.count, 2)
        recorder.undoLast()
        XCTAssertEqual(recorder.steps.count, 1)
        XCTAssertEqual(recorder.steps[0].edges, [e1])
        XCTAssertTrue(recorder.candidates(in: board).contains { $0.edge == e2 })
    }
}
