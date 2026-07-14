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
    /// A board rename, shown explicitly so it can't slip through review.
    public var titleChange: FieldChange?

    /// Proposed-side element ids of additions (nodes + edges) — lets the
    /// canvas ghost-render exactly what would appear.
    public var addedElementIDs: Set<ElementID> = []
    /// Current-side element ids of removals — ghost-marked on the canvas.
    public var removedElementIDs: Set<ElementID> = []

    public var isEmpty: Bool {
        addedNodes.isEmpty && removedNodes.isEmpty && changedNodes.isEmpty
            && addedEdges.isEmpty && removedEdges.isEmpty && changedEdges.isEmpty
            && titleChange == nil
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
        if titleChange != nil { parts.append("board renamed") }
        return parts.isEmpty ? "No changes" : parts.joined(separator: " · ")
    }

    /// A multi-line, human-readable breakdown for the review panel.
    public var detail: String {
        var lines: [String] = []
        if let title = titleChange {
            lines.append("~ title  \(title.before) → \(title.after)")
        }
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

        if let before = a.title, let after = b.title, before != after {
            diff.titleChange = .init(id: "title", before: before, after: after)
        }

        // Nodes, keyed by slug id, carrying their source element ids so the
        // canvas can ghost-render additions/removals.
        let aNodes = Dictionary(zip(a.nodes, a.nodeSourceIDs).map { ($0.id, (wire: $0, element: $1)) },
                                uniquingKeysWith: { first, _ in first })
        let bNodes = Dictionary(zip(b.nodes, b.nodeSourceIDs).map { ($0.id, (wire: $0, element: $1)) },
                                uniquingKeysWith: { first, _ in first })

        var addedSlugs = Set(bNodes.keys.filter { aNodes[$0] == nil })
        var removedSlugs = Set(aNodes.keys.filter { bNodes[$0] == nil })

        // Rename detection: a removed+added pair that kept its position, size,
        // kind, and shape is the same block with a new name — collapse it to a
        // single "renamed" change instead of remove+add churn. Fallback: when
        // exactly one block vanished and one appeared with the same kind and
        // shape, treat that as the rename even if it also moved.
        var renames: [String: String] = [:] // old slug → new slug
        var claimed: Set<String> = []
        for old in removedSlugs.sorted() {
            let oldWire = aNodes[old]!.wire
            guard oldWire.at != nil else { continue }
            if let match = addedSlugs.sorted().first(where: { candidate in
                guard !claimed.contains(candidate) else { return false }
                let newWire = bNodes[candidate]!.wire
                // Same footprint AND a related name — footprint alone
                // misfires when auto-layout reuses a vacated slot.
                return newWire.at == oldWire.at && newWire.size == oldWire.size
                    && newWire.kind == oldWire.kind && newWire.shape == oldWire.shape
                    && similarNames(old, candidate)
            }) {
                renames[old] = match
                claimed.insert(match)
            }
        }
        if renames.isEmpty, removedSlugs.count == 1, addedSlugs.count == 1,
           let old = removedSlugs.first, let new = addedSlugs.first,
           aNodes[old]!.wire.kind == bNodes[new]!.wire.kind,
           aNodes[old]!.wire.shape == bNodes[new]!.wire.shape,
           similarNames(old, new) {
            renames[old] = new
        }
        for (old, new) in renames {
            removedSlugs.remove(old)
            addedSlugs.remove(new)
            diff.changedNodes.append(.init(
                id: new,
                before: aNodes[old]!.wire.displayName,
                after: bNodes[new]!.wire.displayName
            ))
        }

        for id in addedSlugs {
            diff.addedNodes.append(bNodes[id]!.wire.displayName)
            diff.addedElementIDs.insert(bNodes[id]!.element)
        }
        for id in removedSlugs {
            diff.removedNodes.append(aNodes[id]!.wire.displayName)
            diff.removedElementIDs.insert(aNodes[id]!.element)
        }
        for id in aNodes.keys where bNodes[id] != nil {
            let before = aNodes[id]!.wire.signature, after = bNodes[id]!.wire.signature
            if before != after {
                diff.changedNodes.append(.init(id: id, before: before, after: after))
            }
        }

        // Edges, keyed by from → to (+ label to separate parallels). Old-side
        // keys are re-written through the rename mapping so a connector whose
        // endpoint was merely renamed doesn't read as removed+added.
        func renamed(_ slug: String) -> String { renames[slug] ?? slug }
        let aEdges = Dictionary(
            zip(a.edges, a.edgeSourceIDs).map { pair -> (String, (wire: WireBoard.WireEdge, element: ElementID)) in
                var wire = pair.0
                wire.from = renamed(wire.from)
                wire.to = renamed(wire.to)
                return (wire.key, (wire: wire, element: pair.1))
            },
            uniquingKeysWith: { first, _ in first }
        )
        let bEdges = Dictionary(zip(b.edges, b.edgeSourceIDs).map { ($0.key, (wire: $0, element: $1)) },
                                uniquingKeysWith: { first, _ in first })
        for (key, entry) in bEdges where aEdges[key] == nil {
            diff.addedEdges.append(entry.wire.display)
            diff.addedElementIDs.insert(entry.element)
        }
        for (key, entry) in aEdges where bEdges[key] == nil {
            diff.removedEdges.append(entry.wire.display)
            diff.removedElementIDs.insert(entry.element)
        }
        for key in aEdges.keys where bEdges[key] != nil {
            let before = aEdges[key]!.wire.signature, after = bEdges[key]!.wire.signature
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

/// Loose rename plausibility for the single-pair fallback: the slugs share a
/// meaningful prefix or one contains the other ("orders-svc" ↔
/// "orders-service"), so an unrelated remove+add isn't misread as a rename.
private func similarNames(_ a: String, _ b: String) -> Bool {
    if a.contains(b) || b.contains(a) { return true }
    let commonPrefix = zip(a, b).prefix { $0 == $1 }.count
    return commonPrefix >= 4
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
