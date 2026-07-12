import Foundation

/// Batch builders for the layer commands the panel exposes (D9). Each returns
/// operations forming one undo step; apply via `.batch(...)`.
extension Board {
    /// Duplicating a layer creates a sibling *view*: the same elements gain
    /// membership in the copy (elements exist once — layers are concerns,
    /// not containers).
    public func duplicateLayerOperations(_ id: LayerID) -> [BoardOperation]? {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return nil }
        let source = layers[index]
        var copy = Layer(
            name: source.name + " Copy",
            colorTint: source.colorTint,
            isVisible: source.isVisible,
            isLocked: false
        )
        copy.extra = source.extra

        var operations: [BoardOperation] = [.insertLayer(copy, at: index + 1)]
        for var element in elements.values where element.layerIDs.contains(id) {
            element.layerIDs.insert(copy.id)
            operations.append(.replaceElement(element))
        }
        return operations
    }

    /// Deleting a layer strips membership from its elements; elements that
    /// would end up layerless migrate to `fallback` (or the first remaining
    /// layer) so nothing silently disappears. Fails (returns nil) only when
    /// it is the last layer.
    public func deleteLayerOperations(
        _ id: LayerID, migratingSoleMembersTo fallback: LayerID? = nil
    ) -> [BoardOperation]? {
        guard layers.count > 1, layers.contains(where: { $0.id == id }) else { return nil }
        let target = fallback ?? layers.first(where: { $0.id != id })?.id
        guard let target, target != id, layers.contains(where: { $0.id == target }) else { return nil }

        var operations: [BoardOperation] = []
        for var element in elements.values where element.layerIDs.contains(id) {
            element.layerIDs.remove(id)
            if element.layerIDs.isEmpty {
                element.layerIDs = [target]
            }
            operations.append(.replaceElement(element))
        }
        operations.append(.removeLayer(id))
        return operations
    }

    /// Adds the given elements to a layer (multi-membership assign).
    public func assignOperations(_ ids: Set<ElementID>, toLayer layerID: LayerID) -> [BoardOperation] {
        guard layers.contains(where: { $0.id == layerID }) else { return [] }
        var operations: [BoardOperation] = []
        for id in ids.sorted() {
            guard var element = elements[id], !element.layerIDs.contains(layerID) else { continue }
            element.layerIDs.insert(layerID)
            operations.append(.replaceElement(element))
        }
        return operations
    }

    /// Removes elements from a layer, unless it is their only layer.
    public func unassignOperations(_ ids: Set<ElementID>, fromLayer layerID: LayerID) -> [BoardOperation] {
        var operations: [BoardOperation] = []
        for id in ids.sorted() {
            guard var element = elements[id],
                  element.layerIDs.contains(layerID),
                  element.layerIDs.count > 1 else { continue }
            element.layerIDs.remove(layerID)
            operations.append(.replaceElement(element))
        }
        return operations
    }

    public func elementCount(onLayer id: LayerID) -> Int {
        elements.values.lazy.filter { $0.layerIDs.contains(id) }.count
    }
}
