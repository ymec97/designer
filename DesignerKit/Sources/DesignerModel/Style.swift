import Foundation

/// Presentation styling shared by all element kinds. Colors are hex strings
/// ("#RRGGBB" or "#RRGGBBAA"); nil means "use the app default for this kind",
/// which keeps documents small and lets defaults evolve without migrations.
/// `fill` may also be the sentinel `Style.noFill` ("none"): the shape draws
/// with NO background at all — outline and label only — which "#RRGGBB00"
/// can't express without also implying "a fill exists".
/// Presentational label size: a multiplier on an element's base font size.
/// nil == medium (1.0). Kept OFF the agent wire format on purpose — it is pure
/// presentation, and because proposals parse anchored to the current board a
/// matched node keeps its textSize automatically; putting it on the wire would
/// let an agent silently reset user typography ("can't wipe what they can't
/// see"). String-backed so unknown future values round-trip.
public enum TextSize: String, Codable, Sendable, CaseIterable {
    case small, medium, large, xl

    public var multiplier: Double {
        switch self {
        case .small:  return 0.8
        case .medium: return 1.0
        case .large:  return 1.7
        case .xl:     return 2.8
        }
    }
}

/// Background pattern, orthogonal to the fill *color*: `solid` paints a flat
/// fill, `stripes` paints diagonal hatching over it. nil == solid.
/// String-backed so unknown future patterns round-trip.
public enum FillPattern: String, Codable, Sendable, CaseIterable {
    case solid, stripes
}

/// Outline style, orthogonal to stroke color/width: `solid` or `dashed`.
/// nil == solid. String-backed so unknown future styles round-trip.
public enum OutlineStyle: String, Codable, Sendable, CaseIterable {
    case solid, dashed
}

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
    /// Presentational label size; nil == medium. See `TextSize`.
    public var textSize: TextSize?
    /// Background pattern; nil == solid. See `FillPattern`.
    public var fillPattern: FillPattern?
    /// Outline style; nil == solid. See `OutlineStyle`.
    public var outlineStyle: OutlineStyle?
    public var extra: [String: JSONValue]

    public init(
        fill: String? = nil,
        stroke: String? = nil,
        strokeWidth: Double? = nil,
        opacity: Double? = nil,
        image: String? = nil,
        textSize: TextSize? = nil,
        fillPattern: FillPattern? = nil,
        outlineStyle: OutlineStyle? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.opacity = opacity
        self.image = image
        self.textSize = textSize
        self.fillPattern = fillPattern
        self.outlineStyle = outlineStyle
        self.extra = extra
    }

    /// True when the element paints no background (the noFill sentinel).
    public var hasFill: Bool { fill != Self.noFill }
    /// Effective opacity: declared value clamped to 0…1, or fully opaque.
    public var effectiveOpacity: Double { min(max(opacity ?? 1, 0), 1) }
    /// Label font multiplier (medium when unset).
    public var effectiveTextMultiplier: Double { (textSize ?? .medium).multiplier }
    /// True when the background should be hatched with diagonal stripes.
    public var isStriped: Bool { fillPattern == .stripes }
    /// True when the outline should be dashed.
    public var isDashed: Bool { outlineStyle == .dashed }
}

extension Style: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case fill, stroke, strokeWidth, opacity, image, textSize, fillPattern, outlineStyle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fill = try container.decodeIfPresent(String.self, forKey: .fill)
        stroke = try container.decodeIfPresent(String.self, forKey: .stroke)
        strokeWidth = try container.decodeIfPresent(Double.self, forKey: .strokeWidth)
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity)
        image = try container.decodeIfPresent(String.self, forKey: .image)
        textSize = try container.decodeIfPresent(TextSize.self, forKey: .textSize)
        // Lenient: an unknown future pattern/style name reads as nil (the
        // default) rather than failing the whole board's decode.
        fillPattern = try container.decodeIfPresent(String.self, forKey: .fillPattern)
            .flatMap(FillPattern.init(rawValue:))
        outlineStyle = try container.decodeIfPresent(String.self, forKey: .outlineStyle)
            .flatMap(OutlineStyle.init(rawValue:))
        extra = try decoder.unknownFields(excluding: CodingKeys.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(fill, forKey: .fill)
        try container.encodeIfPresent(stroke, forKey: .stroke)
        try container.encodeIfPresent(strokeWidth, forKey: .strokeWidth)
        try container.encodeIfPresent(opacity, forKey: .opacity)
        try container.encodeIfPresent(image, forKey: .image)
        try container.encodeIfPresent(textSize, forKey: .textSize)
        // Omit when default so documents stay small and old boards migrate free.
        if fillPattern != nil, fillPattern != .solid {
            try container.encode(fillPattern, forKey: .fillPattern)
        }
        if outlineStyle != nil, outlineStyle != .solid {
            try container.encode(outlineStyle, forKey: .outlineStyle)
        }
        try encoder.encodeUnknownFields(extra)
    }
}
