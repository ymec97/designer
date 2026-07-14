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

        public var midpoint: Point {
            guard points.count >= 2 else { return start }
            let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
            let total = lengths.reduce(0, +)
            guard total > 0 else { return start }
            var remaining = total / 2
            for (index, length) in lengths.enumerated() where remaining <= length {
                let t = length > 0 ? remaining / length : 0
                let a = points[index], b = points[index + 1]
                return Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            return end
        }

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
    public struct EndpointOffsets: Equatable {
        public var from: Double?
        public var to: Double?
        public init(from: Double? = nil, to: Double? = nil) {
            self.from = from
            self.to = to
        }
    }

    /// Resolves an edge into a drawable route. Returns nil when an anchored
    /// element doesn't exist (e.g. mid-batch during cascade deletes).
    /// `parallelOffset` bows a direct route perpendicular to its line so
    /// parallel connectors between the same nodes separate visually (P4/F5 —
    /// you must be able to see *which* of two connectors carries a flow).
    /// `anchorOffsets` (from `anchorSpread(in:)`) slides auto anchors along
    /// their side; explicit model offsets always win.
    public static func route(
        for edge: Edge,
        frames: FrameProvider,
        parallelOffset: Double = 0,
        anchorOffsets: EndpointOffsets? = nil
    ) -> Route? {
        guard
            let fromResolution = resolve(
                edge.from, toward: edge.to, frames: frames, offsetOverride: anchorOffsets?.from),
            let toResolution = resolve(
                edge.to, toward: edge.from, frames: frames, offsetOverride: anchorOffsets?.to)
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
        return Route(points: points)
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

    /// How a new connection `from → to` relates to an existing edge between
    /// the same pair, so both the connect gesture and sketch conversion make
    /// the same call: same-direction repeats are absorbed (no duplicates, no
    /// accidental bidirectional), opposite-direction repeats upgrade to `both`.
    public enum ConnectionMergeOutcome: Equatable {
        /// No edge between the pair — insert a new one.
        case none
        /// An edge already expresses this direction (or is bidirectional).
        case alreadyConnected(ElementID)
        /// An edge exists in the opposite direction — upgrade it to `.both`.
        case oppositeDirection(ElementID)
    }

    public func connectionMergeOutcome(from: ElementID, to: ElementID) -> ConnectionMergeOutcome {
        for element in elements.values {
            guard let edge = element.edge else { continue }
            let endpoints = (edge.from.elementID, edge.to.elementID)
            let sameOrientation = endpoints == (from, to)
            let oppositeOrientation = endpoints == (to, from)
            guard sameOrientation || oppositeOrientation else { continue }

            switch edge.semantic.direction {
            case .both, .none:
                return .alreadyConnected(element.id)
            case .backward:
                // `backward` flips the arrow: from→to arrows point at `from`.
                return sameOrientation
                    ? .oppositeDirection(element.id)
                    : .alreadyConnected(element.id)
            default: // .forward and unknown values
                return sameOrientation
                    ? .alreadyConnected(element.id)
                    : .oppositeDirection(element.id)
            }
        }
        return .none
    }

    /// The operation upgrading an existing edge to bidirectional.
    public func makeBidirectionalOperation(_ id: ElementID) -> BoardOperation? {
        guard var element = elements[id], var edge = element.edge else { return nil }
        edge.semantic.direction = .both
        element.content = .edge(edge)
        return .replaceElement(element)
    }
}
