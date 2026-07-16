import Foundation

/// String-backed "open enums": the UI knows the built-in values, but unknown
/// values written by future versions round-trip untouched instead of failing
/// to decode (NFR R2).

public struct NodeKind: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let service: NodeKind = "service"
    public static let database: NodeKind = "database"
    public static let queue: NodeKind = "queue"
    public static let cache: NodeKind = "cache"
    public static let gateway: NodeKind = "gateway"
    public static let client: NodeKind = "client"
    public static let external: NodeKind = "external"
    public static let generic: NodeKind = "generic"

    /// The kinds the UI offers (unknown values still round-trip).
    public static let allBuiltIn: [NodeKind] = [
        .service, .database, .queue, .cache, .gateway, .client, .external, .generic,
    ]
}

public struct EdgeDirection: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let forward: EdgeDirection = "forward"
    public static let backward: EdgeDirection = "backward"
    public static let both: EdgeDirection = "both"
    public static let none: EdgeDirection = "none"

    public static let allBuiltIn: [EdgeDirection] = [.forward, .backward, .both, .none]
}

/// Node outline shape (presentation). Sketch recognition preserves what the
/// user drew; the default block is a rectangle.
public struct NodeShape: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let rectangle: NodeShape = "rectangle"
    public static let ellipse: NodeShape = "ellipse"
    public static let diamond: NodeShape = "diamond"
    public static let triangle: NodeShape = "triangle"
    public static let cylinder: NodeShape = "cylinder"
    public static let cloud: NodeShape = "cloud"

    public static let allBuiltIn: [NodeShape] = [
        .rectangle, .ellipse, .diamond, .triangle, .cylinder, .cloud,
    ]
}

/// Orientation for shapes that have one (triangles): which way the apex
/// points. Rectangles/ellipses ignore it.
public struct ShapeOrientation: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let up: ShapeOrientation = "up"
    public static let down: ShapeOrientation = "down"
    public static let left: ShapeOrientation = "left"
    public static let right: ShapeOrientation = "right"

    public static let allBuiltIn: [ShapeOrientation] = [.up, .down, .left, .right]
}

public struct RoutingMode: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let straight: RoutingMode = "straight"
    public static let orthogonal: RoutingMode = "orthogonal"
}

/// Well-known edge property keys (D8). Arbitrary keys are allowed; these are
/// the ones the UI renders as badges and the exporters understand.
public enum WellKnownEdgeProperty {
    public static let protocolKey = "protocol"
    public static let data = "data"
    public static let condition = "condition"
    public static let direction = "direction"
    public static let ownership = "ownership"
    public static let latency = "latency"
    public static let trustBoundary = "trust-boundary"
    public static let failureMode = "failure-mode"
}
