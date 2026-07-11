/// Model-space geometry. Deliberately independent of CoreGraphics so the model
/// package stays UI-free and deterministic (NFR M1).

public struct Point: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: 0, y: 0)
}

public struct Size: Equatable, Codable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct Rect: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var origin: Point { Point(x: x, y: y) }
    public var size: Size { Size(width: width, height: height) }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// A single freehand ink sample. Encoded as a compact `[x, y, pressure, time]`
/// array because boards can hold hundreds of strokes with thousands of samples.
public struct StrokePoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    /// Normalized 0...1; 0.5 is the neutral value for devices without pressure.
    public var pressure: Double
    /// Seconds since the start of the stroke.
    public var time: Double

    public init(x: Double, y: Double, pressure: Double = 0.5, time: Double = 0) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.time = time
    }
}

extension StrokePoint: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(Double.self)
        y = try container.decode(Double.self)
        pressure = try container.decodeIfPresent(Double.self) ?? 0.5
        time = try container.decodeIfPresent(Double.self) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
        try container.encode(pressure)
        try container.encode(time)
    }
}
