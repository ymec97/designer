import Foundation

// MARK: - Anchor

/// Where a connector endpoint lives: attached to an element (it follows the
/// element when it moves/resizes) or floating at a fixed point.
public enum Anchor: Equatable, Sendable {
    /// `side` nil means "auto": the renderer picks the best side dynamically.
    /// `offset` is a normalized 0...1 position along the chosen side.
    case element(ElementID, side: Side?, offset: Double?)
    case free(Point)

    public struct Side: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }

        public static let top: Side = "top"
        public static let right: Side = "right"
        public static let bottom: Side = "bottom"
        public static let left: Side = "left"
    }

    public var elementID: ElementID? {
        if case .element(let id, _, _) = self { return id }
        return nil
    }
}

extension Anchor: Codable {
    enum CodingKeys: String, CodingKey {
        case type, elementId, side, offset, x, y
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "element":
            self = .element(
                try container.decode(ElementID.self, forKey: .elementId),
                side: try container.decodeIfPresent(Side.self, forKey: .side),
                offset: try container.decodeIfPresent(Double.self, forKey: .offset)
            )
        case "free":
            self = .free(Point(
                x: try container.decode(Double.self, forKey: .x),
                y: try container.decode(Double.self, forKey: .y)
            ))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown anchor type '\(type)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .element(let id, let side, let offset):
            try container.encode("element", forKey: .type)
            try container.encode(id, forKey: .elementId)
            try container.encodeIfPresent(side, forKey: .side)
            try container.encodeIfPresent(offset, forKey: .offset)
        case .free(let point):
            try container.encode("free", forKey: .type)
            try container.encode(point.x, forKey: .x)
            try container.encode(point.y, forKey: .y)
        }
    }
}

// MARK: - Node

public struct NodeSemantic: Equatable, Sendable {
    public var kind: NodeKind
    public var name: String
    public var tags: [String]
    public var properties: [String: String]
    public var extra: [String: JSONValue]

    public init(
        kind: NodeKind = .generic,
        name: String = "",
        tags: [String] = [],
        properties: [String: String] = [:],
        extra: [String: JSONValue] = [:]
    ) {
        self.kind = kind
        self.name = name
        self.tags = tags
        self.properties = properties
        self.extra = extra
    }
}

extension NodeSemantic: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, name, tags, properties
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(NodeKind.self, forKey: .kind) ?? .generic
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        properties = try container.decodeIfPresent([String: String].self, forKey: .properties) ?? [:]
        extra = try decoder.unknownFields(excluding: CodingKeys.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        if !tags.isEmpty { try container.encode(tags, forKey: .tags) }
        if !properties.isEmpty { try container.encode(properties, forKey: .properties) }
        try encoder.encodeUnknownFields(extra)
    }
}

public struct Node: Equatable, Sendable, Codable {
    public var semantic: NodeSemantic
    public var frame: Rect
    public var shape: NodeShape
    /// Apex direction for shapes that have one (triangles); default up.
    public var orientation: ShapeOrientation
    public var style: Style

    public init(
        semantic: NodeSemantic = NodeSemantic(),
        frame: Rect,
        shape: NodeShape = .rectangle,
        orientation: ShapeOrientation = .up,
        style: Style = Style()
    ) {
        self.semantic = semantic
        self.frame = frame
        self.shape = shape
        self.orientation = orientation
        self.style = style
    }
}

// MARK: - Edge

public struct EdgeSemantic: Equatable, Sendable {
    public var label: String?
    public var direction: EdgeDirection
    /// Free-form key/values; see `WellKnownEdgeProperty` for keys the UI understands.
    public var properties: [String: String]
    public var extra: [String: JSONValue]

    public init(
        label: String? = nil,
        direction: EdgeDirection = .forward,
        properties: [String: String] = [:],
        extra: [String: JSONValue] = [:]
    ) {
        self.label = label
        self.direction = direction
        self.properties = properties
        self.extra = extra
    }
}

extension EdgeSemantic: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case label, direction, properties
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        direction = try container.decodeIfPresent(EdgeDirection.self, forKey: .direction) ?? .forward
        properties = try container.decodeIfPresent([String: String].self, forKey: .properties) ?? [:]
        extra = try decoder.unknownFields(excluding: CodingKeys.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encode(direction, forKey: .direction)
        if !properties.isEmpty { try container.encode(properties, forKey: .properties) }
        try encoder.encodeUnknownFields(extra)
    }
}

public struct Edge: Equatable, Sendable, Codable {
    public var semantic: EdgeSemantic
    public var from: Anchor
    public var to: Anchor
    public var routing: RoutingMode
    public var waypoints: [Point]
    public var style: Style

    public init(
        semantic: EdgeSemantic = EdgeSemantic(),
        from: Anchor,
        to: Anchor,
        routing: RoutingMode = .straight,
        waypoints: [Point] = [],
        style: Style = Style()
    ) {
        self.semantic = semantic
        self.from = from
        self.to = to
        self.routing = routing
        self.waypoints = waypoints
        self.style = style
    }
}

// MARK: - Ink & Note

public struct Ink: Equatable, Sendable, Codable {
    public var points: [StrokePoint]
    public var style: Style

    public init(points: [StrokePoint], style: Style = Style()) {
        self.points = points
        self.style = style
    }
}

