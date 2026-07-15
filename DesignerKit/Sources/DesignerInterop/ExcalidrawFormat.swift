import Foundation
import DesignerModel

/// Excalidraw interchange (`.excalidraw` JSON, file format v2).
///
/// Mapping (import ⇄ export):
///   rectangle/ellipse/diamond ⇄ blocks (bound text = the block's name)
///   arrow with bindings       ⇄ connectors (bound text = label)
///   freedraw                  ⇄ ink strokes
///   standalone text           ⇄ notes
///   triangle blocks           → closed 3-point line (Excalidraw has none)
/// Layers/flows/kinds have no Excalidraw equivalent and are dropped on
/// export; imported elements land on the base layer.
public enum ExcalidrawFormat {
    // MARK: - Import

    public struct ImportResult {
        public let board: Board
        public let warnings: [String]
    }

    public enum ImportError: Error, LocalizedError {
        case notExcalidraw
        public var errorDescription: String? {
            "This doesn't look like an Excalidraw file (missing type/elements)."
        }
    }

    public static func board(from data: Data, title: String) throws -> ImportResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]],
              (root["type"] as? String) == "excalidraw" || root["type"] == nil
        else { throw ImportError.notExcalidraw }

        var board = Board(title: title)
        let layer = board.layers[0].id
        var warnings: [String] = []
        var elementForExcalidrawID: [String: ElementID] = [:]

        func double(_ value: Any?) -> Double? {
            (value as? Double) ?? (value as? Int).map(Double.init) ?? (value as? NSNumber)?.doubleValue
        }
        func insert(_ element: Element) {
            try? board.apply(.insertElement(element))
        }

        // Pass 1: shapes → blocks, freedraw → ink, standalone text → notes.
        var containerText: [String: String] = [:] // excalidraw container id → label
        for raw in elements where (raw["isDeleted"] as? Bool) != true {
            guard let type = raw["type"] as? String else { continue }
            if type == "text", let containerID = raw["containerId"] as? String,
               let text = raw["text"] as? String {
                containerText[containerID] = text
            }
        }

        for raw in elements where (raw["isDeleted"] as? Bool) != true {
            guard let type = raw["type"] as? String,
                  let id = raw["id"] as? String,
                  let x = double(raw["x"]), let y = double(raw["y"]) else { continue }
            let width = double(raw["width"]) ?? 0
            let height = double(raw["height"]) ?? 0

            switch type {
            case "rectangle", "ellipse", "diamond":
                let shape: NodeShape = type == "ellipse" ? .ellipse
                    : type == "diamond" ? .diamond : .rectangle
                let name = containerText[id]?
                    .replacingOccurrences(of: "\n", with: " ") ?? ""
                let element = Element(
                    layerIDs: [layer], sortKey: board.topSortKey,
                    content: .node(Node(
                        semantic: NodeSemantic(name: name),
                        frame: Rect(x: x, y: y, width: max(width, 24), height: max(height, 24)),
                        shape: shape
                    ))
                )
                elementForExcalidrawID[id] = element.id
                insert(element)

            case "freedraw":
                guard let points = raw["points"] as? [[Any]] else { continue }
                let strokePoints = points.compactMap { pair -> StrokePoint? in
                    guard pair.count >= 2, let px = double(pair[0]), let py = double(pair[1]) else { return nil }
                    return StrokePoint(x: x + px, y: y + py)
                }
                guard strokePoints.count >= 2 else { continue }
                insert(Element(layerIDs: [layer], sortKey: board.topSortKey,
                               content: .ink(Ink(points: strokePoints))))

            case "text" where raw["containerId"] == nil || raw["containerId"] is NSNull:
                guard let text = raw["text"] as? String, !text.isEmpty else { continue }
                insert(Element(layerIDs: [layer], sortKey: board.topSortKey,
                               content: .note(Note(text: text, frame: Rect(
                                   x: x, y: y, width: max(width, 40), height: max(height, 20))))))

            default:
                break // arrows/lines in pass 2; images/frames unsupported
            }
        }

        // Pass 2: arrows → connectors (bound endpoints when available,
        // free endpoints otherwise — they show as dangling and can snap in).
        for raw in elements where (raw["isDeleted"] as? Bool) != true {
            guard let type = raw["type"] as? String, type == "arrow" || type == "line",
                  let id = raw["id"] as? String,
                  let x = double(raw["x"]), let y = double(raw["y"]),
                  let points = raw["points"] as? [[Any]], points.count >= 2 else { continue }

            func anchor(_ binding: Any?, at point: [Any]) -> Anchor {
                if let binding = binding as? [String: Any],
                   let target = binding["elementId"] as? String,
                   let mapped = elementForExcalidrawID[target] {
                    return .element(mapped, side: nil, offset: nil)
                }
                let px = double(point.count >= 1 ? point[0] : 0) ?? 0
                let py = double(point.count >= 2 ? point[1] : 0) ?? 0
                return .free(Point(x: x + px, y: y + py))
            }
            let from = anchor(raw["startBinding"], at: points[0])
            let to = anchor(raw["endBinding"], at: points[points.count - 1])
            if type == "line", !(from.elementID != nil || to.elementID != nil) {
                // An unbound plain line is drawing, not a connector.
                let strokePoints = points.compactMap { pair -> StrokePoint? in
                    guard pair.count >= 2, let px = double(pair[0]), let py = double(pair[1]) else { return nil }
                    return StrokePoint(x: x + px, y: y + py)
                }
                if strokePoints.count >= 2 {
                    insert(Element(layerIDs: [layer], sortKey: board.topSortKey,
                                   content: .ink(Ink(points: strokePoints))))
                }
                continue
            }
            let label = containerText[id]
            insert(Element(layerIDs: [layer], sortKey: board.topSortKey,
                           content: .edge(Edge(
                               semantic: EdgeSemantic(label: label),
                               from: from, to: to))))
        }

        if board.elements.isEmpty {
            warnings.append("no supported elements found (images/frames are skipped)")
        }
        return ImportResult(board: board, warnings: warnings)
    }

    // MARK: - Export

    public static func data(from board: Board) throws -> Data {
        var elements: [[String: Any]] = []
        var counter = 0
        func nextID(_ prefix: String) -> String {
            counter += 1
            return "\(prefix)-\(counter)"
        }
        /// Excalidraw's restore() fills gaps, but these keep files valid in
        /// older builds too.
        func base(_ type: String, id: String, x: Double, y: Double, w: Double, h: Double) -> [String: Any] {
            [
                "id": id, "type": type,
                "x": x, "y": y, "width": w, "height": h,
                "angle": 0, "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
                "fillStyle": "solid", "strokeWidth": 1, "strokeStyle": "solid",
                "roughness": 1, "opacity": 100, "groupIds": [], "frameId": NSNull(),
                "roundness": NSNull(), "seed": counter * 7919 + 1,
                "version": 1, "versionNonce": counter * 104729 + 1,
                "isDeleted": false, "boundElements": NSNull(),
                "updated": 1, "link": NSNull(), "locked": false,
            ]
        }
        func textElement(_ text: String, containerID: String?, frame: Rect, fontSize: Double = 16) -> [String: Any] {
            var element = base("text", id: nextID("text"),
                               x: frame.midX - Double(text.count) * fontSize * 0.3,
                               y: frame.midY - fontSize * 0.6,
                               w: Double(text.count) * fontSize * 0.6, h: fontSize * 1.2)
            element["text"] = text
            element["originalText"] = text
            element["fontSize"] = fontSize
            element["fontFamily"] = 1
            element["textAlign"] = "center"
            element["verticalAlign"] = "middle"
            element["containerId"] = containerID ?? NSNull()
            element["lineHeight"] = 1.25
            return element
        }

        var excalidrawID: [ElementID: String] = [:]

        // Blocks (+ bound name text).
        for element in board.elementsInZOrder {
            guard let node = element.node else { continue }
            let id = nextID("node")
            excalidrawID[element.id] = id
            let f = node.frame
            switch node.shape {
            case .triangle:
                // No triangle in Excalidraw: a closed 3-point line.
                var tri = base("line", id: id, x: f.x, y: f.y, w: f.width, h: f.height)
                tri["points"] = [[f.width / 2, 0.0], [f.width, f.height], [0.0, f.height], [f.width / 2, 0.0]]
                tri["polygon"] = true
                elements.append(tri)
            default:
                let type = node.shape == .ellipse ? "ellipse"
                    : node.shape == .diamond ? "diamond" : "rectangle"
                var shape = base(type, id: id, x: f.x, y: f.y, w: f.width, h: f.height)
                if !node.semantic.name.isEmpty {
                    let text = textElement(node.semantic.name, containerID: id, frame: f)
                    shape["boundElements"] = [["type": "text", "id": text["id"] as? String ?? ""]]
                    elements.append(shape)
                    elements.append(text)
                } else {
                    elements.append(shape)
                }
            }
        }

        // Connectors as bound arrows.
        let frames = board.frameProvider()
        for element in board.elementsInZOrder {
            guard let edge = element.edge,
                  let route = EdgeGeometry.route(for: edge, frames: frames) else { continue }
            let id = nextID("arrow")
            let start = route.start, end = route.end
            var arrow = base("arrow", id: id, x: start.x, y: start.y,
                             w: abs(end.x - start.x), h: abs(end.y - start.y))
            arrow["points"] = [[0.0, 0.0], [end.x - start.x, end.y - start.y]]
            arrow["startArrowhead"] = (edge.semantic.direction == .backward || edge.semantic.direction == .both) ? "arrow" : NSNull()
            arrow["endArrowhead"] = (edge.semantic.direction == .forward || edge.semantic.direction == .both) ? "arrow" : NSNull()
            if let fromID = edge.from.elementID, let bound = excalidrawID[fromID] {
                arrow["startBinding"] = ["elementId": bound, "focus": 0, "gap": 4]
            }
            if let toID = edge.to.elementID, let bound = excalidrawID[toID] {
                arrow["endBinding"] = ["elementId": bound, "focus": 0, "gap": 4]
            }
            let caption = [edge.semantic.label, edge.semantic.properties[WellKnownEdgeProperty.protocolKey]]
                .compactMap { $0 }.joined(separator: " · ")
            if !caption.isEmpty {
                let mid = route.midpoint
                let text = textElement(caption, containerID: id,
                                       frame: Rect(x: mid.x, y: mid.y, width: 0, height: 0), fontSize: 12)
                arrow["boundElements"] = [["type": "text", "id": text["id"] as? String ?? ""]]
                elements.append(arrow)
                elements.append(text)
            } else {
                elements.append(arrow)
            }
        }

        // Ink → freedraw; notes → text.
        for element in board.elementsInZOrder {
            switch element.content {
            case .ink(let ink):
                guard let first = ink.points.first else { continue }
                var freedraw = base("freedraw", id: nextID("draw"),
                                    x: first.x, y: first.y, w: 0, h: 0)
                freedraw["points"] = ink.points.map { [$0.x - first.x, $0.y - first.y] }
                freedraw["pressures"] = []
                freedraw["simulatePressure"] = true
                elements.append(freedraw)
            case .note(let note):
                elements.append(textElement(note.text, containerID: nil, frame: note.frame, fontSize: 14))
            default:
                break
            }
        }

        let document: [String: Any] = [
            "type": "excalidraw",
            "version": 2,
            "source": "designer",
            "elements": elements,
            "appState": ["viewBackgroundColor": "#ffffff", "gridSize": NSNull()],
            "files": [:],
        ]
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    }
}
