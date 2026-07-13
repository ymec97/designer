import Foundation
import DesignerModel

/// A structural difference between two boards, computed on the name-addressed
/// wire representation (so it survives the fresh-IDs round-trip of an LLM edit).
/// This is what the agent-proposal review shows before anything touches the
/// real document.
public struct BoardDiff: Equatable, Sendable {
    public struct FieldChange: Equatable, Sendable {
        public let id: String        // node slug, or "from → to" for an edge
        public let before: String
        public let after: String
    }

    public init() {}

    public var addedNodes: [String] = []       // display names / ids
    public var removedNodes: [String] = []
    public var changedNodes: [FieldChange] = []
    public var addedEdges: [String] = []       // "from → to (label)"
    public var removedEdges: [String] = []
    public var changedEdges: [FieldChange] = []

    public var isEmpty: Bool {
        addedNodes.isEmpty && removedNodes.isEmpty && changedNodes.isEmpty
            && addedEdges.isEmpty && removedEdges.isEmpty && changedEdges.isEmpty
    }

    /// A single-line headline for the proposal banner, e.g.
    /// "+2 blocks · 1 renamed · −1 connector".
    public var summaryLine: String {
        var parts: [String] = []
        func add(_ n: Int, _ singular: String, _ plural: String, sign: String) {
            guard n > 0 else { return }
            parts.append("\(sign)\(n) \(n == 1 ? singular : plural)")
        }
        add(addedNodes.count, "block", "blocks", sign: "+")
        add(removedNodes.count, "block", "blocks", sign: "−")
        add(changedNodes.count, "block changed", "blocks changed", sign: "~")
        add(addedEdges.count, "connector", "connectors", sign: "+")
        add(removedEdges.count, "connector", "connectors", sign: "−")
        add(changedEdges.count, "connector changed", "connectors changed", sign: "~")
        return parts.isEmpty ? "No changes" : parts.joined(separator: " · ")
    }

    /// A multi-line, human-readable breakdown for the review panel.
    public var detail: String {
        var lines: [String] = []
        for n in addedNodes { lines.append("+ block  \(n)") }
        for n in removedNodes { lines.append("− block  \(n)") }
        for c in changedNodes { lines.append("~ block  \(c.id): \(c.before) → \(c.after)") }
        for e in addedEdges { lines.append("+ edge   \(e)") }
        for e in removedEdges { lines.append("− edge   \(e)") }
        for c in changedEdges { lines.append("~ edge   \(c.id): \(c.before) → \(c.after)") }
        return lines.isEmpty ? "No changes." : lines.joined(separator: "\n")
    }
}

extension LLMInterchange {
    /// Diff `proposed` against `current` on the wire representation. Nodes are
    /// keyed by their slug id, edges by `from → to (label)`.
    public static func diff(current: Board, proposed: Board) -> BoardDiff {
        let a = WireBoard(from: current)
        let b = WireBoard(from: proposed)
        var diff = BoardDiff()

        // Nodes, keyed by slug id.
        let aNodes = Dictionary(a.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let bNodes = Dictionary(b.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in bNodes.keys where aNodes[id] == nil {
            diff.addedNodes.append(bNodes[id]!.displayName)
        }
        for id in aNodes.keys where bNodes[id] == nil {
            diff.removedNodes.append(aNodes[id]!.displayName)
        }
        for id in aNodes.keys where bNodes[id] != nil {
            let before = aNodes[id]!.signature, after = bNodes[id]!.signature
            if before != after {
                diff.changedNodes.append(.init(id: id, before: before, after: after))
            }
        }

        // Edges, keyed by from → to (+ label to separate parallels).
        let aEdges = Dictionary(a.edges.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let bEdges = Dictionary(b.edges.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for key in bEdges.keys where aEdges[key] == nil {
            diff.addedEdges.append(bEdges[key]!.display)
        }
        for key in aEdges.keys where bEdges[key] == nil {
            diff.removedEdges.append(aEdges[key]!.display)
        }
        for key in aEdges.keys where bEdges[key] != nil {
            let before = aEdges[key]!.signature, after = bEdges[key]!.signature
            if before != after {
                diff.changedEdges.append(.init(id: key, before: before, after: after))
            }
        }

        diff.addedNodes.sort(); diff.removedNodes.sort()
        diff.addedEdges.sort(); diff.removedEdges.sort()
        diff.changedNodes.sort { $0.id < $1.id }; diff.changedEdges.sort { $0.id < $1.id }
        return diff
    }
}

private extension WireBoard.WireNode {
    var displayName: String { name ?? id }
    /// Fields that, when changed, count as a modified node (position excluded —
    /// a move alone isn't a structural change worth flagging).
    var signature: String {
        "\(name ?? "")|\(kind ?? "generic")|\(shape ?? "rectangle")|\(orientation ?? "up")"
    }
}

private extension WireBoard.WireEdge {
    var key: String { "\(from)→\(to)|\(label ?? "")" }
    var display: String {
        let l = (label?.isEmpty == false) ? " (\(label!))" : ""
        return "\(from) → \(to)\(l)"
    }
    var signature: String {
        "\(direction ?? "forward")|\(`protocol` ?? "")|\(data ?? "")|\(condition ?? "")"
    }
}
