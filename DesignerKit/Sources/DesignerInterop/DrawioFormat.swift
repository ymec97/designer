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
///   vertex cells ⇄ blocks (shape, fill/stroke colors, embedded images)
///   edge cells   ⇄ connectors (waypoints, entry/exit anchors, colors,
///                  floating endpoints; value or edgeLabel child = label)
///   text cells   ⇄ notes
///   group/swimlane containers ⇄ boundaries (children get absolute coords)
/// The original LAYOUT is preserved exactly — positions, sizes, and edge
/// routes come straight from the file, never from auto-layout.
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
            var style: [String: String]
            var styleTokens: Set<String>
            var isVertex: Bool
            var isEdge: Bool
            var source: String?
            var target: String?
            var parent: String?
            var frame: Rect?          // as written: relative to the parent cell
            var relative: Bool
            var waypoints: [Point]
            var sourcePoint: Point?
            var targetPoint: Point?
        }

        // draw.io style: "ellipse;fillColor=#dae8fc;html=1" — leading bare
        // tokens name the shape, key=value pairs configure it.
        func parseStyle(_ raw: String) -> (dict: [String: String], tokens: Set<String>) {
            var dict: [String: String] = [:]
            var tokens: Set<String> = []
            for part in raw.split(separator: ";") {
                if let eq = part.firstIndex(of: "=") {
                    dict[String(part[..<eq])] = String(part[part.index(after: eq)...])
                } else if !part.isEmpty {
                    tokens.insert(String(part))
                }
            }
            return (dict, tokens)
        }

        func parseCell(_ element: XMLElement, valueOverride: String?) -> Cell? {
            guard let id = element.attribute(forName: "id")?.stringValue else { return nil }
            var frame: Rect?
            var relative = false
            var waypoints: [Point] = []
            var sourcePoint: Point?
            var targetPoint: Point?
            if let geometry = element.children?.compactMap({ $0 as? XMLElement })
                .first(where: { $0.name == "mxGeometry" }) {
                let x = Double(geometry.attribute(forName: "x")?.stringValue ?? "") ?? 0
                let y = Double(geometry.attribute(forName: "y")?.stringValue ?? "") ?? 0
                let w = Double(geometry.attribute(forName: "width")?.stringValue ?? "") ?? 0
                let h = Double(geometry.attribute(forName: "height")?.stringValue ?? "") ?? 0
                frame = Rect(x: x, y: y, width: w, height: h)
                relative = geometry.attribute(forName: "relative")?.stringValue == "1"
                for child in geometry.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                    func point(_ e: XMLElement) -> Point {
                        Point(x: Double(e.attribute(forName: "x")?.stringValue ?? "") ?? 0,
                              y: Double(e.attribute(forName: "y")?.stringValue ?? "") ?? 0)
                    }
                    switch (child.name, child.attribute(forName: "as")?.stringValue) {
                    case ("mxPoint", "sourcePoint"): sourcePoint = point(child)
                    case ("mxPoint", "targetPoint"): targetPoint = point(child)
                    case ("Array", "points"):
                        waypoints = (child.children?.compactMap { $0 as? XMLElement } ?? [])
                            .filter { $0.name == "mxPoint" }.map(point)
                    default: break
                    }
                }
            }
            let style = element.attribute(forName: "style")?.stringValue ?? ""
            let parsed = parseStyle(style)
            return Cell(
                id: id,
                value: stripHTML(valueOverride ?? element.attribute(forName: "value")?.stringValue ?? ""),
                style: parsed.dict,
                styleTokens: parsed.tokens,
                isVertex: element.attribute(forName: "vertex")?.stringValue == "1",
                isEdge: element.attribute(forName: "edge")?.stringValue == "1",
                source: element.attribute(forName: "source")?.stringValue,
                target: element.attribute(forName: "target")?.stringValue,
                parent: element.attribute(forName: "parent")?.stringValue,
                frame: frame,
                relative: relative,
                waypoints: waypoints,
                sourcePoint: sourcePoint,
                targetPoint: targetPoint
            )
        }

        var cells: [Cell] = []
        var cellByID: [String: Cell] = [:]
        for node in (try? model.nodes(forXPath: ".//mxCell")) ?? [] {
            guard let element = node as? XMLElement else { continue }
            // <object label="…"><mxCell …/></object> wraps custom-data cells.
            let wrapper = element.parent as? XMLElement
            let label = (wrapper?.name == "object" || wrapper?.name == "UserObject")
                ? wrapper?.attribute(forName: "label")?.stringValue : nil
            // The object wrapper carries the id in that case.
            if var cell = parseCell(element, valueOverride: label) {
                if cell.id.isEmpty, let wrapperID = wrapper?.attribute(forName: "id")?.stringValue {
                    cell.id = wrapperID
                }
                cells.append(cell)
                cellByID[cell.id] = cell
            }
        }

        // Positions inside containers are parent-relative — walk the parent
        // chain to the root so every element lands at its absolute spot.
        func parentOrigin(of cell: Cell) -> Point {
            var x = 0.0, y = 0.0
            var parentID = cell.parent
            var hops = 0
            while let id = parentID, let parent = cellByID[id], hops < 32 {
                if parent.isVertex, let frame = parent.frame {
                    x += frame.x
                    y += frame.y
                }
                parentID = parent.parent
                hops += 1
            }
            return Point(x: x, y: y)
        }

        func absoluteFrame(of cell: Cell) -> Rect? {
            guard let frame = cell.frame else { return nil }
            let origin = parentOrigin(of: cell)
            return Rect(x: frame.x + origin.x, y: frame.y + origin.y,
                        width: frame.width, height: frame.height)
        }

        func shape(for cell: Cell) -> NodeShape {
            let tokens = cell.styleTokens
            let shapeName = cell.style["shape"] ?? ""
            if tokens.contains("ellipse") || shapeName == "ellipse" {
                // draw.io clouds are ellipse-family ("ellipse;shape=cloud").
                return shapeName == "cloud" ? .cloud : .ellipse
            }
            if shapeName == "cloud" { return .cloud }
            if shapeName.hasPrefix("cylinder") || tokens.contains("cylinder") { return .cylinder }
            if tokens.contains("rhombus") || shapeName == "rhombus" { return .diamond }
            if tokens.contains("triangle") || shapeName == "triangle" { return .triangle }
            return .rectangle
        }

        // Stencil names carry semantics even when we can't draw the exact
        // artwork (aws4.s3, mq_broker, …) — keep them as node kinds so the
        // kind dot and future styling still say what the thing is.
        func kind(for cell: Cell) -> NodeKind {
            let hint = ((cell.style["shape"] ?? "") + ";" + (cell.style["prIcon"] ?? "")).lowercased()
            guard !hint.isEmpty else { return .generic }
            if ["s3", "bucket", "storage", "database", "rds", "dynamo", "aurora", "redshift", "cylinder"]
                .contains(where: hint.contains) { return .database }
            if ["mq", "queue", "sqs", "kafka", "kinesis", "broker", "event_bus", "sns"]
                .contains(where: hint.contains) { return .queue }
            if ["elasticache", "redis", "memcache"].contains(where: hint.contains) { return .cache }
            if ["gateway", "api_g", "cloudfront", "route_53", "load_balanc", "elb", "alb"]
                .contains(where: hint.contains) { return .gateway }
            if ["lambda", "ec2", "ecs", "eks", "fargate", "knative", "container"]
                .contains(where: hint.contains) { return .service }
            if ["user", "client", "mobile", "browser"].contains(where: hint.contains) { return .client }
            return .generic
        }

        func styling(for cell: Cell) -> Style {
            var style = Style()
            if let fill = cell.style["fillColor"], fill != "none", fill.hasPrefix("#") {
                style.fill = fill
            }
            if let stroke = cell.style["strokeColor"], stroke != "none", stroke.hasPrefix("#") {
                style.stroke = stroke
            }
            if let width = cell.style["strokeWidth"].flatMap(Double.init) { style.strokeWidth = width }
            // Embedded images travel as data: URIs right in the style. Library
            // references (image=img/lib/…) point into draw.io's own bundle and
            // can't be resolved offline.
            if var image = cell.style["image"] {
                // draw.io escapes ";" and "=" inside style values.
                image = image.replacingOccurrences(of: "%3B", with: ";")
                    .replacingOccurrences(of: "%3D", with: "=")
                if image.hasPrefix("data:") {
                    style.image = image
                } else {
                    warnings.append("'\(cell.value.isEmpty ? cell.id : cell.value)' uses a draw.io library image — not embedded in the file, skipped")
                }
            }
            return style
        }

        func isTextCell(_ cell: Cell) -> Bool {
            cell.styleTokens.contains("text") || cell.style["text"] != nil
        }

        func isContainer(_ cell: Cell) -> Bool {
            cell.styleTokens.contains("group") || cell.style["group"] != nil
                || cell.styleTokens.contains("swimlane") || (cell.style["shape"] ?? "") == "swimlane"
        }

        func isEdgeLabel(_ cell: Cell) -> Bool {
            cell.styleTokens.contains("edgeLabel") || cell.style["edgeLabel"] != nil
        }

        // Vertices: containers become boundaries, text-style cells notes,
        // the rest blocks. Frames are kept EXACTLY as drawn.
        for cell in cells where cell.isVertex && !isEdgeLabel(cell) && !cell.relative {
            guard let frame = absoluteFrame(of: cell), frame.width > 0, frame.height > 0 else { continue }
            if isContainer(cell) {
                let element = Element(layerIDs: [layer], sortKey: board.topSortKey,
                                      content: .boundary(Note(text: cell.value, frame: frame)))
                try? board.apply(.insertElement(element))
                continue
            }
            if isTextCell(cell) {
                guard !cell.value.isEmpty else { continue }
                let element = Element(layerIDs: [layer], sortKey: board.topSortKey,
                                      content: .note(Note(text: cell.value, frame: frame,
                                                          style: styling(for: cell))))
                try? board.apply(.insertElement(element))
                continue
            }
            let element = Element(
                layerIDs: [layer], sortKey: board.topSortKey,
                content: .node(Node(
                    semantic: NodeSemantic(kind: kind(for: cell), name: cell.value),
                    frame: frame,
                    shape: shape(for: cell),
                    style: styling(for: cell)
                ))
            )
            elementForCellID[cell.id] = element.id
            try? board.apply(.insertElement(element))
        }

        // draw.io fixed connection points: exitX/exitY (source side),
        // entryX/entryY (target side) in unit coordinates on the node.
        func pinnedAnchor(_ cell: Cell, xKey: String, yKey: String, elementID: ElementID) -> Anchor {
            guard let x = cell.style[xKey].flatMap(Double.init),
                  let y = cell.style[yKey].flatMap(Double.init) else {
                return .element(elementID, side: nil, offset: nil)
            }
            // Snap to the nearest side; the offset is the position along it.
            let side: Anchor.Side
            let offset: Double
            let dLeft = x, dRight = 1 - x, dTop = y, dBottom = 1 - y
            let smallest = min(dLeft, dRight, dTop, dBottom)
            switch smallest {
            case dTop: side = .top; offset = x
            case dBottom: side = .bottom; offset = x
            case dLeft: side = .left; offset = y
            default: side = .right; offset = y
            }
            return .element(elementID, side: side, offset: max(0, min(1, offset)))
        }

        // Edges: keep the drawn route — waypoints, pinned ends, and floating
        // endpoints (an arrow to empty canvas is still an arrow).
        for cell in cells where cell.isEdge {
            let origin = parentOrigin(of: cell)
            func translated(_ p: Point) -> Point { Point(x: p.x + origin.x, y: p.y + origin.y) }

            let from: Anchor
            if let sourceID = cell.source.flatMap({ elementForCellID[$0] }) {
                from = pinnedAnchor(cell, xKey: "exitX", yKey: "exitY", elementID: sourceID)
            } else if let point = cell.sourcePoint {
                from = .free(translated(point))
            } else {
                warnings.append("edge '\(cell.id)' has no source — skipped")
                continue
            }
            let to: Anchor
            if let targetID = cell.target.flatMap({ elementForCellID[$0] }) {
                to = pinnedAnchor(cell, xKey: "entryX", yKey: "entryY", elementID: targetID)
            } else if let point = cell.targetPoint {
                to = .free(translated(point))
            } else {
                warnings.append("edge '\(cell.id)' has no target — skipped")
                continue
            }

            let direction: EdgeDirection
            let startArrow = cell.style["startArrow"] ?? "none"
            let endArrow = cell.style["endArrow"] ?? "classic"
            switch (startArrow != "none", endArrow != "none") {
            case (true, true): direction = .both
            case (true, false): direction = .backward
            case (false, false): direction = .none
            default: direction = .forward
            }

            var style = Style()
            if let stroke = cell.style["strokeColor"], stroke != "none", stroke.hasPrefix("#") {
                style.stroke = stroke
            }
            if let width = cell.style["strokeWidth"].flatMap(Double.init) { style.strokeWidth = width }

            // Waypoints reproduce the authored route exactly (orthogonal
            // routing draws the literal polyline through them).
            let waypoints = cell.waypoints.map(translated)
            let element = Element(
                layerIDs: [layer], sortKey: board.topSortKey,
                content: .edge(Edge(
                    semantic: EdgeSemantic(label: cell.value.isEmpty ? nil : cell.value,
                                           direction: direction),
                    from: from,
                    to: to,
                    routing: waypoints.isEmpty
                        ? ((cell.style["edgeStyle"] ?? "").contains("orthogonal") ? .orthogonal : .straight)
                        : .orthogonal,
                    waypoints: waypoints,
                    style: style
                ))
            )
            edgeElementForCellID[cell.id] = element.id
            try? board.apply(.insertElement(element))
        }

        // Edge labels living as child cells (style edgeLabel, parent = edge).
        for cell in cells where isEdgeLabel(cell) && !cell.value.isEmpty {
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

        func colorSuffix(_ style: Style) -> String {
            var suffix = ""
            if let fill = style.fill { suffix += "fillColor=\(fill);" }
            if let stroke = style.stroke { suffix += "strokeColor=\(stroke);" }
            if let width = style.strokeWidth { suffix += "strokeWidth=\(width);" }
            return suffix
        }

        for element in board.elementsInZOrder {
            guard let node = element.node else { continue }
            let id = nextID()
            drawioID[element.id] = id
            var style: String
            switch node.shape {
            case .ellipse: style = "ellipse;whiteSpace=wrap;html=1;"
            case .diamond: style = "rhombus;whiteSpace=wrap;html=1;"
            case .triangle: style = "triangle;whiteSpace=wrap;html=1;direction=north;"
            case .cylinder: style = "shape=cylinder3;whiteSpace=wrap;html=1;boundedLbl=1;backgroundOutline=1;size=15;"
            case .cloud: style = "ellipse;shape=cloud;whiteSpace=wrap;html=1;"
            default: style = "rounded=1;whiteSpace=wrap;html=1;arcSize=8;"
            }
            style += colorSuffix(node.style)
            if let image = node.style.image {
                // draw.io escapes ";" and "=" inside style values.
                let escaped = image.replacingOccurrences(of: ";", with: "%3B")
                    .replacingOccurrences(of: "=", with: "%3D")
                style = "shape=image;verticalLabelPosition=bottom;verticalAlign=top;imageAspect=1;image=\(escaped);"
            }
            let f = node.frame
            cellsXML += """
                    <mxCell id="\(id)" value="\(escape(node.semantic.name))" style="\(style)" vertex="1" parent="1">
                      <mxGeometry x="\(fmt(f.x))" y="\(fmt(f.y))" width="\(fmt(f.width))" height="\(fmt(f.height))" as="geometry"/>
                    </mxCell>\n
            """
        }
        for element in board.elementsInZOrder {
            guard let edge = element.edge else { continue }
            // Attached ends reference cells; free ends become fixed points.
            var endpointAttributes = ""
            var endpointPoints = ""
            switch edge.from {
            case .element(let id, _, _):
                guard let fromID = drawioID[id] else { continue }
                endpointAttributes += " source=\"\(fromID)\""
            case .free(let point):
                endpointPoints += "<mxPoint x=\"\(fmt(point.x))\" y=\"\(fmt(point.y))\" as=\"sourcePoint\"/>"
            }
            switch edge.to {
            case .element(let id, _, _):
                guard let toID = drawioID[id] else { continue }
                endpointAttributes += " target=\"\(toID)\""
            case .free(let point):
                endpointPoints += "<mxPoint x=\"\(fmt(point.x))\" y=\"\(fmt(point.y))\" as=\"targetPoint\"/>"
            }
            let caption = [edge.semantic.label, edge.semantic.properties[WellKnownEdgeProperty.protocolKey]]
                .compactMap { $0 }.joined(separator: " · ")
            let arrows: String
            switch edge.semantic.direction {
            case .both: arrows = "startArrow=classic;endArrow=classic;"
            case .backward: arrows = "startArrow=classic;endArrow=none;"
            case EdgeDirection.none: arrows = "startArrow=none;endArrow=none;"
            default: arrows = "endArrow=classic;"
            }
            let edgeStyle = edge.routing == .orthogonal
                ? "edgeStyle=orthogonalEdgeStyle;rounded=0;" : "edgeStyle=none;rounded=1;"
            let waypointsXML = edge.waypoints.isEmpty ? "" : "<Array as=\"points\">"
                + edge.waypoints.map { "<mxPoint x=\"\(fmt($0.x))\" y=\"\(fmt($0.y))\"/>" }.joined()
                + "</Array>"
            cellsXML += """
                    <mxCell id="\(nextID())" value="\(escape(caption))" style="\(edgeStyle)html=1;\(arrows)\(colorSuffix(edge.style))" edge="1" parent="1"\(endpointAttributes)>
                      <mxGeometry relative="1" as="geometry">\(endpointPoints)\(waypointsXML)</mxGeometry>
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
