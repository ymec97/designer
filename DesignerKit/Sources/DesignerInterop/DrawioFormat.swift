import Foundation
import Compression
import DesignerModel

/// draw.io / diagrams.net interchange (`.drawio` mxGraph XML).
///
/// Import handles both plain XML and the compressed form draw.io often
/// saves (`<diagram>` content = base64(raw-deflate(percent-encoded XML))).
/// Only the first page of a multi-page file is imported.
///
/// Mapping (import ⇄ export):
///   vertex cells ⇄ blocks (style: ellipse/rhombus/triangle/rounded)
///   edge cells   ⇄ connectors (value or edgeLabel child = label)
///   text cells   ⇄ notes
/// Freehand ink has no draw.io equivalent and is skipped on export;
/// layers/flows are dropped.
public enum DrawioFormat {
    // MARK: - Import

    public struct ImportResult {
        public let board: Board
        public let warnings: [String]
    }

    public enum ImportError: Error, LocalizedError {
        case notDrawio
        case unreadableDiagram
        public var errorDescription: String? {
            switch self {
            case .notDrawio: return "This doesn't look like a draw.io file (no mxGraphModel found)."
            case .unreadableDiagram: return "The draw.io diagram payload couldn't be decoded."
            }
        }
    }

    public static func board(from data: Data, title: String) throws -> ImportResult {
        guard let document = try? XMLDocument(data: data) else { throw ImportError.notDrawio }

        // Find the mxGraphModel: directly, or inside a <diagram> (which may
        // hold compressed text instead of child XML).
        var model = try? document.nodes(forXPath: "//mxGraphModel").first
        if model == nil, let diagram = try? document.nodes(forXPath: "//diagram").first as? XMLElement {
            if let inner = diagram.children?.first(where: { $0.name == "mxGraphModel" }) {
                model = inner
            } else if let payload = diagram.stringValue, !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let xml = decodeCompressedDiagram(payload),
                      let innerDocument = try? XMLDocument(xmlString: xml),
                      let inner = try? innerDocument.nodes(forXPath: "//mxGraphModel").first else {
                    throw ImportError.unreadableDiagram
                }
                model = inner
            }
        }
        guard let model else { throw ImportError.notDrawio }

        var board = Board(title: title)
        let layer = board.layers[0].id
        var warnings: [String] = []
        var elementForCellID: [String: ElementID] = [:]
        var edgeElementForCellID: [String: ElementID] = [:]

        struct Cell {
            var id: String
            var value: String
            var style: String
            var isVertex: Bool
            var isEdge: Bool
            var source: String?
            var target: String?
            var parent: String?
            var frame: Rect?
        }

        func parseCell(_ element: XMLElement, valueOverride: String?) -> Cell? {
            guard let id = element.attribute(forName: "id")?.stringValue else { return nil }
            var frame: Rect?
            if let geometry = element.children?.compactMap({ $0 as? XMLElement })
                .first(where: { $0.name == "mxGeometry" }) {
                let x = Double(geometry.attribute(forName: "x")?.stringValue ?? "") ?? 0
                let y = Double(geometry.attribute(forName: "y")?.stringValue ?? "") ?? 0
                let w = Double(geometry.attribute(forName: "width")?.stringValue ?? "") ?? 0
                let h = Double(geometry.attribute(forName: "height")?.stringValue ?? "") ?? 0
                frame = Rect(x: x, y: y, width: w, height: h)
            }
            return Cell(
                id: id,
                value: stripHTML(valueOverride ?? element.attribute(forName: "value")?.stringValue ?? ""),
                style: element.attribute(forName: "style")?.stringValue ?? "",
                isVertex: element.attribute(forName: "vertex")?.stringValue == "1",
                isEdge: element.attribute(forName: "edge")?.stringValue == "1",
                source: element.attribute(forName: "source")?.stringValue,
                target: element.attribute(forName: "target")?.stringValue,
                parent: element.attribute(forName: "parent")?.stringValue,
                frame: frame
            )
        }

