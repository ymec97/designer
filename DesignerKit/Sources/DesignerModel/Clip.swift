import Foundation

/// Reusable-library plumbing at the model level (D10): extracting a selection
/// into a standalone clip, and instantiating a clip into a board with fresh
/// identity. A clip is just a `Board` — a whole-board archive is the board
/// itself; a selection archive is a mini-board.
extension Board {
    /// A standalone board containing copies of `ids`, flattened onto a single
    /// layer. Edges are kept; an endpoint anchored to an element outside the
    /// selection becomes a free point at its current resolved position, so
    /// the clip is self-contained.
    public func makeClip(of ids: Set<ElementID>, title: String = "Clip") -> Board {
        var clip = Board(title: title)
        let clipLayer = clip.layers[0].id
        let frames = frameProvider()

        func clamp(_ anchor: Anchor, toward other: Anchor) -> Anchor {
            guard let id = anchor.elementID else { return anchor }
            if ids.contains(id) { return anchor }
            let resolved = EdgeGeometry.resolve(anchor, toward: other, frames: frames)
            return .free(resolved?.point ?? .zero)
        }

        for element in elementsInZOrder where ids.contains(element.id) {
            var copy = element
            copy.layerIDs = [clipLayer]
            copy.groupID = nil
            if case .edge(var edge) = copy.content {
                edge.from = clamp(edge.from, toward: edge.to)
                edge.to = clamp(edge.to, toward: edge.from)
                copy.content = .edge(edge)
            }
            clip.elements[copy.id] = copy
        }
        return clip
    }

    /// The clip's bounding rect in its own coordinate space (for centering on
    /// a drop point). Nil when the clip has no positioned geometry.
    public func contentBounds() -> Rect? {
        var union: Rect?
        let frames = frameProvider()
        for element in elements.values {
            let rect: Rect?
            if let edge = element.edge {
                rect = EdgeGeometry.route(for: edge, frames: frames)?.boundingRect
            } else {
                rect = SpatialIndex.boundingRect(of: element)
            }
            guard let rect else { continue }
            if let current = union {
                let minX = min(current.x, rect.x), minY = min(current.y, rect.y)
                let maxX = max(current.maxX, rect.maxX), maxY = max(current.maxY, rect.maxY)
                union = Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            } else {
                union = rect
            }
        }
        return union
    }

    /// Operations inserting a copy of `clip` into this board: fresh element
    /// IDs, edge anchors remapped to the new IDs, geometry offset by
    /// `(dx, dy)`, everything placed on `layerID` above existing content.
    /// Returns the operations and the new element IDs (for selection).
    public func instantiateOperations(
        from clip: Board, offsetBy dx: Double, _ dy: Double, onto layerID: LayerID
    ) -> (operations: [BoardOperation], newIDs: Set<ElementID>) {
        var idMap: [ElementID: ElementID] = [:]
        for id in clip.elements.keys { idMap[id] = ElementID() }

        var operations: [BoardOperation] = []
        var sortKey = topSortKey
        for element in clip.elementsInZOrder {
            var copy = element
            copy.id = idMap[element.id] ?? ElementID()
            copy.layerIDs = [layerID]
            copy.groupID = nil
            copy.sortKey = sortKey
            sortKey = SortKey.after(sortKey)
            copy.content = Self.offsetAndRemap(element.content, dx: dx, dy: dy, idMap: idMap)
            operations.append(.insertElement(copy))
        }
        return (operations, Set(idMap.values))
    }

    private static func offsetAndRemap(
        _ content: Element.Content, dx: Double, dy: Double, idMap: [ElementID: ElementID]
    ) -> Element.Content {
        func offset(_ rect: Rect) -> Rect {
            Rect(x: rect.x + dx, y: rect.y + dy, width: rect.width, height: rect.height)
        }
        func remap(_ anchor: Anchor) -> Anchor {
            switch anchor {
            case .free(let point):
                return .free(Point(x: point.x + dx, y: point.y + dy))
            case .element(let id, let side, let anchorOffset):
                return .element(idMap[id] ?? id, side: side, offset: anchorOffset)
            }
        }
        switch content {
        case .node(var node):
            node.frame = offset(node.frame)
            return .node(node)
        case .note(var note):
            note.frame = offset(note.frame)
            return .note(note)
        case .ink(var ink):
            ink.points = ink.points.map {
                StrokePoint(x: $0.x + dx, y: $0.y + dy, pressure: $0.pressure, time: $0.time)
            }
            return .ink(ink)
        case .edge(var edge):
            edge.from = remap(edge.from)
            edge.to = remap(edge.to)
            edge.waypoints = edge.waypoints.map { Point(x: $0.x + dx, y: $0.y + dy) }
            return .edge(edge)
        }
    }
}
