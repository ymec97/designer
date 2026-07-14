import Foundation

/// P3 — hand-drawn ("sketchy") rendering support: deterministic jitter that
/// turns clean lines into Excalidraw-style rough strokes. Pure geometry so
/// the canvas renderer and exporters share identical wobble.
public enum Sketch {
    /// SplitMix64 — tiny, deterministic, good enough for visual jitter.
    public struct SeededRandom {
        private var state: UInt64
        public init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        public mutating func next() -> UInt64 {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        /// Uniform in [-1, 1].
        public mutating func unit() -> Double {
            Double(next() >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    /// A jittered variant of `points`: segments are subdivided (~`step` long)
    /// and interior points pushed perpendicular by up to `roughness`.
    /// Endpoints never move (anchors and arrowheads stay honest). `pass`
    /// varies the wobble so two overlaid passes read as one hand stroke.
    public static func roughPolyline(
        _ points: [Point], seed: UInt64, roughness: Double = 1.8,
        step: Double = 32, pass: Int = 0
    ) -> [Point] {
        guard points.count >= 2, roughness > 0 else { return points }
        var rng = SeededRandom(seed: seed &+ UInt64(pass) &* 0x9E37)
        var result: [Point] = [points[0]]
        for (a, b) in zip(points, points.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let length = (dx * dx + dy * dy).squareRoot()
            let pieces = max(1, Int(length / step))
            if length > 0.001 {
                let nx = -dy / length, ny = dx / length
                for piece in 1..<pieces {
                    let t = Double(piece) / Double(pieces)
                    let wobble = rng.unit() * roughness
                    result.append(Point(
                        x: a.x + dx * t + nx * wobble,
                        y: a.y + dy * t + ny * wobble
                    ))
                }
            }
            result.append(b)
        }
        return result
    }

    /// A jittered closed shape through `corners` (last point re-joins the
    /// first). All points may wobble — a shape outline has no anchors.
    public static func roughPolygon(
        _ corners: [Point], seed: UInt64, roughness: Double = 1.8,
        step: Double = 32, pass: Int = 0
    ) -> [Point] {
        guard corners.count >= 3 else { return corners }
        var rng = SeededRandom(seed: seed &+ UInt64(pass) &* 0x9E37)
        var result: [Point] = []
        let closed = corners + [corners[0]]
        for (a, b) in zip(closed, closed.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0.001 else { continue }
            let nx = -dy / length, ny = dx / length
            let pieces = max(1, Int(length / step))
            for piece in 0..<pieces {
                let t = Double(piece) / Double(pieces)
                let wobble = piece == 0 ? rng.unit() * roughness * 0.7 : rng.unit() * roughness
                result.append(Point(
                    x: a.x + dx * t + nx * wobble,
                    y: a.y + dy * t + ny * wobble
                ))
            }
        }
        return result
    }

    /// Polygon approximation of an ellipse, ready for `roughPolygon`.
    public static func ellipsePolygon(in rect: Rect, segments: Int = 26) -> [Point] {
        (0..<segments).map { index in
            let angle = Double(index) / Double(segments) * 2 * .pi
            return Point(
                x: rect.midX + cos(angle) * rect.width / 2,
                y: rect.midY + sin(angle) * rect.height / 2
            )
        }
    }
}

extension Board {
    /// P3 — hand-drawn render style, stored in `extra` (schema-neutral;
    /// older builds simply ignore it).
    public static let sketchyExtraKey = "sketchy"

    public var isSketchy: Bool {
        extra[Self.sketchyExtraKey] == .bool(true)
    }
}
