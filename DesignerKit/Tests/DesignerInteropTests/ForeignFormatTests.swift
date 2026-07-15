import XCTest
import Compression
import DesignerModel
@testable import DesignerInterop

/// draw.io + Excalidraw interchange: imports of handcrafted real-world-shaped
/// documents, and round trips of our own exports.
final class ForeignFormatTests: XCTestCase {
    private func sampleBoard() -> Board {
        var board = Board(title: "Sample")
        let layer = board.layers[0].id
        func node(_ name: String, shape: NodeShape, _ x: Double) -> ElementID {
            let e = Element(layerIDs: [layer], sortKey: board.topSortKey,
                            content: .node(Node(semantic: NodeSemantic(name: name),
                                                frame: Rect(x: x, y: 100, width: 140, height: 70),
                                                shape: shape)))
            try! board.apply(.insertElement(e))
            return e.id
        }
        let api = node("api-gateway", shape: .rectangle, 0)
        let db = node("orders-db", shape: .ellipse, 400)
        _ = node("fraud?", shape: .diamond, 800)
        try! board.apply(.insertElement(Element(
            layerIDs: [layer], sortKey: board.topSortKey,
            content: .edge(Edge(semantic: EdgeSemantic(label: "persist",
                                                       properties: ["protocol": "SQL"]),
                                from: .element(api, side: nil, offset: nil),
                                to: .element(db, side: nil, offset: nil))))))
        try! board.apply(.insertElement(Element(
            layerIDs: [layer], sortKey: board.topSortKey,
            content: .note(Note(text: "TODO: shard", frame: Rect(x: 0, y: 300, width: 120, height: 40))))))
        try! board.apply(.insertElement(Element(
            layerIDs: [layer], sortKey: board.topSortKey,
            content: .ink(Ink(points: [StrokePoint(x: 0, y: 400), StrokePoint(x: 50, y: 420),
                                       StrokePoint(x: 100, y: 400)])))))
        return board
    }

    // MARK: Excalidraw

    func testExcalidrawRoundTrip() throws {
        let data = try ExcalidrawFormat.data(from: sampleBoard())
        let result = try ExcalidrawFormat.board(from: data, title: "Back")
        let board = result.board

        let nodes = board.elements.values.compactMap(\.node)
        XCTAssertEqual(Set(nodes.map(\.semantic.name)), ["api-gateway", "orders-db", "fraud?"])
        XCTAssertEqual(nodes.first { $0.semantic.name == "orders-db" }?.shape, .ellipse)
        XCTAssertEqual(nodes.first { $0.semantic.name == "fraud?" }?.shape, .diamond)

        let edges = board.elements.values.compactMap(\.edge)
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges[0].semantic.label, "persist · SQL")
        XCTAssertNotNil(edges[0].from.elementID, "arrow binding survives")
        XCTAssertNotNil(edges[0].to.elementID)

