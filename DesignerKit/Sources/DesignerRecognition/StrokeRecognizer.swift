import Foundation
import DesignerModel

/// Geometric sketch recognition (D15): resample → closed-shape test →
/// corner analysis. Deliberately conservative — a stroke that isn't clearly
/// a shape stays ink, which users forgive; a wrong conversion they don't.
public enum StrokeRecognizer {
    public enum Recognition: Equatable, Sendable {
        case rectangle(Rect)
        case ellipse(Rect)
        case diamond(Rect)
        case line(from: Point, to: Point)
    }

    // Tunables, expressed relative to stroke size so recognition is
    // zoom- and scale-independent.
    static let minimumPoints = 8
    static let minimumSize: Double = 16
    static let closureThreshold = 0.22      // gap/diagonal to count as closed
    static let lineDeviation = 0.09         // max offset/length to count as a line
    static let cornerAngle = 0.65           // radians (~37°) of turn to be a corner

    public static func recognize(_ strokePoints: [StrokePoint]) -> Recognition? {
        let raw = strokePoints.map { Point(x: $0.x, y: $0.y) }
        guard raw.count >= minimumPoints else { return nil }

        let bounds = boundingRect(of: raw)
        let diagonal = (bounds.width * bounds.width + bounds.height * bounds.height).squareRoot()
        guard max(bounds.width, bounds.height) >= minimumSize else { return nil }

        let points = resample(raw, spacing: max(diagonal / 64, 1))
        guard points.count >= minimumPoints else { return nil }

        let gap = distance(points[0], points[points.count - 1])
        let isClosed = gap < closureThreshold * diagonal

        if !isClosed {
            return recognizeLine(points)
        }
        return recognizeClosedShape(points, bounds: bounds)
    }

    // MARK: Open strokes

    /// Open strokes count as connector candidates when they progress from A
    /// to B without doubling back — curvature is fine (hand-drawn arrows bow),
    /// scribbles are not. Attachment (endpoints near two blocks) is decided
    /// by the conversion layer, which is the real disambiguator.
    private static func recognizeLine(_ points: [Point]) -> Recognition? {
        let start = points[0]
        let end = points[points.count - 1]
        let chord = distance(start, end)
        guard chord > 0 else { return nil }

        let maxDeviation = points
            .map { EdgeGeometry.Route.segmentDistance($0, start, end) }
            .max() ?? 0
        let windingRatio = pathLength(points) / chord

        // Either near-straight, or moderately curved without backtracking.
        if maxDeviation <= lineDeviation * chord || windingRatio <= 1.8 {
            return .line(from: start, to: end)
        }
        return nil
    }

    // MARK: Closed shapes

    private static func recognizeClosedShape(_ points: [Point], bounds: Rect) -> Recognition? {
        // Gate on solidity first: any closed stroke that fills its convex
        // hull like a real shape (not a scribble) converts to a block —
        // the product semantic is "closed shape = block", and users draw
        // circles, blobs, and diamonds expecting exactly that.
        let hull = convexHull(points)
        let solidity = hullSolidity(points, hull: hull)
        guard solidity >= 0.72 else { return nil }

        let corners = detectCorners(points)

        switch corners.count {
        case 0...2:
            // Smooth closed curve. Roundness picks ellipse; anything else
            // solid still converts (as a rectangle-presented block).
            let perimeter = pathLength(points) + distance(points[0], points[points.count - 1])
            let area = polygonArea(points)
            let circularity = 4 * .pi * area / (perimeter * perimeter)
            return circularity > 0.55 ? .ellipse(bounds) : .rectangle(bounds)

        case 3...5:
            // Quadrilateral-ish. Rectangle if corners sit near the bounding
            // box corners; diamond if they sit near the edge midpoints.
            let cornerPoints = corners.map { points[$0] }
            let boxCorners = [
                Point(x: bounds.x, y: bounds.y),
                Point(x: bounds.maxX, y: bounds.y),
                Point(x: bounds.maxX, y: bounds.maxY),
                Point(x: bounds.x, y: bounds.maxY),
            ]
            let midpoints = [
                Point(x: bounds.midX, y: bounds.y),
                Point(x: bounds.maxX, y: bounds.midY),
                Point(x: bounds.midX, y: bounds.maxY),
                Point(x: bounds.x, y: bounds.midY),
            ]
            let diagonal = (bounds.width * bounds.width + bounds.height * bounds.height).squareRoot()
            let toBoxCorners = averageNearestDistance(from: cornerPoints, to: boxCorners) / diagonal
            let toMidpoints = averageNearestDistance(from: cornerPoints, to: midpoints) / diagonal
            if toBoxCorners <= toMidpoints, toBoxCorners < 0.18 {
                return .rectangle(bounds)
            }
            if toMidpoints < toBoxCorners, toMidpoints < 0.18 {
                return .diamond(bounds)
            }
            // Solid closed quad that fits neither template cleanly (rotated,
            // skewed): still a block.
            return .rectangle(bounds)

        default:
            // Solid but many corners (hexagon-ish sketch, sloppy box with
            // extra kinks): still a block. Solidity already rejected scribbles.
            return .rectangle(bounds)
        }
    }

