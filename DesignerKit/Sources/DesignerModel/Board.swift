import Foundation

/// The document root. Named `Board` (not `Document`) to avoid colliding with
/// AppKit's NSDocument terminology in the app layer.
public struct Board: Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: BoardID
    public var title: String
    public var createdAt: Date
    public var modifiedAt: Date
    /// Panel order. A valid board always has at least one layer.
    public var layers: [Layer]
    public var elements: [Element]
    public var groups: [Group]
    public var extra: [String: JSONValue]

    public init(
        schemaVersion: Int = Board.currentSchemaVersion,
        id: BoardID = BoardID(),
        title: String,
        createdAt: Date = Date().millisecondRounded,
        modifiedAt: Date? = nil,
        layers: [Layer] = [Layer(name: "Base")],
        elements: [Element] = [],
        groups: [Group] = [],
        extra: [String: JSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.layers = layers
        self.elements = elements
        self.groups = groups
        self.extra = extra
    }

    public func element(withID id: ElementID) -> Element? {
        elements.first { $0.id == id }
    }

    /// The sort key that places a new element above everything else.
    public var topSortKey: String {
        SortKey.after(elements.map(\.sortKey).max())
    }
}

extension Board: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, id, title, createdAt, modifiedAt, layers, elements, groups
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(BoardID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date().millisecondRounded
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
        layers = try container.decodeIfPresent([Layer].self, forKey: .layers) ?? []
        if layers.isEmpty { layers = [Layer(name: "Base")] }
        elements = try container.decodeIfPresent([Element].self, forKey: .elements) ?? []
        groups = try container.decodeIfPresent([Group].self, forKey: .groups) ?? []
        extra = try decoder.unknownFields(excluding: CodingKeys.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(layers, forKey: .layers)
        try container.encode(elements, forKey: .elements)
        try container.encode(groups, forKey: .groups)
        try encoder.encodeUnknownFields(extra)
    }
}

extension Date {
    /// Timestamps are stored as ISO 8601 with millisecond precision. All model
    /// dates are quantized through this: the canonical Date for N milliseconds
    /// is always the exact same Double, so encode→decode round-trips compare
    /// equal. (Serialization applies the same quantization after parsing.)
    public var millisecondRounded: Date {
        Date(unixMilliseconds: unixMilliseconds)
    }

    public var unixMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    public init(unixMilliseconds: Int64) {
        self.init(timeIntervalSince1970: Double(unixMilliseconds) / 1000)
    }
}
