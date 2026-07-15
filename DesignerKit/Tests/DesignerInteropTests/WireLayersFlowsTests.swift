import XCTest
import DesignerModel
@testable import DesignerInterop

/// The agent-facing wire format carries layers and flows (progressive
/// disclosure + recorded journeys) — round trip and resolution rules.
final class WireLayersFlowsTests: XCTestCase {
    private func layeredBoard() -> Board {
        var board = Board(title: "Layered")
        board.layers[0].name = "Overview"
        let base = board.layers[0].id
        let caching = Layer(name: "Caching", colorTint: "#38D9A9", isVisible: false)
        try! board.apply(.insertLayer(caching, at: 1))

        func node(_ name: String, _ x: Double, layers: Set<LayerID>) -> ElementID {
            let e = Element(layerIDs: layers, sortKey: board.topSortKey,
                            content: .node(Node(semantic: NodeSemantic(name: name),
                                                frame: Rect(x: x, y: 0, width: 120, height: 60))))
            try! board.apply(.insertElement(e))
            return e.id
        }
        let api = node("api", 0, layers: [base])
        let db = node("db", 400, layers: [base])
        let cache = node("cache", 200, layers: [caching.id])
        func edge(_ from: ElementID, _ to: ElementID, label: String, layers: Set<LayerID>) -> ElementID {
            let e = Element(layerIDs: layers, sortKey: board.topSortKey,
                            content: .edge(Edge(semantic: EdgeSemantic(label: label),
                                                from: .element(from, side: nil, offset: nil),
                                                to: .element(to, side: nil, offset: nil))))
            try! board.apply(.insertElement(e))
            return e.id
        }
        let query = edge(api, db, label: "query", layers: [base])
        _ = edge(api, cache, label: "fill", layers: [caching.id])
        try! board.apply(.insertFlow(
            Flow(name: "Read path", source: api,
                 steps: [Flow.Step(edges: [query], nodes: [db])]),
            at: 0))
        return board
    }

    func testLayersAndFlowsRoundTrip() throws {
        let exported = LLMInterchange.export(layeredBoard())
        XCTAssertTrue(exported.contains("\"layers\""))
        XCTAssertTrue(exported.contains("\"Caching\""))
        XCTAssertTrue(exported.contains("\"flows\""))

        let parsed = try LLMInterchange.parse(exported).board
        XCTAssertEqual(parsed.layers.map(\.name), ["Overview", "Caching"])
        XCTAssertEqual(parsed.layers[1].colorTint, "#38D9A9")
        XCTAssertFalse(parsed.layers[1].isVisible, "hidden survives the round trip")

        let cache = try XCTUnwrap(parsed.elements.values.first { $0.node?.semantic.name == "cache" })
        XCTAssertEqual(cache.layerIDs, [parsed.layers[1].id], "membership survives")
        let api = try XCTUnwrap(parsed.elements.values.first { $0.node?.semantic.name == "api" })
        XCTAssertEqual(api.layerIDs, [parsed.layers[0].id])

        XCTAssertEqual(parsed.flows.count, 1)
        let flow = parsed.flows[0]
        XCTAssertEqual(flow.name, "Read path")
        XCTAssertEqual(flow.source, api.id)
        XCTAssertEqual(flow.steps.count, 1)
        XCTAssertEqual(flow.steps[0].edges.count, 1)
        let flowEdge = try XCTUnwrap(parsed.elements[flow.steps[0].edges[0]]?.edge)
        XCTAssertEqual(flowEdge.semantic.label, "query")
    }

    func testViaPicksAmongParallelConnectors() throws {
        let text = """
        {"format": "designer-board", "title": "P",
         "nodes": [{"id": "a"}, {"id": "b"}],
         "edges": [{"from": "a", "to": "b", "label": "gRPC"},
                   {"from": "a", "to": "b", "label": "HTTP"}],
         "flows": [{"name": "fast", "source": "a",
                    "steps": [[{"from": "a", "to": "b", "via": "HTTP"}]]}]}
        """
        let result = try LLMInterchange.parse(text)
        let flow = try XCTUnwrap(result.board.flows.first)
        let edge = try XCTUnwrap(result.board.elements[flow.steps[0].edges[0]]?.edge)
        XCTAssertEqual(edge.semantic.label, "HTTP", "via selects the parallel connector")
    }

    func testUndeclaredLayerIsCreatedWithWarning() throws {
        let text = """
        {"format": "designer-board",
         "nodes": [{"id": "a", "layers": ["Security"]}], "edges": []}
        """
        let result = try LLMInterchange.parse(text)
        XCTAssertTrue(result.board.layers.contains { $0.name == "Security" })
        XCTAssertTrue(result.warnings.contains { $0.contains("Security") })
    }

    func testUnknownFlowSourceSkipsFlowWithWarning() throws {
        let text = """
        {"format": "designer-board",
         "nodes": [{"id": "a"}], "edges": [],
         "flows": [{"name": "ghost", "source": "nope", "steps": [[{"from": "a", "to": "a"}]]}]}
        """
        let result = try LLMInterchange.parse(text)
        XCTAssertTrue(result.board.flows.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("ghost") })
    }
}
