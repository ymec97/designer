import XCTest
import DesignerModel
@testable import DesignerInterop

final class SVGExporterTests: XCTestCase {
    private func board() -> Board {
        var board = Board(title: "SVG")
        let layer = board.layers[0].id
        let a = Element(
            layerIDs: [layer], sortKey: "a",
            content: .node(Node(semantic: NodeSemantic(kind: .gateway, name: "api-gateway"),
                                frame: Rect(x: 100, y: 100, width: 160, height: 80)))
        )
        let b = Element(
            layerIDs: [layer], sortKey: "b",
            content: .node(Node(semantic: NodeSemantic(kind: .database, name: "orders-db"),
                                frame: Rect(x: 400, y: 100, width: 140, height: 80), shape: .ellipse))
        )
        let c = Element(
            layerIDs: [layer], sortKey: "c",
            content: .node(Node(semantic: NodeSemantic(name: "decide"),
                                frame: Rect(x: 400, y: 300, width: 120, height: 90),
                                shape: .triangle, orientation: .down))
        )
        let edge = Element(
            layerIDs: [layer], sortKey: "d",
            content: .edge(Edge(
                semantic: EdgeSemantic(label: "order created", direction: .both,
                                       properties: [WellKnownEdgeProperty.protocolKey: "gRPC"]),
                from: .element(a.id, side: nil, offset: nil),
                to: .element(b.id, side: nil, offset: nil)
            ))
        )
        for element in [a, b, c, edge] { board.elements[element.id] = element }
        return board
    }

    func testSVGIsWellFormedAndContainsElements() throws {
        let svg = SVGExporter.export(board())
        // Parses as XML (well-formed).
        let parser = XMLParser(data: Data(svg.utf8))
        XCTAssertTrue(parser.parse(), "SVG must be well-formed XML; error: \(String(describing: parser.parserError))")

        XCTAssertTrue(svg.hasPrefix("<?xml"))
        XCTAssertTrue(svg.contains("<svg"))
        XCTAssertTrue(svg.contains("<ellipse"), "database node → ellipse")
        XCTAssertTrue(svg.contains("<polygon"), "triangle node → polygon")
        XCTAssertTrue(svg.contains("<polyline"), "edge → polyline")
        XCTAssertTrue(svg.contains("api-gateway"))
        XCTAssertTrue(svg.contains("data-protocol=\"gRPC\""), "semantic data attribute present")
        XCTAssertTrue(svg.contains("marker-start") && svg.contains("marker-end"), "bidirectional arrows")
    }

    func testSVGEscapesText() throws {
        var b = Board(title: "x")
        let layer = b.layers[0].id
        let node = Element(
            layerIDs: [layer], sortKey: "a",
            content: .node(Node(semantic: NodeSemantic(name: "A & B <tag>"),
                                frame: Rect(x: 0, y: 0, width: 100, height: 60)))
        )
        b.elements[node.id] = node
        let svg = SVGExporter.export(b)
        XCTAssertTrue(svg.contains("A &amp; B &lt;tag&gt;"))
        XCTAssertFalse(svg.contains("A & B <tag>"))
        XCTAssertTrue(XMLParser(data: Data(svg.utf8)).parse())
    }

    func testDeterministicOutput() {
        let b = board()
        XCTAssertEqual(SVGExporter.export(b), SVGExporter.export(b), "SVG export must be stable")
    }

    func testEmptyBoardProducesValidSVG() {
        let svg = SVGExporter.export(Board(title: "empty"))
        XCTAssertTrue(XMLParser(data: Data(svg.utf8)).parse())
        XCTAssertTrue(svg.contains("<svg"))
    }
}