        var cells: [Cell] = []
        for node in (try? model.nodes(forXPath: ".//mxCell")) ?? [] {
            guard let element = node as? XMLElement else { continue }
            // <object label="…"><mxCell …/></object> wraps custom-data cells.
            let wrapper = element.parent as? XMLElement
            let label = (wrapper?.name == "object" || wrapper?.name == "UserObject")
                ? wrapper?.attribute(forName: "label")?.stringValue : nil
            // The object wrapper carries the id in that case.
            if let cell = parseCell(element, valueOverride: label) {
                if cell.id.isEmpty, let wrapperID = wrapper?.attribute(forName: "id")?.stringValue {
                    var fixed = cell
                    fixed.id = wrapperID
                    cells.append(fixed)
                } else {
                    cells.append(cell)
                }
            }
        }

        func shape(for style: String) -> NodeShape {
            if style.contains("ellipse") { return .ellipse }
            if style.contains("rhombus") { return .diamond }
            if style.contains("triangle") { return .triangle }
            return .rectangle
        }

        // Vertices: text-style cells become notes, the rest blocks.
        for cell in cells where cell.isVertex {
            guard let frame = cell.frame, frame.width > 0, frame.height > 0 else { continue }
            if cell.style.hasPrefix("text") || cell.style.contains(";text;") {
                guard !cell.value.isEmpty else { continue }
                let element = Element(layerIDs: [layer], sortKey: board.topSortKey,
                                      content: .note(Note(text: cell.value, frame: frame)))
                try? board.apply(.insertElement(element))
                continue
            }
            let element = Element(
                layerIDs: [layer], sortKey: board.topSortKey,
                content: .node(Node(
                    semantic: NodeSemantic(name: cell.value),
                    frame: frame,
                    shape: shape(for: cell.style)
                ))
            )
            elementForCellID[cell.id] = element.id
            try? board.apply(.insertElement(element))
        }

        // Edges.
        for cell in cells where cell.isEdge {
            guard let sourceID = cell.source.flatMap({ elementForCellID[$0] }),
                  let targetID = cell.target.flatMap({ elementForCellID[$0] }) else {
                if cell.source == nil || cell.target == nil {
                    warnings.append("edge '\(cell.id)' has an unattached end — skipped")
                }
                continue
            }
            let element = Element(
                layerIDs: [layer], sortKey: board.topSortKey,
                content: .edge(Edge(
                    semantic: EdgeSemantic(label: cell.value.isEmpty ? nil : cell.value),
                    from: .element(sourceID, side: nil, offset: nil),
                    to: .element(targetID, side: nil, offset: nil)
                ))
            )
            edgeElementForCellID[cell.id] = element.id
            try? board.apply(.insertElement(element))
        }

        // Edge labels living as child cells (style edgeLabel, parent = edge).
        for cell in cells where cell.style.contains("edgeLabel") && !cell.value.isEmpty {
            guard let parent = cell.parent,
                  let edgeElementID = edgeElementForCellID[parent],
                  var element = board.elements[edgeElementID],
                  var edge = element.edge, edge.semantic.label == nil else { continue }
            edge.semantic.label = cell.value
            element.content = .edge(edge)
            try? board.apply(.replaceElement(element))
        }

