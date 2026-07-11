import Foundation

/// Stable, CRDT-compatible identifiers (D11). Encoded as UUID strings in JSON.
/// Concrete types (not a generic phantom) to keep Codable synthesis and
/// diagnostics simple; they never mix because they are distinct types.

public struct BoardID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UUID
    public init() { rawValue = UUID() }
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue.uuidString < rhs.rawValue.uuidString }
    public var description: String { rawValue.uuidString }
}

public struct LayerID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UUID
    public init() { rawValue = UUID() }
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue.uuidString < rhs.rawValue.uuidString }
    public var description: String { rawValue.uuidString }
}

public struct ElementID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UUID
    public init() { rawValue = UUID() }
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue.uuidString < rhs.rawValue.uuidString }
    public var description: String { rawValue.uuidString }
}

public struct GroupID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UUID
    public init() { rawValue = UUID() }
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue.uuidString < rhs.rawValue.uuidString }
    public var description: String { rawValue.uuidString }
}
