import Foundation

/// The single mutation API for board documents (D11). Every change — UI
/// gestures, sketch-recognition conversions, importers, and later agents —
/// goes through `Board.apply(_:)`, which validates the operation and returns
/// its exact inverse. Undo/redo, autosave dirtiness, and future CRDT sync all
/// hang off this one mechanism.
public enum BoardOperation: Equatable, Sendable {
    case insertElement(Element)
    case removeElement(ElementID)
    /// Full-element update; the element's `id` selects the target.
    case replaceElement(Element)
    case setTitle(String)
    case insertLayer(Layer, at: Int)
    case removeLayer(LayerID)
    case replaceLayer(Layer)
    case moveLayer(LayerID, to: Int)
    case insertFlow(Flow, at: Int)
    case removeFlow(FlowID)
    case replaceFlow(Flow)
    case insertGroup(Group)
    case removeGroup(GroupID)
    case replaceGroup(Group)
    /// Set (or clear, with nil) one board-level `extra` entry — board-wide
    /// toggles like the hand-drawn style live there.
    case setExtra(key: String, value: JSONValue?)
    /// Replace the board's entire CONTENT (title, layers, elements, groups,
    /// flows, extra) with another board's — one undo step. Identity (id,
    /// createdAt, schemaVersion) stays; this is what "restore a version"
    /// means (F3).
    case replaceBoard(Board)
    /// Applied in order, inverted in reverse order. Atomic: if any child
    /// fails, the already-applied prefix is rolled back.
    case batch([BoardOperation])

    /// True when applying this changes nothing — an empty batch, or a batch
    /// whose children are all no-ops. Such an op must not register an undo
    /// step (a ⌘Z that consumes a slot but changes nothing reads as broken).
    public var isNoOp: Bool {
        if case .batch(let children) = self {
            return children.allSatisfy(\.isNoOp)
        }
        return false
    }
}

public enum BoardOperationError: Error, LocalizedError, Equatable {
    case elementAlreadyExists(ElementID)
    case elementNotFound(ElementID)
    case layerAlreadyExists(LayerID)
    case layerNotFound(LayerID)
    case layerIndexOutOfRange(Int)
    case cannotRemoveLastLayer
    case layerInUse(LayerID, elementCount: Int)
    case flowAlreadyExists(FlowID)
    case flowNotFound(FlowID)
    case flowIndexOutOfRange(Int)
    case groupAlreadyExists(GroupID)
    case groupNotFound(GroupID)

    public var errorDescription: String? {
        switch self {
        case .elementAlreadyExists(let id): return "An element with id \(id) already exists."
        case .elementNotFound(let id): return "No element with id \(id)."
        case .layerAlreadyExists(let id): return "A layer with id \(id) already exists."
        case .layerNotFound(let id): return "No layer with id \(id)."
        case .layerIndexOutOfRange(let index): return "Layer index \(index) is out of range."
        case .cannotRemoveLastLayer: return "A board must keep at least one layer."
        case .layerInUse(let id, let count):
            return "Layer \(id) still contains \(count) element(s)."
        case .flowAlreadyExists(let id): return "A flow with id \(id) already exists."
        case .flowNotFound(let id): return "No flow with id \(id)."
        case .flowIndexOutOfRange(let index): return "Flow index \(index) is out of range."
        case .groupAlreadyExists(let id): return "A group with id \(id) already exists."
        case .groupNotFound(let id): return "No group with id \(id)."
        }
    }
}

