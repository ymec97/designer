import Foundation
import DesignerModel

/// Turns recognized ink into structured elements via the operation layer:
/// every conversion is one atomic batch (remove ink + insert structure), so
/// one undo returns the ink stroke exactly as drawn.
public enum SketchConversion {
    /// How close (world units) a line endpoint must be to a node to attach.
    static let endpointSnapDistance: Double = 28
    /// Recognized shapes smaller than this become at least this size.
    static let minimumNodeSize = Size(width: 60, height: 40)

    public struct Conversion {
        public let operation: BoardOperation
        /// The element the conversion produces (for selection handover).
        public let producedID: ElementID
        public let actionName: String
    }

    /// Conversion for one ink element, or nil when nothing is confidently
    /// recognized (the stroke stays ink).
    public static func conversion(for element: Element, in board: Board) -> Conversion? {
        guard case .ink(let ink) = element.content else { return nil }
        guard let recognition = StrokeRecognizer.recognize(ink.points) else { return nil }

        switch recognition {
        case .rectangle(let rect), .ellipse(let rect), .diamond(let rect), .triangle(let rect, _):
            let frame = Rect(
                x: rect.x, y: rect.y,
                width: max(rect.width, minimumNodeSize.width),
                height: max(rect.height, minimumNodeSize.height)
            )
            let shape: NodeShape
            var orientation: ShapeOrientation = .up
            switch recognition {
            case .ellipse: shape = .ellipse
            case .diamond: shape = .diamond
            case .triangle(_, let apex): shape = .triangle; orientation = apex
            default: shape = .rectangle
            }
            let node = Element(
                layerIDs: element.layerIDs,
                sortKey: element.sortKey,
                content: .node(Node(
                    semantic: NodeSemantic(kind: .generic, name: ""),
                    frame: frame,
                    shape: shape,
                    orientation: orientation
                ))
            )
            return Conversion(
                operation: .batch([.removeElement(element.id), .insertElement(node)]),
                producedID: node.id,
                actionName: "Convert to Block"
            )

        case .line(let from, let to):
            guard
                let fromNode = nearestNode(to: from, in: board, excluding: element.id),
                let toNode = nearestNode(to: to, in: board, excluding: element.id),
                fromNode != toNode
            else { return nil }

            // A stroke between an already-connected pair creates a PARALLEL
            // connector — drawn twice means two connections (gRPC + HTTP,
            // request + response), never a silent merge. Bidirectional is a
            // property set in the edge editor.
            let edge = Element(
                layerIDs: element.layerIDs,
                sortKey: element.sortKey,
                content: .edge(Edge(
                    from: .element(fromNode, side: nil, offset: nil),
                    to: .element(toNode, side: nil, offset: nil)
                ))
            )
            return Conversion(
                operation: .batch([.removeElement(element.id), .insertElement(edge)]),
                producedID: edge.id,
                actionName: "Convert to Connector"
            )
        }
    }


    // MARK: Multi-stroke chaining (P7)

    /// How close (world units) two stroke ENDPOINTS must be to chain into
    /// one virtual stroke (a box drawn as four separate lines).
    public static let chainTolerance: Double = 26

    /// Groups ink elements into endpoint-connectivity components: strokes
    /// whose ends (transitively) meet within `tolerance`.
    public static func endpointComponents(
        _ elements: [Element], tolerance: Double = chainTolerance
    ) -> [[Element]] {
        let inks: [(element: Element, ends: (Point, Point))] = elements.compactMap { element in
            guard case .ink(let ink) = element.content,
                  let first = ink.points.first, let last = ink.points.last,
                  ink.points.count >= 2 else { return nil }
            return (element, (Point(x: first.x, y: first.y), Point(x: last.x, y: last.y)))
        }
        var parent = Array(0..<inks.count)
        func find(_ i: Int) -> Int { parent[i] == i ? i : { parent[i] = find(parent[i]); return parent[i] }() }
        func near(_ a: Point, _ b: Point) -> Bool {
            (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) <= tolerance * tolerance
        }
        for i in 0..<inks.count {
            for j in (i + 1)..<inks.count {
                let (a0, a1) = inks[i].ends, (b0, b1) = inks[j].ends
                if near(a0, b0) || near(a0, b1) || near(a1, b0) || near(a1, b1) {
                    parent[find(i)] = find(j)
                }
            }
        }
        var components: [Int: [Element]] = [:]
        for (index, ink) in inks.enumerated() {
            components[find(index), default: []].append(ink.element)
        }
        return Array(components.values)
    }

