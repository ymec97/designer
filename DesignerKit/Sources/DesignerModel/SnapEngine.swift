import Foundation

/// Alignment snapping for drags (pure geometry, UI-free so it's testable).
/// Snaps a moving bounding box's edges and centers to other elements' edges
/// and centers, returning both the position adjustment and the guide lines to
/// draw.
public enum SnapEngine {
    public struct Guide: Equatable, Sendable {
        public enum Axis: Equatable, Sendable { case vertical, horizontal }
        public var axis: Axis
        /// World x for vertical guides, world y for horizontal guides.
        public var position: Double
        /// The extent to draw along the other axis (min…max), spanning the
        /// moving box and the element it aligned to.
        public var start: Double
        public var end: Double
    }

    public struct Result: Equatable, Sendable {
        public var dx: Double
        public var dy: Double
        public var guides: [Guide]
    }

    /// Adjusts a proposed move so `movingBox` (already offset by the raw drag)
    /// aligns to nearby `others`. `threshold` is in world units.
    public static func snap(
        movingBox: Rect, others: [Rect], threshold: Double
    ) -> Result {
        // Candidate lines from the moving box: left/centerX/right, top/mid/bottom.
        let movingX = [movingBox.x, movingBox.midX, movingBox.maxX]
        let movingY = [movingBox.y, movingBox.midY, movingBox.maxY]

        var bestX: (delta: Double, line: Double, other: Rect)?
        var bestY: (delta: Double, line: Double, other: Rect)?

        for other in others {
            let otherX = [other.x, other.midX, other.maxX]
            let otherY = [other.y, other.midY, other.maxY]
            for m in movingX {
                for o in otherX {
                    let delta = o - m
                    if abs(delta) <= threshold, abs(delta) < abs(bestX?.delta ?? .greatestFiniteMagnitude) {
                        bestX = (delta, o, other)
                    }
                }
            }
            for m in movingY {
                for o in otherY {
                    let delta = o - m
                    if abs(delta) <= threshold, abs(delta) < abs(bestY?.delta ?? .greatestFiniteMagnitude) {
                        bestY = (delta, o, other)
                    }
                }
            }
        }

        let dx = bestX?.delta ?? 0
        let dy = bestY?.delta ?? 0
        var guides: [Guide] = []
        if let bestX {
            let snapped = movingBox.offsetBy(dx: dx, dy: dy)
            guides.append(Guide(
                axis: .vertical, position: bestX.line,
                start: min(snapped.y, bestX.other.y),
                end: max(snapped.maxY, bestX.other.maxY)
            ))
        }
        if let bestY {
            let snapped = movingBox.offsetBy(dx: dx, dy: dy)
            guides.append(Guide(
                axis: .horizontal, position: bestY.line,
                start: min(snapped.x, bestY.other.x),
                end: max(snapped.maxX, bestY.other.maxX)
            ))
        }
        return Result(dx: dx, dy: dy, guides: guides)
    }

    /// Snaps a resize: only the edges that actually moved (vs `original`) snap
    /// to nearby `others'` edges/centers, so dragging a handle shows the same
    /// red alignment guides as moving. Returns the adjusted frame and guides.
    public static func snapResize(
        frame: Rect, original: Rect, others: [Rect], threshold: Double
    ) -> (frame: Rect, guides: [Guide]) {
        let eps = 1e-6
        var left = frame.x, right = frame.maxX, top = frame.y, bottom = frame.maxY
        var guides: [Guide] = []

        func nearestLine(to value: Double, vertical: Bool) -> (line: Double, other: Rect)? {
            var best: (d: Double, line: Double, other: Rect)?
            for other in others {
                let lines = vertical ? [other.x, other.midX, other.maxX] : [other.y, other.midY, other.maxY]
                for line in lines {
                    let d = line - value
                    if abs(d) <= threshold, abs(d) < abs(best?.d ?? .greatestFiniteMagnitude) {
                        best = (d, line, other)
                    }
                }
            }
            return best.map { ($0.line, $0.other) }
        }

        if abs(frame.x - original.x) > eps, let s = nearestLine(to: frame.x, vertical: true) {
            left = s.line
            guides.append(Guide(axis: .vertical, position: s.line,
                                start: min(frame.y, s.other.y), end: max(frame.maxY, s.other.maxY)))
        }
        if abs(frame.maxX - original.maxX) > eps, let s = nearestLine(to: frame.maxX, vertical: true) {
            right = s.line
            guides.append(Guide(axis: .vertical, position: s.line,
                                start: min(frame.y, s.other.y), end: max(frame.maxY, s.other.maxY)))
        }
        if abs(frame.y - original.y) > eps, let s = nearestLine(to: frame.y, vertical: false) {
            top = s.line
            guides.append(Guide(axis: .horizontal, position: s.line,
                                start: min(frame.x, s.other.x), end: max(frame.maxX, s.other.maxX)))
        }
        if abs(frame.maxY - original.maxY) > eps, let s = nearestLine(to: frame.maxY, vertical: false) {
            bottom = s.line
            guides.append(Guide(axis: .horizontal, position: s.line,
                                start: min(frame.x, s.other.x), end: max(frame.maxX, s.other.maxX)))
        }

        let snapped = Rect(x: min(left, right), y: min(top, bottom),
                           width: abs(right - left), height: abs(bottom - top))
        return (snapped, guides)
    }
}

extension Rect {
    public func offsetBy(dx: Double, dy: Double) -> Rect {
        Rect(x: x + dx, y: y + dy, width: width, height: height)
    }
}
