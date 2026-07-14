import Foundation

/// Uniform-grid spatial index over element bounds, for viewport culling and
/// hit-testing on large boards (D12). Rebuilt incrementally as elements
/// change; queries are O(cells touched), not O(elements).
public struct SpatialIndex {
    /// World-space size of one grid cell. Roughly a few node-widths: big
    /// enough that a node touches ~1–4 cells, small enough to cull well.
    private let cellSize: Double
    private var cells: [Cell: Set<ElementID>] = [:]
    private var bounds: [ElementID: Rect] = [:]

    private struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    public init(cellSize: Double = 512) {
        self.cellSize = cellSize
    }

    public init(board: Board, cellSize: Double = 512) {
        self.init(board: board, edgeRoutes: Self.resolveRoutes(for: board), cellSize: cellSize)
    }

    /// Variant taking pre-resolved routes so callers that cache routes (the
    /// canvas does) don't pay for resolution twice.
    public init(board: Board, edgeRoutes: [ElementID: EdgeGeometry.Route], cellSize: Double = 512) {
        self.init(cellSize: cellSize)
        for element in board.elements.values {
            if let rect = Self.boundingRect(of: element) {
                insert(element.id, bounds: rect)
            }
        }
        // Edges are indexed by their resolved route, padded so near-line hit
        // queries land in their cells.
        for (id, route) in edgeRoutes {
            let bounds = route.boundingRect
            insert(id, bounds: Rect(
                x: bounds.x - 8, y: bounds.y - 8,
                width: bounds.width + 16, height: bounds.height + 16
            ))
        }
    }

    public static func resolveRoutes(for board: Board) -> [ElementID: EdgeGeometry.Route] {
        let frames = board.frameProvider()
        let offsets = EdgeGeometry.parallelOffsets(in: board)
        let spread = EdgeGeometry.anchorSpread(in: board)
        var routes: [ElementID: EdgeGeometry.Route] = [:]
        for element in board.elements.values {
            if let edge = element.edge,
               let route = EdgeGeometry.route(
                   for: edge, frames: frames,
                   parallelOffset: offsets[element.id] ?? 0,
                   anchorOffsets: spread[element.id]) {
                routes[element.id] = route
            }
        }
        return routes
    }

    // MARK: Maintenance

    public mutating func insert(_ id: ElementID, bounds rect: Rect) {
        remove(id)
        bounds[id] = rect
        forEachCell(intersecting: rect) { cells[$0, default: []].insert(id) }
    }

    public mutating func remove(_ id: ElementID) {
        guard let rect = bounds.removeValue(forKey: id) else { return }
        forEachCell(intersecting: rect) { cell in
            cells[cell]?.remove(id)
            if cells[cell]?.isEmpty == true { cells.removeValue(forKey: cell) }
        }
    }

    public mutating func update(_ element: Element) {
        if let rect = Self.boundingRect(of: element) {
            insert(element.id, bounds: rect)
        } else {
            remove(element.id)
        }
    }

    // MARK: Queries

    /// IDs of elements whose bounds intersect `rect` (unordered).
    public func query(_ rect: Rect) -> Set<ElementID> {
        var result: Set<ElementID> = []
        forEachCell(intersecting: rect) { cell in
            guard let ids = cells[cell] else { return }
            for id in ids where bounds[id].map({ $0.intersects(rect) }) == true {
                result.insert(id)
            }
        }
        return result
    }

    /// IDs of elements whose bounds contain `point` (unordered; caller
    /// resolves z-order and precise shape testing).
    public func hits(at point: Point) -> Set<ElementID> {
        query(Rect(x: point.x, y: point.y, width: 0, height: 0))
    }

    public func storedBounds(of id: ElementID) -> Rect? {
        bounds[id]
    }

    /// World-space bounding rect for any element kind.
    public static func boundingRect(of element: Element) -> Rect? {
        switch element.content {
        case .node(let node):
            return node.frame
        case .note(let note):
            return note.frame
        case .boundary(let boundary):
            return boundary.frame
        case .ink(let ink):
            guard let first = ink.points.first else { return nil }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for point in ink.points {
                minX = min(minX, point.x); minY = min(minY, point.y)
                maxX = max(maxX, point.x); maxY = max(maxY, point.y)
            }
            return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .edge:
            // Edge geometry depends on the anchored elements; edges are
            // culled via their endpoints (M2 wires this up).
            return nil
        }
    }

    // MARK: Grid math

    private func forEachCell(intersecting rect: Rect, _ body: (Cell) -> Void) {
        let minX = Int((rect.x / cellSize).rounded(.down))
        let maxX = Int((rect.maxX / cellSize).rounded(.down))
        let minY = Int((rect.y / cellSize).rounded(.down))
        let maxY = Int((rect.maxY / cellSize).rounded(.down))
        for x in minX...maxX {
            for y in minY...maxY {
                body(Cell(x: x, y: y))
            }
        }
    }
}

extension Rect {
    public func intersects(_ other: Rect) -> Bool {
        x <= other.maxX && other.x <= maxX && y <= other.maxY && other.y <= maxY
    }

    public func contains(_ point: Point) -> Bool {
        point.x >= x && point.x <= maxX && point.y >= y && point.y <= maxY
    }
}
