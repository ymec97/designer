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
}

extension Rect {
    public func offsetBy(dx: Double, dy: Double) -> Rect {
        Rect(x: x + dx, y: y + dy, width: width, height: height)
    }
}
