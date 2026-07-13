import Foundation

public struct FlowID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init() { rawValue = UUID().uuidString.lowercased() }
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: FlowID, rhs: FlowID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

/// A recorded traffic journey (F5): a named, ordered chain of specific
/// connectors. Unlike the flood simulation (BFS from a source), a flow
/// expresses *correlation* — "when A sends gRPC to B, B sends gRPC to C" —
/// by naming exactly which edge fires at each step, even when parallel
/// connectors exist between the same nodes.
public struct Flow: Identifiable, Equatable, Sendable {
    /// One playback step: the connectors that fire together and the nodes
    /// they deliver to (same shape the simulator animates).
    public struct Step: Equatable, Sendable, Codable {
        public var edges: [ElementID]
        public var nodes: [ElementID]
        public init(edges: [ElementID], nodes: [ElementID]) {
            self.edges = edges
            self.nodes = nodes
        }
    }

    public var id: FlowID
    public var name: String
    /// The node the journey starts at.
    public var source: ElementID
    public var steps: [Step]
    /// Index into the app's flow color palette (stable across sessions).
    public var colorIndex: Int

    public init(
        id: FlowID = FlowID(),
        name: String,
        source: ElementID,
        steps: [Step],
        colorIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.steps = steps
        self.colorIndex = colorIndex
    }

    /// Every element the flow touches (source + reached nodes + edges) — used
    /// for the "dim everything else" focus view.
    public var memberElements: Set<ElementID> {
        var members: Set<ElementID> = [source]
        for step in steps {
            members.formUnion(step.edges)
            members.formUnion(step.nodes)
        }
        return members
    }

    /// Steps restricted to elements that still exist on `board` — a flow
    /// tolerates connectors deleted after recording (stale hops are skipped;
    /// empty steps drop out).
    public func liveSteps(in board: Board) -> [Step] {
        steps.compactMap { step in
            let edges = step.edges.filter { board.elements[$0]?.edge != nil }
            let nodes = step.nodes.filter { board.elements[$0]?.node != nil }
            guard !edges.isEmpty else { return nil }
            return Step(edges: edges, nodes: nodes)
        }
    }

    /// True when recorded elements have since been deleted from `board`.
    public func isStale(in board: Board) -> Bool {
        steps.contains { step in
            step.edges.contains { board.elements[$0]?.edge == nil }
                || step.nodes.contains { board.elements[$0]?.node == nil }
        } || board.elements[source]?.node == nil
    }
}

extension Flow: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, source, steps, colorIndex
    }
}
