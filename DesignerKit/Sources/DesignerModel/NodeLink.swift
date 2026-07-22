import Foundation

/// Node → board linking (drill-down): a node can reference another board
/// that describes it in more detail. The reference lives in the node's
/// tolerant `extra` bag, so it:
///   - persists in board.json with no schema change,
///   - survives file moves (it's the target's stable BoardID, not a path),
///   - is invisible to the agent wire format (agents can't wipe or forge it).
public extension NodeSemantic {
    static let linkedBoardKey = "linkedBoard"

    /// The board this node drills down into, if any.
    var linkedBoardID: BoardID? {
        get {
            guard case .string(let raw)? = extra[Self.linkedBoardKey],
                  let uuid = UUID(uuidString: raw) else { return nil }
            return BoardID(uuid)
        }
        set {
            if let newValue {
                extra[Self.linkedBoardKey] = .string(newValue.rawValue.uuidString)
            } else {
                extra.removeValue(forKey: Self.linkedBoardKey)
            }
        }
    }
}
