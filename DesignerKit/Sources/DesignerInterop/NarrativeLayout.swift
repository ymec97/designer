import Foundation
import DesignerModel

/// The auto-layout used when a proposed/imported board omits positions —
/// built to read the way a HUMAN would draw it:
///
/// - **Flow with entry points**: sources (clients, flow starts) on the left,
///   traffic progressing left→right. Cycle-safe: depths come from Kahn's
///   topological ordering with deliberate cycle-breaking, never the runaway
///   relaxation that produced depth-48 towers.
/// - **Logically close = physically close**: nodes sharing a specialty layer
///   (the semantic the agent already provides) stay contiguous within their
///   column; cluster order follows connections (barycenter passes).
/// - **Peripherals at the edge**: `kind: external` blocks form a bottom row.
/// - **Compact but readable**: proportional depth compression caps columns,
///   tall columns spill sideways, blocks size to their names. A very complex
///   board may exceed the ~3–4 screen budget — readability wins.
/// - **Direction-aware**: `left-right` (default), `right-left`, `top-down`.
enum NarrativeLayout {
    static let maxColumns = 8
    static let maxRowsPerColumn = 10
    static let rowPitch = 128.0
    static let columnGap = 110.0
    static let clusterGap = 44.0

    static func normalizedDirection(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "right-left", "rtl", "right-to-left": return "right-left"
        case "top-down", "ttb", "top-bottom", "top-to-bottom": return "top-down"
        default: return "left-right"
        }
    }

    /// Frames for the nodes that omit `at`/`size`. Nodes that already have
    /// positions participate as anchors but are not moved.
    static func frames(
        nodes: [WireBoard.WireNode],
        edges: [WireBoard.WireEdge],
        flows: [WireBoard.WireFlow]?,
        direction rawDirection: String?
    ) -> [String: Rect] {
        let needing = nodes.filter { !($0.at?.count == 2 && $0.size?.count == 2) }
        guard !needing.isEmpty else { return [:] }
        let direction = normalizedDirection(rawDirection)

        let needingIDs = Set(needing.map(\.id))
        let subgraphEdges = edges.filter { needingIDs.contains($0.from) && needingIDs.contains($0.to) }
        var frames = layoutFull(nodes: needing, edges: subgraphEdges, flows: flows)

        // Direction transform (computed LTR first).
        if direction != "left-right" {
            let maxX = frames.values.map(\.maxX).max() ?? 0
            for (id, frame) in frames {
                switch direction {
                case "right-left":
                    frames[id] = Rect(x: maxX - frame.x - frame.width + 80, y: frame.y,
                                      width: frame.width, height: frame.height)
                case "top-down":
                    frames[id] = Rect(x: frame.y, y: frame.x,
                                      width: frame.width, height: frame.height)
                default:
                    break
                }
            }
        }

        // Anchored placement: when SOME nodes already have positions, the new
        // block of nodes lands beside the existing content, level with its
        // strongest-connected placed neighbor (the present-time overlap guard
        // still backstops).
        let placed = nodes.filter { $0.at?.count == 2 && $0.size?.count == 2 }
        if !placed.isEmpty {
            let placedMaxX = placed.compactMap { ($0.at?[0] ?? 0) + ($0.size?[0] ?? 0) }.max() ?? 0
            let placedMinY = placed.compactMap { $0.at?[1] }.min() ?? 0
            var anchorY = placedMinY
            let neighborCounts = edges.reduce(into: [String: Int]()) { counts, edge in
                if needingIDs.contains(edge.from), !needingIDs.contains(edge.to) { counts[edge.to, default: 0] += 1 }
                if needingIDs.contains(edge.to), !needingIDs.contains(edge.from) { counts[edge.from, default: 0] += 1 }
            }
            if let strongest = neighborCounts.max(by: { $0.value < $1.value })?.key,
               let neighbor = placed.first(where: { $0.id == strongest }), let at = neighbor.at {
                anchorY = at[1]
            }
            let blockMinX = frames.values.map(\.x).min() ?? 0
            let blockMinY = frames.values.map(\.y).min() ?? 0
            let dx = placedMaxX + 160 - blockMinX
            let dy = anchorY - blockMinY
            for (id, frame) in frames {
                frames[id] = Rect(x: frame.x + dx, y: frame.y + dy,
                                  width: frame.width, height: frame.height)
            }
        }
        return frames
    }

    // MARK: - Full narrative layout (LTR)

    private static func layoutFull(
        nodes: [WireBoard.WireNode],
        edges: [WireBoard.WireEdge],
        flows: [WireBoard.WireFlow]?
    ) -> [String: Rect] {
        let order = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = nodes.map(\.id)

        // Externals form the peripheral bottom row, outside the column flow.
        let externalIDs = Set(nodes.filter { $0.kind == "external" }.map(\.id))
        let flowSources = Set((flows ?? []).map(\.source))

        // 1. Cycle-safe depths: Kahn's ordering; when a cycle stalls the
        // queue, force the node with the fewest unresolved inputs.
        var depth = cycleSafeDepths(
            ids: ids.filter { !externalIDs.contains($0) },
            edges: edges.filter { !externalIDs.contains($0.from) && !externalIDs.contains($0.to) },
            preferredSources: flowSources,
            order: order
        )

        // 2. Proportional depth compression: a 24-stage pipeline squeezes
        // into 8 columns MONOTONICALLY (adjacent stages merge; the
        // left-to-right story survives) instead of wrapping into bands.
        let maxDepth = depth.values.max() ?? 0
        if maxDepth + 1 > maxColumns {
            for (id, d) in depth {
                depth[id] = Int((Double(d) * Double(maxColumns - 1) / Double(maxDepth)).rounded())
            }
        }

        // 3. Cluster keys: the most-specific declared layer (fewest members);
        // base-only nodes cluster by themselves.
        var layerCounts: [String: Int] = [:]
        for node in nodes {
            for layer in node.layers ?? [] { layerCounts[layer, default: 0] += 1 }
        }
        func cluster(of id: String) -> String {
            guard let layers = byID[id]?.layers, !layers.isEmpty else { return "" }
            return layers.min { (layerCounts[$0] ?? 0, $0) < (layerCounts[$1] ?? 0, $1) } ?? ""
        }

        // 4. Column membership + ordering: cluster blocks stay contiguous;
        // two barycenter passes order clusters and members by their
        // neighbors' rows to shorten connectors.
        var columns: [[String]] = Array(repeating: [], count: maxColumns)
        for id in ids where !externalIDs.contains(id) {
            columns[min(depth[id] ?? 0, maxColumns - 1)].append(id)
        }
        columns = columns.filter { !$0.isEmpty }

        var rowOf: [String: Double] = [:]
        func assignRows() {
            for column in columns {
                for (row, id) in column.enumerated() { rowOf[id] = Double(row) }
            }
        }
        func neighborRows(of id: String) -> [Double] {
            var rows: [Double] = []
            for edge in edges {
                if edge.from == id, let row = rowOf[edge.to] { rows.append(row) }
                if edge.to == id, let row = rowOf[edge.from] { rows.append(row) }
            }
            return rows
        }
        assignRows()
        for _ in 0..<3 {
            for (index, column) in columns.enumerated() {
                // Cluster barycenter, then member barycenter inside cluster.
                let grouped = Dictionary(grouping: column, by: cluster(of:))
                let sortedClusters = grouped.sorted { a, b in
                    let aRows = a.value.flatMap(neighborRows(of:))
                    let bRows = b.value.flatMap(neighborRows(of:))
                    let aBary = aRows.isEmpty ? Double(order[a.value[0]] ?? 0) : aRows.reduce(0, +) / Double(aRows.count)
                    let bBary = bRows.isEmpty ? Double(order[b.value[0]] ?? 0) : bRows.reduce(0, +) / Double(bRows.count)
                    return aBary != bBary ? aBary < bBary : a.key < b.key
                }
                var reordered: [String] = []
                for (_, members) in sortedClusters {
                    reordered += members.sorted { a, b in
                        let aRows = neighborRows(of: a), bRows = neighborRows(of: b)
                        let aBary = aRows.isEmpty ? Double(order[a] ?? 0) : aRows.reduce(0, +) / Double(aRows.count)
                        let bBary = bRows.isEmpty ? Double(order[b] ?? 0) : bRows.reduce(0, +) / Double(bRows.count)
                        return aBary != bBary ? aBary < bBary : (order[a] ?? 0) < (order[b] ?? 0)
                    }
                }
                columns[index] = reordered
            }
            assignRows()
        }

        // 5. Tall columns spill sideways (split at cluster boundaries when
        // one is nearby) instead of growing into towers.
        var spilled: [[String]] = []
        for column in columns {
            if column.count <= maxRowsPerColumn {
                spilled.append(column)
                continue
            }
            var start = 0
            while start < column.count {
                var end = min(start + maxRowsPerColumn, column.count)
                if end < column.count {
                    // Prefer breaking between clusters (look back ≤3 rows).
                    for back in 0..<3 where end - back - 1 > start {
                        if cluster(of: column[end - back - 1]) != cluster(of: column[end - back]) {
                            end -= back
                            break
                        }
                    }
                }
                spilled.append(Array(column[start..<end]))
                start = end
            }
        }
        columns = spilled

        // 6. Sizes + frames. Blocks widen for their names (no more "…" on
        // every block); columns pitch by their widest member.
        func blockSize(_ id: String) -> Size {
            let name = byID[id]?.name ?? byID[id]?.id ?? ""
            let width = min(max(160, 44 + Double(name.count) * 8.6), 280)
            return Size(width: width, height: 64)
        }
        var frames: [String: Rect] = [:]
        var x = 80.0
        var boardBottom = 80.0
        for column in columns {
            let widest = column.map { blockSize($0).width }.max() ?? 160
            var y = 80.0
            var previousCluster: String?
            for id in column {
                let size = blockSize(id)
                if let previous = previousCluster, previous != cluster(of: id) {
                    y += clusterGap
                }
                previousCluster = cluster(of: id)
                frames[id] = Rect(x: x + (widest - size.width) / 2, y: y,
                                  width: size.width, height: size.height)
                y += rowPitch
            }
            boardBottom = max(boardBottom, y)
            x += widest + columnGap
        }

        // 7. Externals: a wrapped row along the bottom — supporting cast.
        let externals = ids.filter { externalIDs.contains($0) }
        if !externals.isEmpty {
            let boardWidth = max(x - columnGap, 1200)
            var ex = 80.0
            var ey = boardBottom + 140
            for id in externals {
                let size = blockSize(id)
                if ex + size.width > 80 + boardWidth, ex > 80 {
                    ex = 80.0
                    ey += rowPitch
                }
                frames[id] = Rect(x: ex, y: ey, width: size.width, height: size.height)
                ex += size.width + 60
            }
        }
        return frames
    }

    /// Longest-path depths over a DAG obtained by Kahn's ordering; cycles
    /// are broken deliberately (stall → force the node with the fewest
    /// unresolved inputs) so depths stay small and meaningful.
    static func cycleSafeDepths(
        ids: [String],
        edges: [WireBoard.WireEdge],
        preferredSources: Set<String>,
        order: [String: Int]
    ) -> [String: Int] {
        let idSet = Set(ids)
        var incoming: [String: Int] = Dictionary(ids.map { ($0, 0) }, uniquingKeysWith: { a, _ in a })
        var outEdges: [String: [String]] = [:]
        for edge in edges where idSet.contains(edge.from) && idSet.contains(edge.to) && edge.from != edge.to {
            incoming[edge.to, default: 0] += 1
            outEdges[edge.from, default: []].append(edge.to)
        }

        var depth: [String: Int] = [:]
        var processed: Set<String> = []
        var remaining = incoming

        func ready() -> [String] {
            ids.filter { !processed.contains($0) && remaining[$0] == 0 }
                .sorted { a, b in
                    // Flow sources first, then declaration order.
                    let aFlow = preferredSources.contains(a), bFlow = preferredSources.contains(b)
                    if aFlow != bFlow { return aFlow }
                    return (order[a] ?? 0) < (order[b] ?? 0)
                }
        }

        while processed.count < ids.count {
            var queue = ready()
            if queue.isEmpty {
                // Cycle: force the unprocessed node with the fewest
                // unresolved inputs (ties by declaration order).
                if let forced = ids.filter({ !processed.contains($0) })
                    .min(by: { (remaining[$0] ?? 0, order[$0] ?? 0) < (remaining[$1] ?? 0, order[$1] ?? 0) }) {
                    remaining[forced] = 0
                    queue = [forced]
                } else {
                    break
                }
            }
            for id in queue {
                processed.insert(id)
                if depth[id] == nil { depth[id] = 0 }
                for target in outEdges[id] ?? [] where !processed.contains(target) {
                    depth[target] = max(depth[target] ?? 0, (depth[id] ?? 0) + 1)
                    remaining[target] = max((remaining[target] ?? 1) - 1, 0)
                }
            }
        }
        return depth
    }
}