    /// Orders the strokes end-to-end into one virtual stroke (reversing
    /// members as needed), or nil when they don't all join.
    public static func chain(
        _ elements: [Element], tolerance: Double = chainTolerance
    ) -> [StrokePoint]? {
        var remaining: [[StrokePoint]] = elements.compactMap { element in
            guard case .ink(let ink) = element.content, ink.points.count >= 2 else { return nil }
            return ink.points
        }
        guard remaining.count == elements.count, remaining.count >= 2 else { return nil }
        func near(_ a: StrokePoint, _ b: StrokePoint) -> Bool {
            (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) <= tolerance * tolerance
        }
        var chain = remaining.removeFirst()
        while !remaining.isEmpty {
            let tail = chain[chain.count - 1], head = chain[0]
            var attached = false
            for (index, stroke) in remaining.enumerated() {
                if near(stroke[0], tail) {
                    chain += remaining.remove(at: index); attached = true
                } else if near(stroke[stroke.count - 1], tail) {
                    chain += remaining.remove(at: index).reversed(); attached = true
                } else if near(stroke[stroke.count - 1], head) {
                    chain = remaining.remove(at: index) + chain; attached = true
                } else if near(stroke[0], head) {
                    chain = remaining.remove(at: index).reversed() + chain; attached = true
                }
                if attached { break }
            }
            if !attached { return nil }
        }
        return chain
    }

    /// P7: several strokes that join into one CLOSED shape become one block
    /// (a box drawn as four lines). Chained lines stay untouched — a chain
    /// that reads as a connector is too ambiguous to auto-convert.
    public static func chainedConversion(
        for elements: [Element], in board: Board
    ) -> Conversion? {
        guard elements.count >= 2, let merged = chain(elements) else { return nil }
        guard let recognition = StrokeRecognizer.recognize(merged) else { return nil }

        let rect: Rect
        let shape: NodeShape
        var orientation: ShapeOrientation = .up
        switch recognition {
        case .line:
            return nil
        case .rectangle(let r): rect = r; shape = .rectangle
        case .ellipse(let r): rect = r; shape = .ellipse
        case .diamond(let r): rect = r; shape = .diamond
        case .triangle(let r, let apex): rect = r; shape = .triangle; orientation = apex
        }
        let template = elements[0]
        let node = Element(
            layerIDs: template.layerIDs,
            sortKey: template.sortKey,
            content: .node(Node(
                semantic: NodeSemantic(kind: .generic, name: ""),
                frame: Rect(
                    x: rect.x, y: rect.y,
                    width: max(rect.width, minimumNodeSize.width),
                    height: max(rect.height, minimumNodeSize.height)
                ),
                shape: shape,
                orientation: orientation
            ))
        )
        return Conversion(
            operation: .batch(elements.map { .removeElement($0.id) } + [.insertElement(node)]),
            producedID: node.id,
            actionName: "Convert to Block"
        )
    }

    /// Batch conversion for a selection; nil when nothing converts.
    /// Three passes: multi-stroke chains become blocks first (P7), then
    /// remaining closed shapes, then lines attach to them — so a sketched
    /// diagram structurizes correctly regardless of iteration order.
    public static func structurize(
        _ ids: some Sequence<ElementID>, in board: Board
    ) -> Conversion? {
        var operations: [BoardOperation] = []
        var lastProduced: ElementID?
        var workingBoard = board
        let idList = ids.sorted()
        var consumed: Set<ElementID> = []

        // Pass 0 (P7): strokes that join end-to-end into one closed shape.
        let inkElements = idList.compactMap { id -> Element? in
            guard let element = workingBoard.elements[id],
                  case .ink = element.content else { return nil }
            return element
        }
        for component in endpointComponents(inkElements) where component.count >= 2 {
            guard let conversion = chainedConversion(for: component, in: workingBoard) else { continue }
            operations.append(conversion.operation)
            lastProduced = conversion.producedID
            consumed.formUnion(component.map(\.id))
            try? workingBoard.apply(conversion.operation)
        }

        func attempt(_ id: ElementID, linesPass: Bool) {
            guard !consumed.contains(id),
                  let element = workingBoard.elements[id],
                  case .ink(let ink) = element.content,
                  let recognition = StrokeRecognizer.recognize(ink.points) else { return }
            let isLine: Bool = {
                if case .line = recognition { return true }
                return false
            }()
            guard isLine == linesPass,
                  let conversion = conversion(for: element, in: workingBoard) else { return }
            operations.append(conversion.operation)
            lastProduced = conversion.producedID
            try? workingBoard.apply(conversion.operation)
        }

        for id in idList { attempt(id, linesPass: false) }
        for id in idList { attempt(id, linesPass: true) }

        guard let produced = lastProduced else { return nil }
        return Conversion(
            operation: operations.count == 1 ? operations[0] : .batch(operations),
            producedID: produced,
            actionName: "Structurize"
        )
    }

    private static func nearestNode(
        to point: Point, in board: Board, excluding: ElementID
    ) -> ElementID? {
        var best: (id: ElementID, distance: Double)?
        for element in board.elements.values where element.id != excluding {
            guard let node = element.node else { continue }
            let d = distanceToRect(point, node.frame)
            if d <= endpointSnapDistance, d < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (element.id, d)
            }
        }
        return best?.id
    }

    /// 0 when the point is inside the rect.
    static func distanceToRect(_ point: Point, _ rect: Rect) -> Double {
        let dx = max(rect.x - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.y - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