        if board.elements.isEmpty {
            warnings.append("no supported cells found in the first page")
        }
        return ImportResult(board: board, warnings: warnings)
    }

    /// draw.io compressed payload: base64 → raw DEFLATE → percent-decoding.
    static func decodeCompressedDiagram(_ payload: String) -> String? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let compressed = Data(base64Encoded: trimmed) else { return nil }
        let capacity = max(compressed.count * 32, 1 << 16)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { outPtr -> Int in
            compressed.withUnsafeBytes { inPtr -> Int in
                compression_decode_buffer(
                    outPtr.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    inPtr.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        output.removeSubrange(written...)
        guard let urlEncoded = String(data: output, encoding: .utf8) else { return nil }
        return urlEncoded.removingPercentEncoding ?? urlEncoded
    }

    private static func stripHTML(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "<br>", with: " ")
            .replacingOccurrences(of: "<br/>", with: " ")
        while let open = result.firstIndex(of: "<"), let close = result[open...].firstIndex(of: ">") {
            result.removeSubrange(open...close)
        }
        return result
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Export

    public static func xml(from board: Board) -> String {
        var cellsXML = ""
        var cellID = 1
        var drawioID: [ElementID: String] = [:]
        func nextID() -> String {
            cellID += 1
            return "cell-\(cellID)"
        }
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        func fmt(_ value: Double) -> String { String(Int(value.rounded())) }

        for element in board.elementsInZOrder {
            guard let node = element.node else { continue }
            let id = nextID()
            drawioID[element.id] = id
            let style: String
            switch node.shape {
            case .ellipse: style = "ellipse;whiteSpace=wrap;html=1;"
            case .diamond: style = "rhombus;whiteSpace=wrap;html=1;"
            case .triangle: style = "triangle;whiteSpace=wrap;html=1;direction=north;"
            default: style = "rounded=1;whiteSpace=wrap;html=1;arcSize=8;"
            }
            let f = node.frame
            cellsXML += """
                    <mxCell id="\(id)" value="\(escape(node.semantic.name))" style="\(style)" vertex="1" parent="1">
                      <mxGeometry x="\(fmt(f.x))" y="\(fmt(f.y))" width="\(fmt(f.width))" height="\(fmt(f.height))" as="geometry"/>
                    </mxCell>\n
            """
        }
        for element in board.elementsInZOrder {
            guard let edge = element.edge,
                  let fromID = edge.from.elementID.flatMap({ drawioID[$0] }),
                  let toID = edge.to.elementID.flatMap({ drawioID[$0] }) else { continue }
            let caption = [edge.semantic.label, edge.semantic.properties[WellKnownEdgeProperty.protocolKey]]
                .compactMap { $0 }.joined(separator: " · ")
            let arrows: String
            switch edge.semantic.direction {
            case .both: arrows = "startArrow=classic;endArrow=classic;"
            case .backward: arrows = "startArrow=classic;endArrow=none;"
            case EdgeDirection.none: arrows = "startArrow=none;endArrow=none;"
            default: arrows = "endArrow=classic;"
            }
            cellsXML += """
                    <mxCell id="\(nextID())" value="\(escape(caption))" style="edgeStyle=none;rounded=1;html=1;\(arrows)" edge="1" parent="1" source="\(fromID)" target="\(toID)">
                      <mxGeometry relative="1" as="geometry"/>
                    </mxCell>\n
            """
        }
        for element in board.elementsInZOrder {
            guard case .note(let note) = element.content, !note.text.isEmpty else { continue }
            cellsXML += """
                    <mxCell id="\(nextID())" value="\(escape(note.text))" style="text;html=1;align=left;verticalAlign=top;" vertex="1" parent="1">
                      <mxGeometry x="\(fmt(note.frame.x))" y="\(fmt(note.frame.y))" width="\(fmt(max(note.frame.width, 60)))" height="\(fmt(max(note.frame.height, 24)))" as="geometry"/>
                    </mxCell>\n
            """
        }

        return """
        <mxfile host="Designer" agent="Designer" version="24.0.0" type="device">
          <diagram id="designer-1" name="\(board.title.isEmpty ? "Page-1" : board.title)">
            <mxGraphModel dx="0" dy="0" grid="0" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="1169" pageHeight="826" math="0" shadow="0">
              <root>
                <mxCell id="0"/>
                <mxCell id="1" parent="0"/>
        \(cellsXML)      </root>
            </mxGraphModel>
          </diagram>
        </mxfile>
        """
    }
}
