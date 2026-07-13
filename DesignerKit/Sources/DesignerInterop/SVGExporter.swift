import Foundation
import DesignerModel

/// Hand-generated SVG for a board. macOS has no public SVG *writer*, so we
/// emit the XML directly — straightforward for our small primitive set, and
/// it lets us attach semantic `data-*` attributes so exported diagrams stay
/// machine-readable. Colors are baked (a self-contained file has no app
/// theme), defaulting to a light palette.
public enum SVGExporter {
    public struct Palette: Sendable {
        public var background: String
        public var nodeFill: String
        public var nodeStroke: String
        public var text: String
        public var edge: String
        public var ink: String

        public static let light = Palette(
            background: "#FFFFFF", nodeFill: "#F5F6F8", nodeStroke: "#8A8F98",
            text: "#1D1D1F", edge: "#6E7178", ink: "#1D1D1F"
        )
    }

    public static func export(
        _ board: Board, selection: Set<ElementID>? = nil, palette: Palette = .light, padding: Double = 24
    ) -> String {
        let source: Board
        if let selection, !selection.isEmpty {
            source = board.makeClip(of: selection)
        } else {
            source = board
        }

        let bounds = source.contentBounds() ?? Rect(x: 0, y: 0, width: 100, height: 100)
        let width = bounds.width + padding * 2
        let height = bounds.height + padding * 2
        let originX = bounds.x - padding
        let originY = bounds.y - padding
        let frames = source.frameProvider()

        var body = ""
        // Edges under nodes.
        for element in source.elementsInZOrder {
            guard let edge = element.edge,
                  let route = EdgeGeometry.route(for: edge, frames: frames) else { continue }
            body += svgEdge(edge, route: route, palette: palette)
        }
        for element in source.elementsInZOrder {
            switch element.content {
            case .node(let node): body += svgNode(node, palette: palette)
            case .note(let note): body += svgNote(note, palette: palette)
            case .ink(let ink): body += svgInk(ink, palette: palette)
            case .edge: break
            }
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" \
        width="\(fmt(width))" height="\(fmt(height))" \
        viewBox="\(fmt(originX)) \(fmt(originY)) \(fmt(width)) \(fmt(height))">
        <defs>
        <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
        <path d="M0,0 L10,5 L0,10 z" fill="\(palette.edge)"/>
        </marker>
        </defs>
        <rect x="\(fmt(originX))" y="\(fmt(originY))" width="\(fmt(width))" height="\(fmt(height))" fill="\(palette.background)"/>
        \(body)</svg>
        """
    }

    // MARK: Elements

    private static func svgNode(_ node: Node, palette: Palette) -> String {
        let f = node.frame
        let shapeSVG: String
        switch node.shape {
        case .ellipse:
            shapeSVG = "<ellipse cx=\"\(fmt(f.midX))\" cy=\"\(fmt(f.midY))\" rx=\"\(fmt(f.width / 2))\" ry=\"\(fmt(f.height / 2))\" fill=\"\(fill(node, palette))\" stroke=\"\(palette.nodeStroke)\" stroke-width=\"1.5\"/>"
        case .diamond:
            let points = "\(fmt(f.midX)),\(fmt(f.y)) \(fmt(f.maxX)),\(fmt(f.midY)) \(fmt(f.midX)),\(fmt(f.maxY)) \(fmt(f.x)),\(fmt(f.midY))"
            shapeSVG = "<polygon points=\"\(points)\" fill=\"\(fill(node, palette))\" stroke=\"\(palette.nodeStroke)\" stroke-width=\"1.5\"/>"
        case .triangle:
            shapeSVG = "<polygon points=\"\(trianglePoints(f, node.orientation))\" fill=\"\(fill(node, palette))\" stroke=\"\(palette.nodeStroke)\" stroke-width=\"1.5\"/>"
        default:
            shapeSVG = "<rect x=\"\(fmt(f.x))\" y=\"\(fmt(f.y))\" width=\"\(fmt(f.width))\" height=\"\(fmt(f.height))\" rx=\"8\" fill=\"\(fill(node, palette))\" stroke=\"\(palette.nodeStroke)\" stroke-width=\"1.5\"/>"
        }
        let label = node.semantic.name.isEmpty ? "" : centeredText(
            node.semantic.name, x: f.midX, y: f.midY, size: 13, weight: "500", color: palette.text
        )
        return """
        <g data-kind="\(escape(node.semantic.kind.rawValue))" data-shape="\(node.shape.rawValue)"\(node.semantic.name.isEmpty ? "" : " data-name=\"\(escape(node.semantic.name))\"")>
        \(shapeSVG)\(label)
        </g>
        """
    }

    private static func svgEdge(_ edge: Edge, route: EdgeGeometry.Route, palette: Palette) -> String {
        let points = route.points.map { "\(fmt($0.x)),\(fmt($0.y))" }.joined(separator: " ")
        let markerStart = (edge.semantic.direction == .backward || edge.semantic.direction == .both)
            ? " marker-start=\"url(#arrow)\"" : ""
        let markerEnd = (edge.semantic.direction == .forward || edge.semantic.direction == .both)
            ? " marker-end=\"url(#arrow)\"" : ""

        var attributes = ""
        if let proto = edge.semantic.properties[WellKnownEdgeProperty.protocolKey] {
            attributes += " data-protocol=\"\(escape(proto))\""
        }
        if let data = edge.semantic.properties[WellKnownEdgeProperty.data] {
            attributes += " data-payload=\"\(escape(data))\""
        }

        var svg = "<polyline points=\"\(points)\" fill=\"none\" stroke=\"\(palette.edge)\" stroke-width=\"1.5\"\(markerStart)\(markerEnd)\(attributes)/>"

        // Caption at the midpoint.
        let caption = [
            edge.semantic.label,
            edge.semantic.properties[WellKnownEdgeProperty.protocolKey].map { "protocol: \($0)" },
        ].compactMap { $0 }.filter { !$0.isEmpty }
        if !caption.isEmpty {
            let mid = route.midpoint
            for (index, line) in caption.enumerated() {
                svg += centeredText(
                    line, x: mid.x, y: mid.y + Double(index) * 14 - Double(caption.count - 1) * 7,
                    size: index == 0 ? 12 : 10, weight: index == 0 ? "500" : "400",
                    color: index == 0 ? palette.text : palette.edge,
                    background: palette.background
                )
            }
        }
        return svg + "\n"
    }

    private static func svgNote(_ note: Note, palette: Palette) -> String {
        guard !note.text.isEmpty else { return "" }
        return "<text x=\"\(fmt(note.frame.x))\" y=\"\(fmt(note.frame.y + 14))\" font-family=\"-apple-system, sans-serif\" font-size=\"12\" fill=\"\(palette.text)\">\(escape(note.text))</text>\n"
    }

    private static func svgInk(_ ink: Ink, palette: Palette) -> String {
        guard ink.points.count > 1 else { return "" }
        let d = ink.points.enumerated().map { index, point in
            "\(index == 0 ? "M" : "L")\(fmt(point.x)) \(fmt(point.y))"
        }.joined(separator: " ")
        return "<path d=\"\(d)\" fill=\"none\" stroke=\"\(palette.ink)\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n"
    }

    // MARK: Helpers

    private static func trianglePoints(_ f: Rect, _ orientation: ShapeOrientation) -> String {
        let vertices: [(Double, Double)]
        switch orientation {
        case .down: vertices = [(f.x, f.y), (f.maxX, f.y), (f.midX, f.maxY)]
        case .left: vertices = [(f.maxX, f.y), (f.maxX, f.maxY), (f.x, f.midY)]
        case .right: vertices = [(f.x, f.y), (f.x, f.maxY), (f.maxX, f.midY)]
        default: vertices = [(f.midX, f.y), (f.maxX, f.maxY), (f.x, f.maxY)]
        }
        return vertices.map { "\(fmt($0.0)),\(fmt($0.1))" }.joined(separator: " ")
    }

    private static func centeredText(
        _ text: String, x: Double, y: Double, size: Double, weight: String, color: String,
        background: String? = nil
    ) -> String {
        var result = ""
        if let background {
            // A subtle backing rect so labels stay legible over lines.
            let width = Double(text.count) * size * 0.58 + 8
            result += "<rect x=\"\(fmt(x - width / 2))\" y=\"\(fmt(y - size * 0.7))\" width=\"\(fmt(width))\" height=\"\(fmt(size * 1.4))\" rx=\"4\" fill=\"\(background)\" opacity=\"0.85\"/>"
        }
        result += "<text x=\"\(fmt(x))\" y=\"\(fmt(y + size * 0.35))\" text-anchor=\"middle\" font-family=\"-apple-system, Helvetica, sans-serif\" font-size=\"\(fmt(size))\" font-weight=\"\(weight)\" fill=\"\(color)\">\(escape(text))</text>"
        return result
    }

    private static func fill(_ node: Node, _ palette: Palette) -> String {
        node.style.fill ?? palette.nodeFill
    }

    private static func fmt(_ value: Double) -> String {
        // Trim trailing zeros for compact, stable output.
        if value == value.rounded() { return String(Int(value.rounded())) }
        return String(format: "%.2f", value)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
