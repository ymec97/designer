import XCTest
@testable import DesignerInterop
import DesignerModel

/// The flow auto-layout used when an imported/proposed board omits positions.
final class WireLayoutTests: XCTestCase {
    private func board(_ json: String) -> Board {
        try! LLMInterchange.parse("# designer-board\n\n\(json)\n").board
    }

    private func frame(_ board: Board, _ name: String) -> Rect {
        board.elements.values.first { $0.node?.semantic.name == name }!.node!.frame
    }

    func testChainFlowsLeftToRight() {
        let b = board(#"{"nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"},{"id":"c","name":"c"}],"edges":[{"from":"a","to":"b"},{"from":"b","to":"c"}]}"#)
        XCTAssertLessThan(frame(b, "a").x, frame(b, "b").x)
        XCTAssertLessThan(frame(b, "b").x, frame(b, "c").x)
    }

    func testDeepChainCompressesMonotonically() {
        // A 24-hop pipeline squeezes into <=8 columns while KEEPING the
        // left-to-right story: no bands, no 8,000pt marches, x never
        // decreases along the chain.
        var nodes: [String] = []
        var edges: [String] = []
        for index in 0..<24 {
            nodes.append("{\"id\": \"n\(index)\", \"name\": \"n\(index)\"}")
            if index > 0 { edges.append("{\"from\": \"n\(index - 1)\", \"to\": \"n\(index)\"}") }
        }
        let b = board("{\"nodes\": [\(nodes.joined(separator: ","))], \"edges\": [\(edges.joined(separator: ","))]}")
        let frames = b.elements.values.compactMap(\.node?.frame)
        XCTAssertLessThanOrEqual(frames.map(\.maxX).max() ?? 0, 2600, "stays a few screens wide")
        XCTAssertLessThanOrEqual(frames.map(\.maxY).max() ?? 0, 1600, "no towers")
        for index in 1..<24 {
            XCTAssertGreaterThanOrEqual(
                frame(b, "n\(index)").x, frame(b, "n\(index - 1)").x,
                "the chain reads left to right (n\(index))")
        }
    }

    func testCyclicGraphStaysCompact() {
        // The bug that produced the 27,000pt board: cycles pushed longest-
        // path depths to node-count. Kahn-based depths must keep a cyclic
        // 30-node graph within a few screens.
        var nodes: [String] = []
        var edges: [String] = []
        for index in 0..<30 {
            nodes.append("{\"id\": \"n\(index)\", \"name\": \"n\(index)\"}")
            edges.append("{\"from\": \"n\(index)\", \"to\": \"n\((index + 1) % 30)\"}") // one big cycle
            if index % 3 == 0 { edges.append("{\"from\": \"n\((index + 5) % 30)\", \"to\": \"n\(index)\"}") }
        }
        let b = board("{\"nodes\": [\(nodes.joined(separator: ","))], \"edges\": [\(edges.joined(separator: ","))]}")
        let frames = b.elements.values.compactMap(\.node?.frame)
        XCTAssertLessThanOrEqual(frames.map(\.maxX).max() ?? 0, 3200)
        XCTAssertLessThanOrEqual(frames.map(\.maxY).max() ?? 0, 2400)
        // And nothing overlaps.
        for i in 0..<frames.count {
            for j in (i + 1)..<frames.count {
                XCTAssertFalse(frames[i].intersects(frames[j]), "blocks must not overlap")
            }
        }
    }

    func testDirectionTopDownSwapsAxes() {
        let json = #"{"layout": "top-down", "nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"}],"edges":[{"from":"a","to":"b"}]}"#
        let b = board(json)
        XCTAssertLessThan(frame(b, "a").y, frame(b, "b").y, "top-down flows downward")
        if case .string(let direction)? = b.extra["layoutDirection"] {
            XCTAssertEqual(direction, "top-down", "direction persists on the board")
        } else {
            XCTFail("layoutDirection not stored")
        }
    }

    func testDirectionRightLeftMirrors() {
        let json = #"{"layout": "right-left", "nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"}],"edges":[{"from":"a","to":"b"}]}"#
        let b = board(json)
        XCTAssertGreaterThan(frame(b, "a").x, frame(b, "b").x, "right-left flows leftward")
    }

    func testExternalsFormBottomRow() {
        let json = #"{"nodes":[{"id":"svc","name":"svc"},{"id":"db","name":"db"},{"id":"jira","name":"JIRA","kind":"external"},{"id":"slack","name":"Slack","kind":"external"}],"edges":[{"from":"svc","to":"db"},{"from":"svc","to":"jira"},{"from":"svc","to":"slack"}]}"#
        let b = board(json)
        let coreMaxY = max(frame(b, "svc").maxY, frame(b, "db").maxY)
        XCTAssertGreaterThan(frame(b, "JIRA").y, coreMaxY, "externals sit below the core")
        XCTAssertEqual(frame(b, "JIRA").y, frame(b, "Slack").y, "externals share the bottom row")
    }

    func testLayerMatesStayAdjacent() {
        // Nodes sharing a specialty layer must be contiguous in their column.
        let json = """
        {"layers": [{"name": "Base"}, {"name": "Analysis"}],
         "nodes": [{"id": "src", "name": "src"},
                   {"id": "a1", "name": "a1", "layers": ["Analysis"]},
                   {"id": "plain", "name": "plain"},
                   {"id": "a2", "name": "a2", "layers": ["Analysis"]}],
         "edges": [{"from": "src", "to": "a1"}, {"from": "src", "to": "plain"}, {"from": "src", "to": "a2"}]}
        """
        let b = board(json)
        let ys = ["a1", "plain", "a2"].map { (name: $0, y: frame(b, $0).y) }.sorted { $0.y < $1.y }
        let order = ys.map(\.name)
        XCTAssertTrue(order == ["a1", "a2", "plain"] || order == ["plain", "a1", "a2"],
                      "cluster mates a1/a2 stay adjacent, got \(order)")
    }

    func testFanOutSharesColumn() {
        let b = board(#"{"nodes":[{"id":"gw","name":"gw"},{"id":"a","name":"a"},{"id":"b","name":"b"}],"edges":[{"from":"gw","to":"a"},{"from":"gw","to":"b"}]}"#)
        XCTAssertLessThan(frame(b, "gw").x, frame(b, "a").x)
        XCTAssertEqual(frame(b, "a").x, frame(b, "b").x, "siblings share a column")
        XCTAssertNotEqual(frame(b, "a").y, frame(b, "b").y, "siblings stack vertically")
    }

    func testDiamondJoinLandsAfterBothBranches() {
        let b = board(#"{"nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"},{"id":"c","name":"c"},{"id":"d","name":"d"}],"edges":[{"from":"a","to":"b"},{"from":"a","to":"c"},{"from":"b","to":"d"},{"from":"c","to":"d"}]}"#)
        XCTAssertGreaterThan(frame(b, "d").x, frame(b, "b").x)
        XCTAssertGreaterThan(frame(b, "d").x, frame(b, "c").x)
    }

    func testCycleTerminatesWithPositions() {
        let b = board(#"{"nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"},{"id":"c","name":"c"}],"edges":[{"from":"a","to":"b"},{"from":"b","to":"c"},{"from":"c","to":"a"}]}"#)
        XCTAssertEqual(b.elements.values.filter { $0.node != nil }.count, 3)
        for name in ["a", "b", "c"] {
            XCTAssertGreaterThan(frame(b, name).width, 0)
        }
    }

    func testGivenPositionsAreKept() {
        let b = board(#"{"nodes":[{"id":"a","name":"a","at":[500,600],"size":[100,50]},{"id":"b","name":"b"}],"edges":[{"from":"a","to":"b"}]}"#)
        XCTAssertEqual(frame(b, "a").x, 500)
        XCTAssertEqual(frame(b, "a").y, 600)
        XCTAssertGreaterThan(frame(b, "b").x, 80 - 1, "auto node still placed")
    }

    func testMissingNameFallsBackToID() {
        let b = board(#"{"nodes":[{"id":"orders-cache","kind":"cache"}],"edges":[]}"#)
        let node = b.elements.values.first { $0.node != nil }!.node!
        XCTAssertEqual(node.semantic.name, "orders-cache",
                       "an agent that only sets id must still produce a labeled block")
        XCTAssertEqual(node.semantic.kind, .cache)
    }

    /// Proposals REUSE the current graph: matched blocks (by name) inherit
    /// their current frame when the wire omits positions, so an agent edit
    /// overlays the existing diagram instead of rebuilding it far away.
    func testAnchoredParseInheritsMatchedFrames() throws {
        var current = Board(title: "Current")
        let layer = current.layers[0].id
        func place(_ name: String, _ x: Double, _ y: Double) {
            try! current.apply(.insertElement(Element(
                layerIDs: [layer], sortKey: current.topSortKey,
                content: .node(Node(semantic: NodeSemantic(name: name),
                                    frame: Rect(x: x, y: y, width: 150, height: 70))))))
        }
        place("Web App", 2000, 3000)
        place("Orders DB", 2400, 3000)

        // Agent resends both blocks WITHOUT positions + one new block.
        let proposal = """
        # designer-board

        {"nodes":[{"id":"web-app","name":"Web App"},
                  {"id":"orders-db","name":"Orders DB"},
                  {"id":"cache","name":"Hot Cache","kind":"cache"}],
         "edges":[{"from":"web-app","to":"cache","label":"reads"}]}
        """
        let anchored = try LLMInterchange.parse(proposal, anchoredTo: current).board

        XCTAssertEqual(frame(anchored, "Web App"), Rect(x: 2000, y: 3000, width: 150, height: 70),
                       "matched block keeps its exact current frame")
        XCTAssertEqual(frame(anchored, "Orders DB").x, 2400)
        let cache = frame(anchored, "Hot Cache")
        XCTAssertGreaterThan(cache.x, 2000, "the NEW block lands beside the existing graph, not at the origin")
        XCTAssertGreaterThan(cache.y, 1000, "…vertically near the graph too")

        // An explicit `at` from the agent still wins over inheritance.
        let movedProposal = """
        # designer-board

        {"nodes":[{"id":"web-app","name":"Web App","at":[5000,5000],"size":[150,70]},
                  {"id":"orders-db","name":"Orders DB"}],"edges":[]}
        """
        let moved = try LLMInterchange.parse(movedProposal, anchoredTo: current).board
        XCTAssertEqual(frame(moved, "Web App").x, 5000, "explicit at is a deliberate move")
        XCTAssertEqual(frame(moved, "Orders DB").x, 2400, "unmoved match still inherits")

        // Un-anchored parse (plain import) is unchanged: auto-layout from scratch.
        let plain = try LLMInterchange.parse(proposal).board
        XCTAssertLessThan(frame(plain, "Web App").x, 1000, "plain parse still lays out fresh")
    }

    func testNoEdgesStacksCompactly() {
        // No edges = no flow: one tidy column (spilling sideways past 10).
        let b = board(#"{"nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"}],"edges":[]}"#)
        XCTAssertEqual(frame(b, "a").x, frame(b, "b").x, "same column without flow")
        XCTAssertNotEqual(frame(b, "a").y, frame(b, "b").y)
        var many: [String] = []
        for index in 0..<14 { many.append("{\"id\": \"m\(index)\", \"name\": \"m\(index)\"}") }
        let big = board("{\"nodes\": [\(many.joined(separator: ","))], \"edges\": []}")
        let xs = Set(big.elements.values.compactMap(\.node?.frame.x))
        XCTAssertGreaterThan(xs.count, 1, "14 flow-less nodes spill into a second column")
    }
}
