import XCTest
import DesignerModel
@testable import DesignerInterop

final class LLMInterchangeTests: XCTestCase {
    private func sampleBoard() -> (Board, gateway: ElementID, database: ElementID, edge: ElementID) {
        var board = Board(title: "Orders")
        let layer = board.layers[0].id
        let gateway = Element(
            layerIDs: [layer], sortKey: "a",
            content: .node(Node(semantic: NodeSemantic(kind: .gateway, name: "api-gateway"),
                                frame: Rect(x: 100, y: 100, width: 160, height: 80)))
        )
        let database = Element(
            layerIDs: [layer], sortKey: "b",
            content: .node(Node(semantic: NodeSemantic(kind: .database, name: "orders-db"),
                                frame: Rect(x: 400, y: 100, width: 140, height: 80),
                                shape: .ellipse))
        )
        let edge = Element(
            layerIDs: [layer], sortKey: "c",
            content: .edge(Edge(
                semantic: EdgeSemantic(
                    label: "order created", direction: .forward,
                    properties: [
                        WellKnownEdgeProperty.protocolKey: "gRPC",
                        WellKnownEdgeProperty.data: "OrderEvent",
                        "ownership": "orders-team",
                    ]
                ),
                from: .element(gateway.id, side: nil, offset: nil),
                to: .element(database.id, side: nil, offset: nil)
            ))
        )
        for element in [gateway, database, edge] { board.elements[element.id] = element }
        return (board, gateway.id, database.id, edge.id)
    }

    func testExportIsLegibleAndReferencesNodesByName() {
        let (board, _, _, _) = sampleBoard()
        let text = LLMInterchange.export(board)
        XCTAssertTrue(text.contains("designer-board"))
        XCTAssertTrue(text.contains("api-gateway"))
        XCTAssertTrue(text.contains("orders-db"))
        XCTAssertTrue(text.contains("\"protocol\" : \"gRPC\""))
        XCTAssertTrue(text.contains("# Designer board"), "primer header present")
    }

    func testRoundTripPreservesStructure() throws {
        let (board, _, _, _) = sampleBoard()
        let text = LLMInterchange.export(board)
        let result = try LLMInterchange.parse(text)
        XCTAssertTrue(result.warnings.isEmpty)

        let imported = result.board
        let nodes = imported.elements.values.filter { $0.node != nil }
        let edges = imported.elements.values.filter { $0.edge != nil }
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(edges.count, 1)

        let db = try XCTUnwrap(nodes.first { $0.node?.semantic.name == "orders-db" }?.node)
        XCTAssertEqual(db.shape, .ellipse, "shape survives interchange")

        let edge = try XCTUnwrap(edges.first?.edge)
        XCTAssertEqual(edge.semantic.label, "order created")
        XCTAssertEqual(edge.semantic.properties[WellKnownEdgeProperty.protocolKey], "gRPC")
        XCTAssertEqual(edge.semantic.properties["ownership"], "orders-team", "arbitrary props survive")
        // The edge connects the right nodes.
        let gatewayID = nodes.first { $0.node?.semantic.name == "api-gateway" }?.id
        XCTAssertEqual(edge.from.elementID, gatewayID)
    }

    func testImportToleratesSurroundingProseAndFences() throws {
        let (board, _, _, _) = sampleBoard()
        let json = LLMInterchange.export(board)
        let wrapped = """
        Sure! Here's the updated board with the change you asked for:

        ```json
        \(json.components(separatedBy: "\n\n").last ?? json)
        ```

        Let me know if you'd like anything else.
        """
        let result = try LLMInterchange.parse(wrapped)
        XCTAssertEqual(result.board.elements.values.filter { $0.node != nil }.count, 2)
    }

    func testLLMAddedNodeWithoutPositionIsAutoPlaced() throws {
        let json = """
        {
          "format": "designer-board",
          "nodes": [
            {"id": "a", "name": "a", "at": [0, 0], "size": [100, 60]},
            {"id": "cache", "name": "redis", "kind": "cache"}
          ],
          "edges": [{"from": "a", "to": "cache", "label": "reads", "protocol": "RESP"}]
        }
        """
        let result = try LLMInterchange.parse(json)
        let cache = try XCTUnwrap(
            result.board.elements.values.first { $0.node?.semantic.name == "redis" }?.node
        )
        XCTAssertEqual(cache.semantic.kind, .cache)
        XCTAssertGreaterThan(cache.frame.width, 0, "auto-placed node has a real frame")
        XCTAssertEqual(result.board.elements.values.filter { $0.edge != nil }.count, 1)
    }

    func testEdgeToUnknownNodeIsWarnedNotFatal() throws {
        let json = """
        {
          "format": "designer-board",
          "nodes": [{"id": "a", "name": "a", "at": [0,0], "size": [100,60]}],
          "edges": [{"from": "a", "to": "ghost"}]
        }
        """
        let result = try LLMInterchange.parse(json)
        XCTAssertEqual(result.board.elements.values.filter { $0.edge != nil }.count, 0)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("ghost"))
    }

    func testMalformedInputThrowsPreciseErrors() {
        XCTAssertThrowsError(try LLMInterchange.parse("just some text, no json")) {
            XCTAssertEqual($0 as? LLMInterchange.ImportError, .noJSONObject)
        }
        // Balanced braces but not valid JSON content.
        XCTAssertThrowsError(try LLMInterchange.parse("{ nodes: [], }")) {
            guard case .invalidJSON = $0 as? LLMInterchange.ImportError else {
                return XCTFail("expected invalidJSON, got \($0)")
            }
        }
    }

    func testDuplicateNodeSlugsAreDisambiguated() {
        var board = Board(title: "Dupes")
        let layer = board.layers[0].id
        for i in 0..<3 {
            let node = Element(
                layerIDs: [layer], sortKey: SortKey.bulk(i, of: 3),
                content: .node(Node(semantic: NodeSemantic(name: "worker"),
                                    frame: Rect(x: Double(i) * 200, y: 0, width: 100, height: 60)))
            )
            board.elements[node.id] = node
        }
        let text = LLMInterchange.export(board)
        // Three distinct ids: worker, worker-2, worker-3.
        XCTAssertTrue(text.contains("\"worker\""))
        XCTAssertTrue(text.contains("\"worker-2\""))
        XCTAssertTrue(text.contains("\"worker-3\""))
    }

    func testExportSelectionOnly() throws {
        let (board, gateway, _, _) = sampleBoard()
        let text = LLMInterchange.export(board, selection: [gateway])
        let result = try LLMInterchange.parse(text)
        XCTAssertEqual(result.board.elements.values.filter { $0.node != nil }.count, 1)
        XCTAssertEqual(result.board.elements.values.filter { $0.edge != nil }.count, 0)
    }
}
