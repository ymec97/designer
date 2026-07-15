import Foundation
import DesignerModel

/// Turns an accepted agent proposal into a single undoable board mutation.
public enum ProposalApply {
    /// One batched operation that replaces the current board's *structured*
    /// content with `proposed`:
    /// - elements (blocks, connectors, notes) are swapped wholesale, keeping
    ///   the proposed element ids;
    /// - layers are matched BY NAME - missing ones are created (with the
    ///   proposed tint/visibility), existing ones are never deleted or
    ///   restyled, and element membership maps through the name match;
    /// - flows are replaced by the proposed board's flows (they reference the
    ///   proposed element ids being inserted).
    /// Freehand ink and boundaries are left untouched - the agent can't see
    /// them in the text format, so it must not be able to wipe them.
    /// Applied through `Board.apply`, this is exactly one undo step.
    public static func replaceOperation(current: Board, proposed: Board) -> BoardOperation {
        var operations: [BoardOperation] = []

        // Layers by name. The current base layer absorbs the proposed base.
        var layerIDForProposed: [LayerID: LayerID] = [:]
        var insertionIndex = current.layers.count
        for (index, proposedLayer) in proposed.layers.enumerated() {
            if let existing = current.layers.first(where: { $0.name == proposedLayer.name }) {
                layerIDForProposed[proposedLayer.id] = existing.id
            } else if index == 0 {
                // A renamed base layer maps onto the current base rather than
                // spawning a parallel "default" layer.
                layerIDForProposed[proposedLayer.id] = current.layers[0].id
            } else {
                // Proposed layers land VISIBLE regardless of the wire's
                // `hidden` flag: the user must SEE what they accepted. The
                // agent stages reveals afterwards via set_layer_visibility.
                var newLayer = proposedLayer
                newLayer.isVisible = true
                operations.append(.insertLayer(newLayer, at: insertionIndex))
                insertionIndex += 1
                layerIDForProposed[proposedLayer.id] = proposedLayer.id
            }
        }
        let fallbackLayer = current.layers[0].id

        for flow in current.flows {
            operations.append(.removeFlow(flow.id))
        }
        for element in current.elements.values where element.isWireRepresentable {
            operations.append(.removeElement(element.id))
        }
        for element in proposed.elementsInZOrder {
            var remapped = element
            let mapped = Set(element.layerIDs.compactMap { layerIDForProposed[$0] })
            remapped.layerIDs = mapped.isEmpty ? [fallbackLayer] : mapped
            operations.append(.insertElement(remapped))
        }
        for (index, flow) in proposed.flows.enumerated() {
            operations.append(.insertFlow(flow, at: index))
        }
        if proposed.title != current.title, !proposed.title.isEmpty {
            operations.append(.setTitle(proposed.title))
        }
        return .batch(operations)
    }
}

private extension Element {
    /// True for the element kinds the LLM text format round-trips (blocks,
    /// connectors, notes). Ink is not representable there and is preserved
    /// across an agent proposal.
    var isWireRepresentable: Bool {
        switch content {
        case .node, .edge, .note: return true
        case .ink, .boundary: return false // preserved across agent proposals
        }
    }
}
