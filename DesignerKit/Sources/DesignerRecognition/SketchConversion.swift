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

            // A stroke opposing an existing connection upgrades it to
            // bidirectional; a same-direction repeat is absorbed (the stroke
            // vanishes, nothing duplicates or changes direction).
            switch board.connectionMergeOutcome(from: fromNode, to: toNode) {
            case .alreadyConnected(let existing):
                return Conversion(
                    operation: .removeElement(element.id),
                    producedID: existing,
                    actionName: "Convert to Connector"
                )
            case .oppositeDirection(let existing):
                guard let upgrade = board.makeBidirectionalOperation(existing) else { return nil }
                return Conversion(
                    operation: .batch([.removeElement(element.id), upgrade]),
                    producedID: existing,
                    actionName: "Make Bidirectional"
                )
            case .none:
                break
            }

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


    /// Batch conversion for a selection; nil when nothing converts.
    /// Two passes: closed shapes become blocks first, then lines attach to
    /// them — so a sketched diagram (boxes + connecting strokes) structurizes
    /// correctly regardless of iteration order.
    public static func structurize(
        _ ids: some Sequence<ElementID>, in board: Board
    ) -> Conversion? {
        var operations: [BoardOperation] = []
        var lastProduced: ElementID?
        var workingBoard = board
        let idList = ids.sorted()

        func attempt(_ id: ElementID, linesPass: Bool) {
            guard let element = workingBoard.elements[id],
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
