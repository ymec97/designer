import Foundation

/// Pure geometry for connectors: resolving anchors against current node
/// frames and routing the line. Lives in the model package (no UI imports)
/// because attachment correctness is a model-level invariant the torture
/// tests must pin down.
public enum EdgeGeometry {
    /// A resolved, drawable route in world coordinates.
    public struct Route: Equatable, Sendable {
        public var points: [Point]

        public var start: Point { points.first ?? .zero }
        public var end: Point { points.last ?? .zero }

        public var midpoint: Point { point(atFraction: 0.5) }

        public var boundingRect: Rect {
            guard let first = points.first else { return Rect(x: 0, y: 0, width: 0, height: 0) }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x); minY = min(minY, point.y)
                maxX = max(maxX, point.x); maxY = max(maxY, point.y)
            }
            return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        /// The point a fraction (0…1) of the way along the route by arc length
        /// — used to animate a packet travelling the connector.
        public func point(atFraction fraction: Double) -> Point {
            guard points.count >= 2 else { return start }
            let clamped = max(0, min(1, fraction))
            let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
            let total = lengths.reduce(0, +)
            guard total > 0 else { return start }
            var remaining = clamped * total
            for (index, length) in lengths.enumerated() {
                if remaining <= length {
                    let t = length > 0 ? remaining / length : 0
                    let a = points[index], b = points[index + 1]
                    return Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                }
                remaining -= length
            }
            return end
        }

        /// Distance from a point to the nearest segment of the route.
        public func distance(to point: Point) -> Double {
            guard points.count >= 2 else {
                return hypot(point.x - start.x, point.y - start.y)
            }
            var best = Double.greatestFiniteMagnitude
            for (a, b) in zip(points, points.dropFirst()) {
                best = min(best, Self.segmentDistance(point, a, b))
            }
            return best
        }

