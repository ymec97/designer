import Foundation
import DesignerModel

/// Turns an accepted agent proposal into a single undoable board mutation.
public enum ProposalApply {
    /// One batched operation that replaces the current board's *structured*
    /// elements (blocks, connectors, notes) with `proposed`, remapping every
    /// proposed element onto `targetLayer` (the coarse text format is
    /// single-layer) while preserving proposed element ids. Freehand ink is
    /// left untouched — the agent can't see it in the text format, so it must
    /// not be able to wipe it. Applied through `Board.apply`, this is exactly
    /// one undo step.
    public static func replaceOperation(current: Board, proposed: Board, targetLayer: LayerID) -> BoardOperation {
        var operations: [BoardOperation] = []
        for element in current.elements.values where element.isWireRepresentable {
            operations.append(.removeElement(element.id))
        }
        for element in proposed.elementsInZOrder {
            var remapped = element
            remapped.layerIDs = [targetLayer]
            operations.append(.insertElement(remapped))
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
