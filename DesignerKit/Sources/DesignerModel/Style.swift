import Foundation

/// Presentation styling shared by all element kinds. Colors are hex strings
/// ("#RRGGBB" or "#RRGGBBAA"); nil means "use the app default for this kind",
/// which keeps documents small and lets defaults evolve without migrations.
public struct Style: Equatable, Sendable {
    public var fill: String?
    public var stroke: String?
    public var strokeWidth: Double?
    /// Embedded image as a data: URI (PNG/JPEG/SVG). Drawn inside the node's
    /// frame; imported diagrams (draw.io/Excalidraw) carry icons this way.
    public var image: String?
    public var extra: [String: JSONValue]

    public init(
        fill: String? = nil,
        stroke: String? = nil,
        strokeWidth: Double? = nil,
        image: String? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.image = image
        self.extra = extra
    }
}

extension Style: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case fill, stroke, strokeWidth, image
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fill = try container.decodeIfPresent(String.self, forKey: .fill)
        stroke = try container.decodeIfPresent(String.self, forKey: .stroke)
        strokeWidth = try container.decodeIfPresent(Double.self, forKey: .strokeWidth)
        image = try container.decodeIfPresent(String.self, forKey: .image)
        extra = try decoder.unknownFields(excluding: CodingKeys.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(fill, forKey: .fill)
        try container.encodeIfPresent(stroke, forKey: .stroke)
        try container.encodeIfPresent(strokeWidth, forKey: .strokeWidth)
        try container.encodeIfPresent(image, forKey: .image)
        try encoder.encodeUnknownFields(extra)
    }
}
