import Foundation

/// A concern/view over the board (D9): infra, data flow, security, ownership…
/// Element membership lives on the elements (`Element.layerIDs`), not here.
/// The board's `layers` array order is the panel display order.
public struct Layer: Identifiable, Equatable, Sendable {
    public var id: LayerID
    public var name: String
    /// Optional hex color used to tint the layer's elements in focus mode.
    public var colorTint: String?
    public var isVisible: Bool
    public var isLocked: Bool
    public var extra: [String: JSONValue]

    public init(
        id: LayerID = LayerID(),
        name: String,
        colorTint: String? = nil,
        isVisible: Bool = true,
        isLocked: Bool = false,
        extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.colorTint = colorTint
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.extra = extra
    }
}

extension Layer: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, colorTint, isVisible, isLocked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(LayerID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorTint = try container.decodeIfPresent(String.self, forKey: .colorTint)
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        extra = try decoder.unknownFields(excluding: CodingKeys.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(colorTint, forKey: .colorTint)
        try container.encode(isVisible, forKey: .isVisible)
        try container.encode(isLocked, forKey: .isLocked)
        try encoder.encodeUnknownFields(extra)
    }
}

public struct Group: Identifiable, Equatable, Sendable {
    public var id: GroupID
    public var name: String?
    public var memberIDs: Set<ElementID>
    public var extra: [String: JSONValue]

    public init(
        id: GroupID = GroupID(),
        name: String? = nil,
        memberIDs: Set<ElementID> = [],
        extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.memberIDs = memberIDs
        self.extra = extra
    }
}

extension Group: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, members
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(GroupID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        memberIDs = Set(try container.decodeIfPresent([ElementID].self, forKey: .members) ?? [])
        extra = try decoder.unknownFields(excluding: CodingKeys.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(memberIDs.sorted(), forKey: .members)
        try encoder.encodeUnknownFields(extra)
    }
}