        public static func segmentDistance(_ p: Point, _ a: Point, _ b: Point) -> Double {
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
            return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
        }
    }

    /// Frame lookup that lets the canvas feed in-flight drag frames without
    /// mutating the board.
    public typealias FrameProvider = (ElementID) -> Rect?

    /// Per-edge anchor-offset overrides so several connectors meeting the
    /// same node side spread along it instead of stacking on the midpoint.
    /// `captionT` staggers parallel edges' label pills along the route
    /// (everyone at 0.5 overlaps).
    public struct EndpointOffsets: Equatable {
        public var from: Double?
        public var to: Double?
        public var captionT: Double?
        public init(from: Double? = nil, to: Double? = nil, captionT: Double? = nil) {
            self.from = from
            self.to = to
            self.captionT = captionT
        }
    }

    /// Resolves an edge into a drawable route. Returns nil when an anchored
    /// element doesn't exist (e.g. mid-batch during cascade deletes).
    /// `parallelOffset` bows a direct route perpendicular to its line so
    /// parallel connectors between the same nodes separate visually (P4/F5 —
    /// you must be able to see *which* of two connectors carries a flow).
    /// `anchorOffsets` (from `anchorSpread(in:)`) slides auto anchors along
    /// their side; explicit model offsets always win.
    /// `obstacles` (bounding-box query for NODE frames, e.g. from
    /// `SpatialIndex.nodeObstacleQuery`) lets plain straight routes curve
    /// around blocks they'd otherwise cross (P5).
    public static func route(
        for edge: Edge,
        frames: FrameProvider,
        parallelOffset: Double = 0,
        anchorOffsets: EndpointOffsets? = nil,
        obstacles: ((Rect) -> [Rect])? = nil
    ) -> Route? {
        // With manual waypoints the connector should LEAVE its node toward
        // the first bend, not toward the far node.
        let towardFrom: Anchor = edge.waypoints.first.map { .free($0) } ?? edge.to
        let towardTo: Anchor = edge.waypoints.last.map { .free($0) } ?? edge.from
        guard
            let fromResolution = resolve(
                edge.from, toward: towardFrom, frames: frames, offsetOverride: anchorOffsets?.from),
            let toResolution = resolve(
                edge.to, toward: towardTo, frames: frames, offsetOverride: anchorOffsets?.to)
        else { return nil }

        var points: [Point]
        if edge.routing == .orthogonal, edge.waypoints.isEmpty {
            points = orthogonalRoute(from: fromResolution, to: toResolution)
        } else {
            points = [fromResolution.point] + edge.waypoints + [toResolution.point]
        }
        // Collapse consecutive duplicates so hit-testing and arrowheads are stable.
        points = points.reduce(into: []) { result, point in
            if result.last != point { result.append(point) }
        }
        guard points.count >= 2 else { return nil }

        // Manual waypoints render as a smooth curve through the bends (P5).
        if !edge.waypoints.isEmpty, edge.routing != .orthogonal, points.count >= 3 {
            points = smoothed(points)
        }

        // Bow parallels: only direct, waypoint-less lines participate (manual
        // waypoints are the user's routing; orthogonal parallels are rare).
        // Anchor spreading already separates endpoints along the node side —
        // bowing on top of it makes the lines weave, so spreading wins.
        let anchorsSpread = anchorOffsets?.from != nil || anchorOffsets?.to != nil
        if parallelOffset != 0, !anchorsSpread, points.count == 2, edge.waypoints.isEmpty {
            let a = points[0], b = points[1]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = (dx * dx + dy * dy).squareRoot()
            if length > 1 {
                let nx = -dy / length, ny = dx / length
                func bowed(_ t: Double, _ factor: Double) -> Point {
                    Point(x: a.x + dx * t + nx * parallelOffset * factor,
                          y: a.y + dy * t + ny * parallelOffset * factor)
                }
                points = [a, bowed(0.25, 0.8), bowed(0.5, 1), bowed(0.75, 0.8), b]
            }
        }

        // Node avoidance (P5): a plain straight line that would cross an
        // unrelated block detours around it with a gentle curve. Manual
        // waypoints, orthogonal routing, and bowed parallels are left alone.
        if points.count == 2, let obstacles {
            var detours = avoidanceWaypoints(from: points[0], to: points[1], obstacles: obstacles)
            if !detours.isEmpty {
                // Re-anchor the endpoints toward the detour they actually
                // approach from — anchors chosen for the straight line made
                // curves hook around and arrive on the wrong side. BUT never
                // accept a side that faces AWAY from the far endpoint: on a
                // wide/short node a detour waypoint nudged just above center
                // would otherwise pick `.top`, sending the arrowhead across
                // the whole node to poke into the top edge from above.
                var start = points[0], end = points[1]
                if let first = detours.first,
                   let resolved = resolve(edge.from, toward: .free(first), frames: frames,
                                          offsetOverride: anchorOffsets?.from),
                   sideFaces(resolved.side, from: resolved.point, toward: points[1]) {
                    start = resolved.point
                }
                if let last = detours.last,
                   let resolved = resolve(edge.to, toward: .free(last), frames: frames,
                                          offsetOverride: anchorOffsets?.to),
                   sideFaces(resolved.side, from: resolved.point, toward: points[0]) {
                    end = resolved.point
                }
                var candidate = smoothed([start] + detours + [end])
                // Spline overshoot can clip blocks the straight line missed
                // (dense rows). Verify; if dirty, flip the detour side once;
                // if still dirty, an honest straight line beats a weird hook.
                if routeIntersectsBlockers(candidate, from: start, to: end, obstacles: obstacles) {
                    detours = mirroredWaypoints(detours, from: points[0], to: points[1])
                    candidate = smoothed([start] + detours + [end])
                    if routeIntersectsBlockers(candidate, from: start, to: end, obstacles: obstacles) {
                        candidate = points
                    }
                }
                points = candidate
            }
        }

        return Route(points: points)
    }

    /// Centripetal-ish Catmull-Rom sampling: a polyline that passes exactly
    /// through every input point but bends smoothly. Downstream code (hit
    /// tests, packets, arrowheads, exports) keeps working on plain polylines.
    static func smoothed(_ points: [Point], samplesPerSegment: Int = 14) -> [Point] {
        guard points.count >= 3 else { return points }
        func interpolate(_ p0: Point, _ p1: Point, _ p2: Point, _ p3: Point, _ t: Double) -> Point {
            let t2 = t * t, t3 = t2 * t
            func axis(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
                0.5 * ((2 * b) + (c - a) * t
                       + (2 * a - 5 * b + 4 * c - d) * t2
                       + (3 * b - a - 3 * c + d) * t3)
            }
            return Point(x: axis(p0.x, p1.x, p2.x, p3.x), y: axis(p0.y, p1.y, p2.y, p3.y))
        }
        var result: [Point] = []
        for index in 0..<(points.count - 1) {
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]
            for sample in 0..<samplesPerSegment {
                result.append(interpolate(p0, p1, p2, p3, Double(sample) / Double(samplesPerSegment)))
            }
        }
        result.append(points[points.count - 1])
        return result
    }

    /// Where a straight `a`→`b` line should bend to clear the blocks it
    /// crosses (empty when it's already clear). Blockers are grouped into
    /// clusters ALONG the line, and each cluster gets its own perpendicular
    /// waypoint on its cheaper side — a long connector over a row of nodes
    /// weaves past each one instead of attempting (and giving up on) a
    /// single giant bow. A cluster whose detour would be absurd (>220pt) is
    /// crossed rather than dodged.
    static func avoidanceWaypoints(
        from a: Point, to b: Point, obstacles: (Rect) -> [Rect]
    ) -> [Point] {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1 else { return [] }
        let nx = -dy / length, ny = dx / length

        let margin = 14.0
        let searchBox = Rect(
            x: min(a.x, b.x) - margin, y: min(a.y, b.y) - margin,
            width: abs(dx) + margin * 2, height: abs(dy) + margin * 2
        )
        struct Blocker {
            var rect: Rect
            var tMin: Double // projection range along a→b, in [0, 1]
            var tMax: Double
        }
        var blockers: [Blocker] = []
        for raw in obstacles(searchBox) {
            let rect = Rect(x: raw.x - margin, y: raw.y - margin,
                            width: raw.width + margin * 2, height: raw.height + margin * 2)
            guard !rect.contains(a), !rect.contains(b), segmentIntersects(rect, a, b) else { continue }
            var tMin = Double.infinity, tMax = -Double.infinity
            for corner in [Point(x: rect.x, y: rect.y), Point(x: rect.maxX, y: rect.y),
                           Point(x: rect.x, y: rect.maxY), Point(x: rect.maxX, y: rect.maxY)] {
                let t = ((corner.x - a.x) * dx + (corner.y - a.y) * dy) / (length * length)
                tMin = min(tMin, t)
                tMax = max(tMax, t)
            }
            blockers.append(Blocker(rect: rect, tMin: max(tMin, 0), tMax: min(tMax, 1)))
        }
        guard !blockers.isEmpty else { return [] }

        // Merge blockers whose spans along the line touch into clusters.
        blockers.sort { $0.tMin < $1.tMin }
        var clusters: [[Blocker]] = []
        for blocker in blockers {
            if var last = clusters.last, let end = last.map(\.tMax).max(),
               blocker.tMin <= end + 0.02 {
                last.append(blocker)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([blocker])
            }
        }

        var waypoints: [Point] = []
        for cluster in clusters {
            var maxSigned = -Double.infinity
            var minSigned = Double.infinity
            for blocker in cluster {
                let rect = blocker.rect
                for corner in [Point(x: rect.x, y: rect.y), Point(x: rect.maxX, y: rect.y),
                               Point(x: rect.x, y: rect.maxY), Point(x: rect.maxX, y: rect.maxY)] {
                    let signed = (corner.x - a.x) * nx + (corner.y - a.y) * ny
                    maxSigned = max(maxSigned, signed)
                    minSigned = min(minSigned, signed)
                }
            }
            let clearance = 18.0
            let positive = maxSigned + clearance
            let negative = minSigned - clearance
            let offset = abs(positive) <= abs(negative) ? positive : negative
            guard abs(offset) <= 220 else { continue } // cross this one
            let tMid = ((cluster.map(\.tMin).min() ?? 0) + (cluster.map(\.tMax).max() ?? 1)) / 2
            waypoints.append(Point(
                x: a.x + dx * tMid + nx * offset,
                y: a.y + dy * tMid + ny * offset
            ))
        }
        return waypoints
    }

    /// Collision-aware caption placement for one render pass. Each placed
    /// pill registers as an obstacle for the pills after it, so labels never
    /// stack on labels; candidates scan along the route AND perpendicular to
    /// it (dense boards with short connectors have no clear on-route spot).
    /// Falls back to the preferred midpoint when everything is blocked — an
    /// overlapping label beats a missing one.
    public struct CaptionPlacer {
        private var placedPills: [Rect] = []

        public init() {}

        public mutating func place(
            preferred: Double,
            route: Route,
            pillSize: Size,
            obstacles: (Rect) -> [Rect]
        ) -> Point {
            let alongOffsets: [Double] = [0, 0.08, -0.08, 0.16, -0.16, 0.24, -0.24, 0.32, -0.32, 0.4, -0.4]
            let perpendicularSteps: [Double] = [0, 1, -1, 2, -2]
            var fallback: Point?
            for along in alongOffsets {
                let t = min(0.92, max(0.08, preferred + along))
                let base = route.point(atFraction: t)
                let normal = normalAt(route: route, fraction: t)
                for step in perpendicularSteps {
                    let push = step * (pillSize.height / 2 + 12)
                    let center = Point(x: base.x + normal.x * push, y: base.y + normal.y * push)
                    if fallback == nil { fallback = center }
                    let pill = Rect(
                        x: center.x - pillSize.width / 2, y: center.y - pillSize.height / 2,
                        width: pillSize.width, height: pillSize.height
                    )
                    let blocked = placedPills.contains { $0.intersects(pill) }
                        || obstacles(pill).contains { $0.intersects(pill) }
                    if !blocked {
                        placedPills.append(pill)
                        return center
                    }
                }
            }
            let center = fallback ?? route.midpoint
            placedPills.append(Rect(
                x: center.x - pillSize.width / 2, y: center.y - pillSize.height / 2,
                width: pillSize.width, height: pillSize.height))
            return center
        }

        private func normalAt(route: Route, fraction: Double) -> Point {
            let ahead = route.point(atFraction: min(1, fraction + 0.05))
            let behind = route.point(atFraction: max(0, fraction - 0.05))
            let dx = ahead.x - behind.x, dy = ahead.y - behind.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0.001 else { return Point(x: 0, y: -1) }
            return Point(x: -dy / length, y: dx / length)
        }
    }

    /// True when a sampled route passes through any blocking node (the ones
    /// not hosting its endpoints) — the post-detour sanity check.
    private static func routeIntersectsBlockers(
        _ points: [Point], from a: Point, to b: Point, obstacles: (Rect) -> [Rect]
    ) -> Bool {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return false }
        let blockers = obstacles(Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            .filter { !$0.contains(a) && !$0.contains(b) }
        guard !blockers.isEmpty else { return false }
        // Endpoints hug their node borders; skip the first/last few samples.
        for point in points.dropFirst(3).dropLast(3) {
            if blockers.contains(where: { $0.contains(point) }) { return true }
        }
        return false
    }

    /// The same waypoints reflected to the other side of the a→b line.
    private static func mirroredWaypoints(_ waypoints: [Point], from a: Point, to b: Point) -> [Point] {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.001 else { return waypoints }
        return waypoints.map { point in
            let t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
            let projection = Point(x: a.x + dx * t, y: a.y + dy * t)
            return Point(x: 2 * projection.x - point.x, y: 2 * projection.y - point.y)
        }
    }

    private static func segmentIntersects(_ rect: Rect, _ a: Point, _ b: Point) -> Bool {
        // Liang–Barsky clip of segment against rect.
        let dx = b.x - a.x, dy = b.y - a.y
        var t0 = 0.0, t1 = 1.0
        for (p, q) in [(-dx, a.x - rect.x), (dx, rect.maxX - a.x),
                       (-dy, a.y - rect.y), (dy, rect.maxY - a.y)] {
            if p == 0 {
                if q < 0 { return false }
                continue
            }
            let r = q / p
            if p < 0 {
                if r > t1 { return false }
                t0 = max(t0, r)
            } else {
                if r < t0 { return false }
                t1 = min(t1, r)
            }
        }
        return t0 <= t1
    }

    /// Perpendicular offsets that fan out edges sharing the same node pair
    /// (±9, ±18, …, sign-canonicalized so opposite-direction edges land on
    /// opposite sides rather than colliding). Edges with manual waypoints are
    /// left alone. Empty result for boards without parallels.
    public static func parallelOffsets(in board: Board) -> [ElementID: Double] {
        var groups: [String: [ElementID]] = [:]
        var flipped: Set<ElementID> = []
        for element in board.elementsInZOrder {
            guard let edge = element.edge, edge.waypoints.isEmpty,
                  let a = edge.from.elementID, let b = edge.to.elementID, a != b else { continue }
            let canonical = a.rawValue < b.rawValue
            if !canonical { flipped.insert(element.id) }
            let key = canonical ? "\(a.rawValue)|\(b.rawValue)" : "\(b.rawValue)|\(a.rawValue)"
            groups[key, default: []].append(element.id)
        }
        var offsets: [ElementID: Double] = [:]
        let spacing = 28.0
        for ids in groups.values where ids.count > 1 {
            let base = -spacing * Double(ids.count - 1) / 2
            for (index, id) in ids.enumerated() {
                let canonicalOffset = base + spacing * Double(index)
                offsets[id] = flipped.contains(id) ? -canonicalOffset : canonicalOffset
            }
        }
        return offsets
    }

    /// Distributes auto anchors sharing a node side so arrows never stack on
    /// the side's midpoint: each (node, side) group is sorted by where the
    /// connector comes from and spaced around the center. Adding or removing
    /// a connector re-flows the whole side. Explicitly pinned anchors
    /// (side/offset set in the model) and edges with manual waypoints are
    /// left untouched.
    public static func anchorSpread(in board: Board) -> [ElementID: EndpointOffsets] {
        let frames = board.frameProvider()

        struct SideKey: Hashable {
            var nodeID: ElementID
            var side: Anchor.Side
        }
        struct Slot {
            var edgeID: ElementID
            var isFrom: Bool
            /// Sort key: the other endpoint's position along the side's axis,
            /// so connectors keep their left-to-right/top-to-bottom order and
            /// don't cross. Ties (parallel edges) keep z-order.
            var order: Double
        }
        var groups: [SideKey: [Slot]] = [:]

        for element in board.elementsInZOrder {
            guard let edge = element.edge, edge.waypoints.isEmpty else { continue }
            for isFrom in [true, false] {
                let anchor = isFrom ? edge.from : edge.to
                let other = isFrom ? edge.to : edge.from
                guard case .element(let nodeID, nil, nil) = anchor,
                      let frame = frames(nodeID) else { continue }
                let toward = targetPoint(of: other, frames: frames)
                let side = autoSide(from: frame, toward: toward)
                let horizontal = side == .top || side == .bottom
                groups[SideKey(nodeID: nodeID, side: side), default: []].append(
                    Slot(edgeID: element.id, isFrom: isFrom,
                         order: horizontal ? toward.x : toward.y))
            }
        }

        var spread: [ElementID: EndpointOffsets] = [:]

        // Parallel edges (same node pair): stagger their caption pills along
        // the route so labels never sit on top of each other.
        var pairs: [String: [ElementID]] = [:]
        for element in board.elementsInZOrder {
            guard let edge = element.edge, edge.waypoints.isEmpty,
                  let a = edge.from.elementID, let b = edge.to.elementID, a != b else { continue }
            let key = a.rawValue.uuidString < b.rawValue.uuidString
                ? "\(a.rawValue)|\(b.rawValue)" : "\(b.rawValue)|\(a.rawValue)"
            pairs[key, default: []].append(element.id)
        }
        for ids in pairs.values where ids.count > 1 {
            for (index, id) in ids.enumerated() {
                var offsets = spread[id] ?? EndpointOffsets()
                offsets.captionT = 0.32 + 0.36 * Double(index) / Double(ids.count - 1)
                spread[id] = offsets
            }
        }

        for (key, slots) in groups where slots.count > 1 {
            guard let frame = frames(key.nodeID) else { continue }
            let length = (key.side == .top || key.side == .bottom)
                ? frame.width : frame.height
            guard length > 0 else { continue }

            let sorted = slots.enumerated().sorted {
                $0.element.order != $1.element.order
                    ? $0.element.order < $1.element.order
                    : $0.offset < $1.offset
            }.map(\.element)
            // Centered, evenly spaced, never within 10% of a corner.
            let spacing = min(26.0, length * 0.8 / Double(sorted.count - 1))
            let base = -spacing * Double(sorted.count - 1) / 2
            for (index, slot) in sorted.enumerated() {
                let t = min(0.9, max(0.1, 0.5 + (base + spacing * Double(index)) / length))
                var offsets = spread[slot.edgeID] ?? EndpointOffsets()
                if slot.isFrom { offsets.from = t } else { offsets.to = t }
                spread[slot.edgeID] = offsets
            }
        }
        return spread
    }

    // MARK: Anchor resolution

    struct Resolution {
        var point: Point
        var side: Anchor.Side?
    }

    static func resolve(
        _ anchor: Anchor,
        toward other: Anchor,
        frames: FrameProvider,
        offsetOverride: Double? = nil
    ) -> Resolution? {
        switch anchor {
        case .free(let point):
            return Resolution(point: point, side: nil)
        case .element(let id, let side, let offset):
            guard let frame = frames(id) else { return nil }
            let resolvedSide = side ?? autoSide(from: frame, toward: targetPoint(of: other, frames: frames))
            return Resolution(
                point: point(on: frame, side: resolvedSide, offset: offset ?? offsetOverride ?? 0.5),
                side: resolvedSide
            )
        }
    }

    /// Where the opposite endpoint roughly is, for auto-side selection.
    private static func targetPoint(of anchor: Anchor, frames: FrameProvider) -> Point {
        switch anchor {
        case .free(let point):
            return point
        case .element(let id, _, _):
            guard let frame = frames(id) else { return .zero }
            return Point(x: frame.midX, y: frame.midY)
        }
    }

    /// The outward normal of a node side (screen coords: +y is down).
    private static func outwardNormal(_ side: Anchor.Side) -> (dx: Double, dy: Double) {
        switch side {
        case .top: return (0, -1)
        case .bottom: return (0, 1)
        case .left: return (-1, 0)
        case .right: return (1, 0)
        default: return (0, 0)
        }
    }

    /// True when `side` (at border point `from`) opens toward `target` — i.e.
    /// the connector arriving/leaving there does NOT have to cross the node
    /// interior to reach the far endpoint. A nil side (free anchor) always
    /// passes. Used to reject a detour-chosen side that faces away.
    private static func sideFaces(_ side: Anchor.Side?, from: Point, toward target: Point) -> Bool {
        guard let side else { return true }
        let normal = outwardNormal(side)
        let toTarget = (dx: target.x - from.x, dy: target.y - from.y)
        return normal.dx * toTarget.dx + normal.dy * toTarget.dy >= 0
    }

    /// Picks the frame side facing `target` (dominant axis wins).
    public static func autoSide(from frame: Rect, toward target: Point) -> Anchor.Side {
        let dx = target.x - frame.midX
        let dy = target.y - frame.midY
        // Normalize by half-extents so flat/wide nodes don't bias the choice.
        let nx = frame.width > 0 ? dx / (frame.width / 2) : dx
        let ny = frame.height > 0 ? dy / (frame.height / 2) : dy
        if abs(nx) >= abs(ny) {
            return nx >= 0 ? .right : .left
        }
        return ny >= 0 ? .bottom : .top
    }

    public static func point(on frame: Rect, side: Anchor.Side, offset: Double) -> Point {
        let t = max(0, min(1, offset))
        switch side {
        case .top: return Point(x: frame.x + frame.width * t, y: frame.y)
        case .bottom: return Point(x: frame.x + frame.width * t, y: frame.maxY)
        case .left: return Point(x: frame.x, y: frame.y + frame.height * t)
        case .right: return Point(x: frame.maxX, y: frame.y + frame.height * t)
        default: return Point(x: frame.midX, y: frame.midY)
        }
    }

    // MARK: Orthogonal routing

    /// Simple elbow route: leave each anchor perpendicular to its side by a
    /// stub, then connect with at most two bends. Not obstacle-avoiding (that
    /// is a later refinement); manual waypoints override it entirely.
    static func orthogonalRoute(from: Resolution, to: Resolution) -> [Point] {
        let stub: Double = 24
        let start = from.point
        let end = to.point
        let startStub = offset(start, side: from.side, by: stub)
        let endStub = offset(end, side: to.side, by: stub)

        let startHorizontal = from.side == .left || from.side == .right
        var middle: [Point]
        if startHorizontal {
            // H → V → H
            let midX = (startStub.x + endStub.x) / 2
            middle = [
                Point(x: midX, y: startStub.y),
                Point(x: midX, y: endStub.y),
            ]
        } else {
            // V → H → V
            let midY = (startStub.y + endStub.y) / 2
            middle = [
                Point(x: startStub.x, y: midY),
                Point(x: endStub.x, y: midY),
            ]
        }
        return [start, startStub] + middle + [endStub, end]
    }

    private static func offset(_ point: Point, side: Anchor.Side?, by distance: Double) -> Point {
        switch side {
        case .top: return Point(x: point.x, y: point.y - distance)
        case .bottom: return Point(x: point.x, y: point.y + distance)
        case .left: return Point(x: point.x - distance, y: point.y)
        case .right: return Point(x: point.x + distance, y: point.y)
        default: return point
        }
    }
}

extension Board {
    /// Effective frame lookup for anchor resolution against the live board.
    public func frameProvider(overrides: [ElementID: Rect] = [:]) -> EdgeGeometry.FrameProvider {
        { id in
            if let override = overrides[id] { return override }
            guard let element = self.elements[id] else { return nil }
            return SpatialIndex.boundingRect(of: element)
        }
    }

    /// All edges anchored to the given element (for cascade delete and
    /// invalidation when a node moves).
    public func edges(anchoredTo id: ElementID) -> [Element] {
        elements.values.filter { element in
            guard let edge = element.edge else { return false }
            return edge.from.elementID == id || edge.to.elementID == id
        }
    }

    // NOTE: connection "merging" (absorbing repeat connections, silently
    // upgrading opposite drags to bidirectional) was removed 2026-07-15:
    // drawing a second connection between a pair now always creates a
    // PARALLEL connector — anchor spreading keeps them readable, and
    // bidirectional is an explicit edge-editor property.
}
