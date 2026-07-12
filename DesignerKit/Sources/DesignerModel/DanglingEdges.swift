import Foundation

/// Dangling-connector policy: deleting a node keeps its connectors. The
/// affected anchors become free points pinned at their last resolved
/// position; a dangling edge renders in a warning style until a new node
/// appears near the free endpoint, at which point it snaps back in.
extension Board {
    /// True when either endpoint is unattached — the "visibly invalid" state.
    public func isDangling(_ edge: Edge) -> Bool {
        func dangling(_ anchor: Anchor) -> Bool {
            switch anchor {
            case .free: return true
            case .element(let id, _, _): return elements[id] == nil
            }
        }
        return dangling(edge.from) || dangling(edge.to)
    }

    /// Operations that delete `ids` while detaching (not deleting) their
    /// connectors: each affected anchor is replaced by a free point at its
    /// current resolved location. Order matters — detachments are emitted
    /// before removals so anchor resolution still sees the node frames.
    public func deleteDetachingEdges(_ ids: Set<ElementID>) -> [BoardOperation] {
        let frames = frameProvider()
        var operations: [BoardOperation] = []

        for element in elements.values {
            guard var edge = element.edge else { continue }
            // Edges being deleted themselves don't need detaching.
            guard !ids.contains(element.id) else { continue }

            var changed = false
            func detached(_ anchor: Anchor, toward other: Anchor) -> Anchor {
                guard let anchorID = anchor.elementID, ids.contains(anchorID) else { return anchor }
                changed = true
                let resolved = EdgeGeometry.resolve(anchor, toward: other, frames: frames)
                return .free(resolved?.point ?? Point.zero)
            }
            let newFrom = detached(edge.from, toward: edge.to)
            let newTo = detached(edge.to, toward: edge.from)
            if changed {
                edge.from = newFrom
                edge.to = newTo
                var updated = element
                updated.content = .edge(edge)
                operations.append(.replaceElement(updated))
            }
        }

        operations.append(contentsOf: ids.compactMap { id in
            elements[id] != nil ? .removeElement(id) : nil
        })
        return operations
    }

    /// Reattachment operations for a newly placed node: any dangling free
    /// endpoint within `snapDistance` of (or inside) the node's frame snaps
    /// onto it.
    public func reattachmentOperations(
        forNodeID nodeID: ElementID,
        frame: Rect,
        snapDistance: Double = 28
    ) -> [BoardOperation] {
        var operations: [BoardOperation] = []
        for element in elements.values {
            guard var edge = element.edge else { continue }
            var changed = false

            func snapped(_ anchor: Anchor, otherEnd: Anchor) -> Anchor {
                guard case .free(let point) = anchor else { return anchor }
                // Don't create a self-loop by snapping both ends to one node.
                guard otherEnd.elementID != nodeID else { return anchor }
                let dx = max(frame.x - point.x, 0, point.x - frame.maxX)
                let dy = max(frame.y - point.y, 0, point.y - frame.maxY)
                guard (dx * dx + dy * dy).squareRoot() <= snapDistance else { return anchor }
                changed = true
                return .element(nodeID, side: nil, offset: nil)
            }

            edge.from = snapped(edge.from, otherEnd: edge.to)
            edge.to = snapped(edge.to, otherEnd: edge.from)
            if changed {
                var updated = element
                updated.content = .edge(edge)
                operations.append(.replaceElement(updated))
            }
        }
        return operations
    }

    /// Expands an operation so that any node it inserts also snaps nearby
    /// dangling endpoints onto itself, as part of the same undo step.
    public func expandingWithReattachments(_ operation: BoardOperation) -> BoardOperation {
        var insertedNodes: [(ElementID, Rect)] = []
        func collect(_ operation: BoardOperation) {
            switch operation {
            case .insertElement(let element):
                if let node = element.node { insertedNodes.append((element.id, node.frame)) }
            case .batch(let children):
                children.forEach(collect)
            default:
                break
            }
        }
        collect(operation)
        guard !insertedNodes.isEmpty else { return operation }

        var fixes: [BoardOperation] = []
        for (id, frame) in insertedNodes {
            fixes.append(contentsOf: reattachmentOperations(forNodeID: id, frame: frame))
        }
        guard !fixes.isEmpty else { return operation }
        return .batch([operation] + fixes)
    }
}