    // MARK: Solidity

    /// Monotone-chain convex hull.
    static func convexHull(_ input: [Point]) -> [Point] {
        let points = input.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        guard points.count > 2 else { return points }
        func cross(_ o: Point, _ a: Point, _ b: Point) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [Point] = []
        for point in points {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [Point] = []
        for point in points.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Stroke area / hull area: ~1 for clean convex shapes, low for scribbles.
    static func hullSolidity(_ points: [Point], hull: [Point]) -> Double {
        let hullArea = polygonArea(hull)
        guard hullArea > 0 else { return 0 }
        return polygonArea(points) / hullArea
    }

    /// Indices of sharp direction changes along a resampled stroke.
    static func detectCorners(_ points: [Point]) -> [Int] {
        guard points.count > 8 else { return [] }
        let window = max(2, points.count / 16)
        var candidates: [(index: Int, turn: Double)] = []

        for i in window..<(points.count - window) {
            let before = points[i - window]
            let here = points[i]
            let after = points[i + window]
            let angleIn = atan2(here.y - before.y, here.x - before.x)
            let angleOut = atan2(after.y - here.y, after.x - here.x)
            var turn = abs(angleOut - angleIn)
            if turn > .pi { turn = 2 * .pi - turn }
            if turn > cornerAngle {
                candidates.append((i, turn))
            }
        }

        // Merge runs of consecutive candidates, keeping the sharpest of each.
        var corners: [Int] = []
        var run: [(index: Int, turn: Double)] = []
        func flush() {
            if let best = run.max(by: { $0.turn < $1.turn }) {
                corners.append(best.index)
            }
            run = []
        }
        for candidate in candidates {
            if let last = run.last, candidate.index - last.index > window {
                flush()
            }
            run.append(candidate)
        }
        flush()
        return corners
    }

    // MARK: Geometry helpers

    static func resample(_ points: [Point], spacing: Double) -> [Point] {
        guard points.count > 1, spacing > 0 else { return points }
        var result = [points[0]]
        var carry = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            var segment = distance(a, b)
            var origin = a
            while carry + segment >= spacing {
                let t = (spacing - carry) / segment
                let next = Point(
                    x: origin.x + (b.x - origin.x) * t,
                    y: origin.y + (b.y - origin.y) * t
                )
                result.append(next)
                segment -= (spacing - carry)
                carry = 0
                origin = next
            }
            carry += segment
        }
        return result
    }

    static func boundingRect(of points: [Point]) -> Rect {
        guard let first = points.first else { return Rect(x: 0, y: 0, width: 0, height: 0) }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); minY = min(minY, point.y)
            maxX = max(maxX, point.x); maxY = max(maxY, point.y)
        }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func distance(_ a: Point, _ b: Point) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    static func pathLength(_ points: [Point]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    static func polygonArea(_ points: [Point]) -> Double {
        guard points.count > 2 else { return 0 }
        var sum = 0.0
        for (a, b) in zip(points, points.dropFirst() + [points[0]]) {
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    static func averageNearestDistance(from sources: [Point], to targets: [Point]) -> Double {
        guard !sources.isEmpty else { return .greatestFiniteMagnitude }
        let total = sources.reduce(0.0) { partial, source in
            partial + (targets.map { distance(source, $0) }.min() ?? 0)
        }
        return total / Double(sources.count)
    }
}
