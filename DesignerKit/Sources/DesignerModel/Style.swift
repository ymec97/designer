import Foundation

/// Presentation styling shared by all element kinds. Colors are hex strings
/// ("#RRGGBB" or "#RRGGBBAA"); nil means "use the app default for this kind",
/// which keeps documents small and lets defaults evolve without migrations.
/// `fill` may also be the sentinel `Style.noFill` ("none"): the shape draws
/// with NO background at all — outline and label only — which "#RRGGBB00"
/// can't express without also implying "a fill exists".
public struct Style: Equatable, Sendable {
    /// The `fill` sentinel meaning "no background".
    public static let noFill = "none"

    public var fill: String?
    public var stroke: String?
    public var strokeWidth: Double?
    /// Whole-element opacity 0…1 (fill, stroke, and label fade together);
    /// nil means fully opaque.
    public var opacity: Double?
    /// Embedded image as a data: URI (PNG/JPEG/SVG). Drawn inside the node's
    /// frame; imported diagrams (draw.io/Excalidraw) carry icons this way.
    public var image: String?
    public var extra: [String: JSONValue]

    public init(
        fill: String? = nil,
        stroke: String? = nil,
        strokeWidth: Double? = nil,
        opacity: Double? = nil,
        image: String? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.opacity = opacity
        self.image = image
        self.extra = extra
    }

    /// True when the element paints no background (the noFill sentinel).
    public var hasFill: Bool { fill != Self.noFill }
    /// Effective opacity: declared value clamped to 0…1, or fully opaque.
    public var effectiveOpacity: Double { min(max(opacity ?? 1, 0), 1) }
}

extension Style: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case fill, stroke, strokeWidth, opacity, image
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fill = try container.decodeIfPresent(String.self, forKey: .fill)
        stroke = try container.decodeIfPresent(String.self, forKey: .stroke)
        strokeWidth = try container.decodeIfPresent(Double.self, forKey: .strokeWidth)
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity)
        image = try container.decodeIfPresent(String.self, forKey: .image)
        extra = try decoder.unknownFields(excluding: CodingKeys.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(fill, forKey: .fill)
        try container.encodeIfPresent(stroke, forKey: .stroke)
        try container.encodeIfPresent(strokeWidth, forKey: .strokeWidth)
        try container.encodeIfPresent(opacity, forKey: .opacity)
        try container.encodeIfPresent(image, forKey: .image)
        try encoder.encodeUnknownFields(extra)
    }
}