public struct Note: Equatable, Sendable, Codable {
    public var text: String
    public var frame: Rect
    public var style: Style

    public init(text: String, frame: Rect, style: Style = Style()) {
        self.text = text
        self.frame = frame
        self.style = style
    }
}

// MARK: - Element

/// One entry in the board's flat element table. Common identity/placement
/// fields live here; the role-specific payload lives in `content`.
public struct Element: Identifiable, Equatable, Sendable {
    public var id: ElementID
    /// Multi-layer membership (D9). Always non-empty in a valid board.
    public var layerIDs: Set<LayerID>
    /// Fractional index defining z-order across the whole board.
    public var sortKey: String
    public var groupID: GroupID?
    public var content: Content
    public var extra: [String: JSONValue]

    public enum Content: Equatable, Sendable {
        case node(Node)
        case edge(Edge)
        case ink(Ink)
        case note(Note)
    }

    public init(
        id: ElementID = ElementID(),
        layerIDs: Set<LayerID>,
        sortKey: String,
        groupID: GroupID? = nil,
        content: Content,
        extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.layerIDs = layerIDs
        self.sortKey = sortKey
        self.groupID = groupID
        self.content = content
        self.extra = extra
    }

    public var node: Node? {
        if case .node(let value) = content { return value }
        return nil
    }

    public var edge: Edge? {
        if case .edge(let value) = content { return value }
        return nil
    }
}

extension Element: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, layers, sortKey, group, role
        // Role payload keys, flattened at the element level:
        case semantic, frame, shape, orientation, style, from, to, routing, waypoints, points, text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ElementID.self, forKey: .id)
        layerIDs = Set(try container.decode([LayerID].self, forKey: .layers))
        sortKey = try container.decode(String.self, forKey: .sortKey)
        groupID = try container.decodeIfPresent(GroupID.self, forKey: .group)

        let role = try container.decode(String.self, forKey: .role)
        switch role {
        case "node":
            content = .node(Node(
                semantic: try container.decodeIfPresent(NodeSemantic.self, forKey: .semantic) ?? NodeSemantic(),
                frame: try container.decode(Rect.self, forKey: .frame),
                shape: try container.decodeIfPresent(NodeShape.self, forKey: .shape) ?? .rectangle,
                orientation: try container.decodeIfPresent(ShapeOrientation.self, forKey: .orientation) ?? .up,
                style: try container.decodeIfPresent(Style.self, forKey: .style) ?? Style()
            ))
        case "edge":
            content = .edge(Edge(
                semantic: try container.decodeIfPresent(EdgeSemantic.self, forKey: .semantic) ?? EdgeSemantic(),
                from: try container.decode(Anchor.self, forKey: .from),
                to: try container.decode(Anchor.self, forKey: .to),
                routing: try container.decodeIfPresent(RoutingMode.self, forKey: .routing) ?? .straight,
                waypoints: try container.decodeIfPresent([Point].self, forKey: .waypoints) ?? [],
                style: try container.decodeIfPresent(Style.self, forKey: .style) ?? Style()
            ))
        case "ink":
            content = .ink(Ink(
                points: try container.decode([StrokePoint].self, forKey: .points),
                style: try container.decodeIfPresent(Style.self, forKey: .style) ?? Style()
            ))
        case "note":
            content = .note(Note(
                text: try container.decode(String.self, forKey: .text),
                frame: try container.decode(Rect.self, forKey: .frame),
                style: try container.decodeIfPresent(Style.self, forKey: .style) ?? Style()
            ))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .role, in: container,
                debugDescription: "Unknown element role '\(role)'"
            )
        }

        extra = try decoder.unknownFields(excluding: CodingKeys.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        // Sets have no stable order; sort for canonical output (NFR M3).
        try container.encode(layerIDs.sorted(), forKey: .layers)
        try container.encode(sortKey, forKey: .sortKey)
        try container.encodeIfPresent(groupID, forKey: .group)

        switch content {
        case .node(let node):
            try container.encode("node", forKey: .role)
            try container.encode(node.semantic, forKey: .semantic)
            try container.encode(node.frame, forKey: .frame)
            if node.shape != .rectangle {
                try container.encode(node.shape, forKey: .shape)
            }
            if node.orientation != .up {
                try container.encode(node.orientation, forKey: .orientation)
            }
            try container.encode(node.style, forKey: .style)
        case .edge(let edge):
            try container.encode("edge", forKey: .role)
            try container.encode(edge.semantic, forKey: .semantic)
            try container.encode(edge.from, forKey: .from)
            try container.encode(edge.to, forKey: .to)
            try container.encode(edge.routing, forKey: .routing)
            if !edge.waypoints.isEmpty { try container.encode(edge.waypoints, forKey: .waypoints) }
            try container.encode(edge.style, forKey: .style)
        case .ink(let ink):
            try container.encode("ink", forKey: .role)
            try container.encode(ink.points, forKey: .points)
            try container.encode(ink.style, forKey: .style)
        case .note(let note):
            try container.encode("note", forKey: .role)
            try container.encode(note.text, forKey: .text)
            try container.encode(note.frame, forKey: .frame)
            try container.encode(note.style, forKey: .style)
        }

        try encoder.encodeUnknownFields(extra)
    }
}