        XCTAssertTrue(board.elements.values.contains { element in
            if case .note(let note) = element.content { return note.text == "TODO: shard" }
            return false
        })
        XCTAssertTrue(board.elements.values.contains { element in
            if case .ink = element.content { return true }
            return false
        }, "freedraw round-trips as ink")
    }

    func testExcalidrawImportOfForeignDocument() throws {
        // Shaped like a real Excalidraw save (fields we don't read included).
        let json = """
        {"type": "excalidraw", "version": 2, "source": "https://excalidraw.com",
         "elements": [
           {"id": "r1", "type": "rectangle", "x": 10, "y": 20, "width": 120, "height": 60,
            "angle": 0, "isDeleted": false, "boundElements": [{"type": "text", "id": "t1"}]},
           {"id": "t1", "type": "text", "x": 30, "y": 40, "width": 80, "height": 20,
            "text": "web", "containerId": "r1", "isDeleted": false},
           {"id": "e1", "type": "ellipse", "x": 300, "y": 20, "width": 100, "height": 60,
            "isDeleted": false},
           {"id": "a1", "type": "arrow", "x": 130, "y": 50, "width": 170, "height": 0,
            "points": [[0, 0], [170, 0]], "isDeleted": false,
            "startBinding": {"elementId": "r1", "focus": 0, "gap": 4},
            "endBinding": {"elementId": "e1", "focus": 0, "gap": 4}},
           {"id": "gone", "type": "rectangle", "x": 0, "y": 0, "width": 50, "height": 50,
            "isDeleted": true},
           {"id": "d1", "type": "freedraw", "x": 0, "y": 200, "width": 60, "height": 20,
            "points": [[0, 0], [30, 10], [60, 0]], "isDeleted": false}
         ], "appState": {}}
        """
        let result = try ExcalidrawFormat.board(from: Data(json.utf8), title: "Foreign")
        let board = result.board
        XCTAssertEqual(board.elements.values.compactMap(\.node).count, 2, "deleted elements skipped")
        XCTAssertEqual(board.elements.values.first { $0.node?.shape == .rectangle }?.node?.semantic.name, "web")
        XCTAssertEqual(board.elements.values.compactMap(\.edge).count, 1)
        XCTAssertTrue(board.elements.values.contains { if case .ink = $0.content { return true }; return false })
    }

    // MARK: draw.io

    func testDrawioRoundTrip() throws {
        let xml = DrawioFormat.xml(from: sampleBoard())
        XCTAssertTrue(xml.contains("<mxfile"))
        let result = try DrawioFormat.board(from: Data(xml.utf8), title: "Back")
        let board = result.board

        let nodes = board.elements.values.compactMap(\.node)
        XCTAssertEqual(Set(nodes.map(\.semantic.name)), ["api-gateway", "orders-db", "fraud?"])
        XCTAssertEqual(nodes.first { $0.semantic.name == "orders-db" }?.shape, .ellipse)
        XCTAssertEqual(nodes.first { $0.semantic.name == "fraud?" }?.shape, .diamond)
        let edges = board.elements.values.compactMap(\.edge)
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges[0].semantic.label, "persist · SQL")
        XCTAssertTrue(board.elements.values.contains { element in
            if case .note(let note) = element.content { return note.text == "TODO: shard" }
            return false
        })
    }

    func testDrawioImportOfForeignDocument() throws {
        let xml = """
        <mxfile host="app.diagrams.net">
          <diagram id="x" name="Page-1">
            <mxGraphModel><root>
              <mxCell id="0"/><mxCell id="1" parent="0"/>
              <mxCell id="n1" value="&lt;b&gt;web&lt;/b&gt;" style="rounded=1;html=1;" vertex="1" parent="1">
                <mxGeometry x="0" y="0" width="120" height="60" as="geometry"/>
              </mxCell>
              <mxCell id="n2" value="db" style="ellipse;whiteSpace=wrap;" vertex="1" parent="1">
                <mxGeometry x="300" y="0" width="100" height="60" as="geometry"/>
              </mxCell>
              <mxCell id="e1" value="" style="edgeStyle=orthogonalEdgeStyle;" edge="1" parent="1" source="n1" target="n2">
                <mxGeometry relative="1" as="geometry"/>
              </mxCell>
              <mxCell id="lbl" value="query" style="edgeLabel;html=1;" vertex="1" connectable="0" parent="e1">
                <mxGeometry x="-0.1" relative="1" as="geometry"/>
              </mxCell>
              <mxCell id="note" value="remember this" style="text;html=1;" vertex="1" parent="1">
                <mxGeometry x="0" y="200" width="140" height="30" as="geometry"/>
              </mxCell>
            </root></mxGraphModel>
          </diagram>
        </mxfile>
        """
        let result = try DrawioFormat.board(from: Data(xml.utf8), title: "Foreign")
        let board = result.board
        let nodes = board.elements.values.compactMap(\.node)
        XCTAssertEqual(Set(nodes.map(\.semantic.name)), ["web", "db"], "HTML labels stripped")
        let edges = board.elements.values.compactMap(\.edge)
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges[0].semantic.label, "query", "edgeLabel child becomes the label")
        XCTAssertTrue(board.elements.values.contains { element in
            if case .note(let note) = element.content { return note.text == "remember this" }
            return false
        })
    }

    func testDrawioCompressedDiagramImport() throws {
        // A minimal one-node model, compressed exactly the way draw.io does:
        // percent-encode → raw deflate → base64.
        let inner = """
        <mxGraphModel><root><mxCell id="0"/><mxCell id="1" parent="0"/>\
        <mxCell id="n1" value="zipped" style="rounded=1;" vertex="1" parent="1">\
        <mxGeometry x="0" y="0" width="100" height="50" as="geometry"/></mxCell></root></mxGraphModel>
        """
        let payload = try XCTUnwrap(Self.drawioCompress(inner))
        let xml = "<mxfile><diagram id=\"c\" name=\"P\">\(payload)</diagram></mxfile>"
        let result = try DrawioFormat.board(from: Data(xml.utf8), title: "Zipped")
        XCTAssertEqual(result.board.elements.values.compactMap(\.node).first?.semantic.name, "zipped")
    }

    /// Inverse of `decodeCompressedDiagram`, used only to build the fixture.
    private static func drawioCompress(_ xml: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        guard let encoded = xml.addingPercentEncoding(withAllowedCharacters: allowed),
              let input = encoded.data(using: .utf8) else { return nil }
        var output = Data(count: input.count * 2 + 1024)
        let written = output.withUnsafeMutableBytes { outPtr -> Int in
            input.withUnsafeBytes { inPtr -> Int in
                compression_encode_buffer(
                    outPtr.bindMemory(to: UInt8.self).baseAddress!, input.count * 2 + 1024,
                    inPtr.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        output.removeSubrange(written...)
        return output.base64EncodedString()
    }
}
