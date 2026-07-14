import Foundation

/// Grouping (feature 4): elements grouped together select and move as one.
/// `Element.groupID` is the fast lookup; `Board.groups` is the registry —
/// these helpers keep both in sync inside single undoable batches.
extension Board {
    /// One batched operation that groups `ids` (≥ 2 elements). Elements
    /// already in other groups migrate to the new one; groups left empty are
    /// removed. Returns nil when there's nothing sensible to group.
    public func groupOperation(for ids: Set<ElementID>, named name: String? = nil) -> (operation: BoardOperation, groupID: GroupID)? {
        let members = ids.filter { elements[$0] != nil }
        guard members.count >= 2 else { return nil }

        var operations: [BoardOperation] = []
        let newGroup = Group(name: name, memberIDs: Set(members))

        // Migrate members out of any previous groups.
        var affected: [GroupID: Group] = [:]
        for id in members {
            guard let old = elements[id]?.groupID, let group = groups.first(where: { $0.id == old }) else { continue }
            affected[old] = affected[old] ?? group
            affected[old]?.memberIDs.remove(id)
        }
        for (_, reduced) in affected {
            if reduced.memberIDs.count < 2 {
                // A group of one is meaningless: dissolve it entirely.
                for orphan in reduced.memberIDs {
                    if var element = elements[orphan] {
                        element.groupID = nil
                        operations.append(.replaceElement(element))
                    }
                }
                operations.append(.removeGroup(reduced.id))
            } else {
                operations.append(.replaceGroup(reduced))
            }
        }

        operations.append(.insertGroup(newGroup))
        for id in members {
            guard var element = elements[id] else { continue }
            element.groupID = newGroup.id
            operations.append(.replaceElement(element))
        }
        return (.batch(operations), newGroup.id)
    }

    /// One batched operation that dissolves `groupID`.
    public func ungroupOperation(_ groupID: GroupID) -> BoardOperation? {
        guard groups.contains(where: { $0.id == groupID }) else { return nil }
        var operations: [BoardOperation] = []
        for element in elements.values where element.groupID == groupID {
            var freed = element
            freed.groupID = nil
            operations.append(.replaceElement(freed))
        }
        operations.append(.removeGroup(groupID))
        return .batch(operations)
    }

    /// Expands a selection so any touched group is selected whole — the core
    /// "click one member, get the group" behavior.
    public func expandSelectionToGroups(_ ids: Set<ElementID>) -> Set<ElementID> {
        var expanded = ids
        let touchedGroups = Set(ids.compactMap { elements[$0]?.groupID })
        guard !touchedGroups.isEmpty else { return expanded }
        for element in elements.values {
            if let group = element.groupID, touchedGroups.contains(group) {
                expanded.insert(element.id)
            }
        }
        return expanded
    }

    /// The group fully covered by `ids`, if the selection is exactly one
    /// group's membership (drives Ungroup enablement).
    public func exactGroup(of ids: Set<ElementID>) -> GroupID? {
        let groupIDs = Set(ids.compactMap { elements[$0]?.groupID })
        guard groupIDs.count == 1, let candidate = groupIDs.first else { return nil }
        let members = Set(elements.values.filter { $0.groupID == candidate }.map(\.id))
        return members == ids ? candidate : nil
    }
}
