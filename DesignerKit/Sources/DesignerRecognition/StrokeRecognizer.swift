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
        case triangle(Rect, apex: ShapeOrientation)
        case line(from: Point, to: Point)
    }

    // Tunables, expressed relative to stroke size so recognition is
    // zoom- and scale-independent.
    static let minimumPoints = 8
    static let minimumSize: Double = 16
    static let closureThreshold = 0.3       // gap/diagonal to count as closed
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

        // Closed if the ends nearly meet, OR the stroke clearly loops around
        // its bounds (hand-drawn circles often stop 30–50% short of their
        // start; a loop's path length ≈ 2.8–3.2× its diagonal, a line's ≈ 1).
        let gap = distance(points[0], points[points.count - 1])
        let loopiness = pathLength(points) / diagonal
        let isClosed = gap < closureThreshold * diagonal
            || (gap < 0.55 * diagonal && loopiness > 2.2)

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

        // Roundness first: a true circle/ellipse (circularity → 1) is round
        // regardless of how its jittery hull simplifies. Squares and diamonds
        // sit near 0.785, triangles near 0.6, so 0.82 cleanly separates
        // "round" from "cornered". (Straight-edged shapes fail this and are
        // classified by corner count below.)
        let perimeter = pathLength(points) + distance(points[0], points[points.count - 1])
        let area = polygonArea(points)
        let circularity = perimeter > 0 ? 4 * .pi * area / (perimeter * perimeter) : 0
        // The convex hull is jitter-free, so its circularity is a far more
        // reliable roundness measure for a wobbly hand-drawn circle, whose raw
        // perimeter is inflated by tremor — that inflation pushed real circles
        // below the gate and misfiled them as rectangles (B5).
        let hullPerimeter = hull.count > 1
            ? pathLength(hull) + distance(hull[hull.count - 1], hull[0]) : perimeter
        let hullCircularity = hullPerimeter > 0
            ? 4 * .pi * polygonArea(hull) / (hullPerimeter * hullPerimeter) : 0
        if max(circularity, hullCircularity) > 0.80 {
            return .ellipse(bounds)
        }

        // Reduce the convex hull to its dominant corners (Douglas-Peucker) to
        // count straight sides.
        let diagonal = (bounds.width * bounds.width + bounds.height * bounds.height).squareRoot()
        let cornerPoints = simplifiedRingVertices(hull, epsilon: 0.08 * diagonal)

        switch cornerPoints.count {
        case 3:
            return .triangle(bounds, apex: triangleApex(cornerPoints))

        case 4:
            // Rectangle if corners sit near the bounding-box corners,
            // diamond if near the edge midpoints.
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
            let toBoxCorners = averageNearestDistance(from: cornerPoints, to: boxCorners) / diagonal
            let toMidpoints = averageNearestDistance(from: cornerPoints, to: midpoints) / diagonal
            return toMidpoints < toBoxCorners ? .diamond(bounds) : .rectangle(bounds)

        default:
            // Many small segments that never resolved into 3/4 clean corners
            // is the signature of a round blob, not a box — prefer an ellipse
            // when the (jitter-free) hull reads round-ish. Only genuinely
            // cornered sloppy shapes fall through to a rectangle (B5).
            return hullCircularity > 0.70 ? .ellipse(bounds) : .rectangle(bounds)
        }
    }

    /// Which way a triangle's apex points. The apex is the vertex between the
    /// two most nearly equal edges (the tip of an isosceles triangle); its
    /// offset from the opposite side's midpoint, snapped to an axis, gives the
    /// direction. Screen y grows downward.
    static func triangleApex(_ vertices: [Point]) -> ShapeOrientation {
        guard vertices.count == 3 else { return .up }
        func edgeLength(_ a: Int, _ b: Int) -> Double { distance(vertices[a], vertices[b]) }

        var apexIndex = 0
        var smallestDifference = Double.greatestFiniteMagnitude
        for i in 0..<3 {
            let left = (i + 2) % 3
            let right = (i + 1) % 3
            let difference = abs(edgeLength(i, left) - edgeLength(i, right))
            if difference < smallestDifference {
                smallestDifference = difference
                apexIndex = i
            }
        }

        let apex = vertices[apexIndex]
        let a = vertices[(apexIndex + 1) % 3]
        let b = vertices[(apexIndex + 2) % 3]
        let baseMid = Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = apex.x - baseMid.x
        let dy = apex.y - baseMid.y
        if abs(dx) > abs(dy) {
            return dx > 0 ? .right : .left
        }
        return dy > 0 ? .down : .up
    }

    /// Dominant corners of a closed ring after Douglas-Peucker simplification.
    /// A triangle → 3 points, square/diamond → 4, circle → many. Splits the
    /// ring at its two most distant vertices so the closed curve simplifies
    /// cleanly.
    static func simplifiedRingVertices(_ ring: [Point], epsilon: Double) -> [Point] {
        let n = ring.count
        guard n > 3 else { return ring }

        // Split point: the vertex farthest from ring[0].
        var farIndex = 0
        var farDistance = -1.0
        for i in 1..<n {
            let d = distance(ring[0], ring[i])
            if d > farDistance { farDistance = d; farIndex = i }
        }
        let arcA = Array(ring[0...farIndex])
        let arcB = Array(ring[farIndex..<n]) + [ring[0]]
        let simplifiedA = douglasPeucker(arcA, epsilon: epsilon)
        let simplifiedB = douglasPeucker(arcB, epsilon: epsilon)
        // Drop the two shared endpoints (start and split appear in both arcs).
        return Array(simplifiedA.dropLast()) + Array(simplifiedB.dropLast())
    }

    static func douglasPeucker(_ points: [Point], epsilon: Double) -> [Point] {
        guard points.count > 2 else { return points }
        let first = points[0]
        let last = points[points.count - 1]
        var maxDistance = 0.0
        var index = 0
        for i in 1..<(points.count - 1) {
            let d = EdgeGeometry.Route.segmentDistance(points[i], first, last)
            if d > maxDistance { maxDistance = d; index = i }
        }
        if maxDistance > epsilon {
            let left = douglasPeucker(Array(points[0...index]), epsilon: epsilon)
            let right = douglasPeucker(Array(points[index..<points.count]), epsilon: epsilon)
            return left.dropLast() + right
        }
        return [first, last]
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