extension Board {
    /// Applies `operation` and returns the operation that undoes it.
    /// On error the board is unchanged (including inside batches).
    @discardableResult
    public mutating func apply(_ operation: BoardOperation) throws -> BoardOperation {
        switch operation {
        case .insertElement(let element):
            guard elements[element.id] == nil else {
                throw BoardOperationError.elementAlreadyExists(element.id)
            }
            elements[element.id] = element
            return .removeElement(element.id)

        case .removeElement(let id):
            guard let existing = elements.removeValue(forKey: id) else {
                throw BoardOperationError.elementNotFound(id)
            }
            return .insertElement(existing)

        case .replaceElement(let element):
            guard let existing = elements[element.id] else {
                throw BoardOperationError.elementNotFound(element.id)
            }
            elements[element.id] = element
            return .replaceElement(existing)

        case .setTitle(let newTitle):
            let oldTitle = title
            title = newTitle
            return .setTitle(oldTitle)

        case .insertLayer(let layer, let index):
            guard !layers.contains(where: { $0.id == layer.id }) else {
                throw BoardOperationError.layerAlreadyExists(layer.id)
            }
            guard (0...layers.count).contains(index) else {
                throw BoardOperationError.layerIndexOutOfRange(index)
            }
            layers.insert(layer, at: index)
            return .removeLayer(layer.id)

        case .removeLayer(let id):
            guard let index = layers.firstIndex(where: { $0.id == id }) else {
                throw BoardOperationError.layerNotFound(id)
            }
            guard layers.count > 1 else {
                throw BoardOperationError.cannotRemoveLastLayer
            }
            let inhabitants = elements.values.filter { $0.layerIDs.contains(id) }
            guard inhabitants.isEmpty else {
                throw BoardOperationError.layerInUse(id, elementCount: inhabitants.count)
            }
            let removed = layers.remove(at: index)
            return .insertLayer(removed, at: index)

        case .replaceLayer(let layer):
            guard let index = layers.firstIndex(where: { $0.id == layer.id }) else {
                throw BoardOperationError.layerNotFound(layer.id)
            }
            let old = layers[index]
            layers[index] = layer
            return .replaceLayer(old)

        case .moveLayer(let id, let index):
            guard let currentIndex = layers.firstIndex(where: { $0.id == id }) else {
                throw BoardOperationError.layerNotFound(id)
            }
            guard (0..<layers.count).contains(index) else {
                throw BoardOperationError.layerIndexOutOfRange(index)
            }
            let layer = layers.remove(at: currentIndex)
            layers.insert(layer, at: index)
            return .moveLayer(id, to: currentIndex)

        case .insertFlow(let flow, let index):
            guard !flows.contains(where: { $0.id == flow.id }) else {
                throw BoardOperationError.flowAlreadyExists(flow.id)
            }
            guard (0...flows.count).contains(index) else {
                throw BoardOperationError.flowIndexOutOfRange(index)
            }
            flows.insert(flow, at: index)
            return .removeFlow(flow.id)

        case .removeFlow(let id):
            guard let index = flows.firstIndex(where: { $0.id == id }) else {
                throw BoardOperationError.flowNotFound(id)
            }
            let removed = flows.remove(at: index)
            return .insertFlow(removed, at: index)

        case .replaceFlow(let flow):
            guard let index = flows.firstIndex(where: { $0.id == flow.id }) else {
                throw BoardOperationError.flowNotFound(flow.id)
            }
            let old = flows[index]
            flows[index] = flow
            return .replaceFlow(old)

        case .insertGroup(let group):
            guard !groups.contains(where: { $0.id == group.id }) else {
                throw BoardOperationError.groupAlreadyExists(group.id)
            }
            groups.append(group)
            return .removeGroup(group.id)

        case .removeGroup(let id):
            guard let index = groups.firstIndex(where: { $0.id == id }) else {
                throw BoardOperationError.groupNotFound(id)
            }
            let removed = groups.remove(at: index)
            return .insertGroup(removed)

        case .replaceGroup(let group):
            guard let index = groups.firstIndex(where: { $0.id == group.id }) else {
                throw BoardOperationError.groupNotFound(group.id)
            }
            let old = groups[index]
            groups[index] = group
            return .replaceGroup(old)

        case .setExtra(let key, let value):
            let old = extra[key]
            if let value {
                extra[key] = value
            } else {
                extra.removeValue(forKey: key)
            }
            return .setExtra(key: key, value: old)

        case .replaceBoard(let replacement):
            // Only CONTENT moves; identity (id, createdAt, schemaVersion)
            // stays ours, so restoring a version never re-identifies the doc.
            let previous = self
            title = replacement.title
            layers = replacement.layers
            elements = replacement.elements
            groups = replacement.groups
            flows = replacement.flows
            extra = replacement.extra
            return .replaceBoard(previous)

        case .batch(let operations):
            var inverses: [BoardOperation] = []
            inverses.reserveCapacity(operations.count)
            do {
                for operation in operations {
                    inverses.append(try apply(operation))
                }
            } catch {
                // Roll back the applied prefix so the batch is atomic.
                for inverse in inverses.reversed() {
                    try? apply(inverse)
                }
                throw error
            }
            return .batch(inverses.reversed())
        }
    }
}
