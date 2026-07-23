import Foundation

public struct FlowCompositionID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible, ExpressibleByStringLiteral {
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

    public static func < (lhs: FlowCompositionID, rhs: FlowCompositionID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

/// A composition organizes recorded flows into a hierarchy that plays some
/// groups **serially** and some **in parallel** — the "flow studio" concept.
/// The root is itself a group (its `mode`); `children` are flows or nested
/// groups. Only `FlowID`s are references (a flow may appear in several
/// compositions); nested groups are embedded inline, so cycles are impossible
/// and any structural edit is a single `.replaceComposition` op.
///
/// Compositions never cross the agent wire — they're a pure authoring surface.
public struct FlowComposition: Identifiable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case serial, parallel
    }

    /// A node in the composition tree: either a recorded flow (by id) or a
    /// nested group with its own play mode.
    public indirect enum Child: Equatable, Sendable {
        case flow(FlowID)
        case group(mode: Mode, children: [Child])
    }

    public var id: FlowCompositionID
    public var name: String
    /// Play mode of the root group.
    public var mode: Mode
    public var children: [Child]

    public init(
        id: FlowCompositionID = FlowCompositionID(),
        name: String,
        mode: Mode = .serial,
        children: [Child] = []
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.children = children
    }

    /// Every flow the composition references, in tree order (a flow may repeat
    /// if added more than once).
    public var memberFlowIDs: [FlowID] {
        var out: [FlowID] = []
        func walk(_ children: [Child]) {
            for child in children {
                switch child {
                case .flow(let id): out.append(id)
                case .group(_, let nested): walk(nested)
                }
            }
        }
        walk(children)
        return out
    }

    /// True when any referenced flow is missing from the board or has itself
    /// gone stale (a recorded element was deleted).
    public func isStale(in board: Board) -> Bool {
        let byID = Dictionary(board.flows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return memberFlowIDs.contains { id in
            guard let flow = byID[id] else { return true }
            return flow.isStale(in: board)
        }
    }

    // MARK: Tree editing

    /// The child at `path` (each index selects into the children array at that
    /// depth). An empty path addresses the root group, which is not a `Child`
    /// and returns nil.
    public func child(at path: [Int]) -> Child? {
        guard !path.isEmpty else { return nil }
        var children = self.children
        for (depth, index) in path.enumerated() {
            guard children.indices.contains(index) else { return nil }
            let child = children[index]
            if depth == path.count - 1 { return child }
            guard case .group(_, let nested) = child else { return nil }
            children = nested
        }
        return nil
    }

    /// Mutate the children array of the group addressed by `groupPath` (empty =
    /// the root group; otherwise the path must land on a `.group` child).
    /// Returns true if the group was found and the transform applied.
    @discardableResult
    public mutating func updateChildren(
        atGroupPath groupPath: [Int],
        _ transform: (inout [Child]) -> Void
    ) -> Bool {
        Self.update(&children, groupPath: groupPath[...], transform)
    }

    private static func update(
        _ children: inout [Child],
        groupPath: ArraySlice<Int>,
        _ transform: (inout [Child]) -> Void
    ) -> Bool {
        guard let index = groupPath.first else {
            transform(&children)
            return true
        }
        guard children.indices.contains(index),
              case .group(let mode, var nested) = children[index] else { return false }
        let ok = update(&nested, groupPath: groupPath.dropFirst(), transform)
        if ok { children[index] = .group(mode: mode, children: nested) }
        return ok
    }

    /// Append a child to the group at `groupPath` (empty = root).
    public mutating func appendChild(_ child: Child, toGroupAt groupPath: [Int]) {
        updateChildren(atGroupPath: groupPath) { $0.append(child) }
    }

    /// Remove the child at `path` (path must be non-empty).
    public mutating func removeChild(at path: [Int]) {
        guard let last = path.last else { return }
        updateChildren(atGroupPath: Array(path.dropLast())) { children in
            guard children.indices.contains(last) else { return }
            children.remove(at: last)
        }
    }

    /// Move the child at `path` up or down among its siblings.
    public mutating func moveChild(at path: [Int], up: Bool) {
        guard let last = path.last else { return }
        updateChildren(atGroupPath: Array(path.dropLast())) { children in
            let target = up ? last - 1 : last + 1
            guard children.indices.contains(last), children.indices.contains(target) else { return }
            children.swapAt(last, target)
        }
    }

    /// Toggle serial↔parallel for the group at `groupPath` (empty = the root,
    /// which flips `mode`; otherwise the path must land on a `.group` child).
    public mutating func toggleMode(atGroupPath groupPath: [Int]) {
        if groupPath.isEmpty {
            mode = (mode == .serial) ? .parallel : .serial
            return
        }
        let last = groupPath[groupPath.count - 1]
        updateChildren(atGroupPath: Array(groupPath.dropLast())) { children in
            guard children.indices.contains(last),
                  case .group(let mode, let nested) = children[last] else { return }
            children[last] = .group(mode: mode == .serial ? .parallel : .serial, children: nested)
        }
    }
}

// MARK: - Codable

extension FlowComposition: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, mode, children
    }
}

extension FlowComposition.Child: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, id, mode, children
    }
    private enum Kind: String, Codable {
        case flow, group
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown `kind` throws (Kind is a closed String enum) rather than
        // silently dropping a child.
        switch try container.decode(Kind.self, forKey: .kind) {
        case .flow:
            self = .flow(try container.decode(FlowID.self, forKey: .id))
        case .group:
            self = .group(
                mode: try container.decode(FlowComposition.Mode.self, forKey: .mode),
                children: try container.decode([FlowComposition.Child].self, forKey: .children)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .flow(let id):
            try container.encode(Kind.flow, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .group(let mode, let children):
            try container.encode(Kind.group, forKey: .kind)
            try container.encode(mode, forKey: .mode)
            try container.encode(children, forKey: .children)
        }
    }
}
