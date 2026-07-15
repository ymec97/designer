import Foundation
import DesignerModel

/// The LLM-facing shape of a board: name-addressed, positions optional,
/// well-known edge properties promoted to top-level keys. Distinct from the
/// on-disk schema, which is UUID-addressed and lossless.
struct WireBoard: Codable {
    var format: String?
    var version: Int?
    var title: String?
    var layers: [WireLayer]?
    var nodes: [WireNode]
    var edges: [WireEdge]
    var notes: [WireNote]?
    var flows: [WireFlow]?

    /// Source element ids parallel to `nodes`/`edges` (set by `init(from:)`
    /// only; not serialized). Lets the diff map wire keys back to elements.
    var nodeSourceIDs: [ElementID] = []
    var edgeSourceIDs: [ElementID] = []

    enum CodingKeys: String, CodingKey {
        case format, version, title, layers, nodes, edges, notes, flows
    }

    /// Layers are addressed by NAME in the wire format. The first layer is
    /// the base; elements that omit `layers` land there.
    struct WireLayer: Codable {
        var name: String
        var tint: String?
        var hidden: Bool?
    }

    struct WireNode: Codable {
        var id: String
        var kind: String?
        var name: String?
        var shape: String?
        var orientation: String?
        var at: [Double]?
        var size: [Double]?
        /// Layer names this node appears on (multi-membership). Omitted =
        /// the base layer.
        var layers: [String]?
    }

    struct WireEdge: Codable {
        var from: String
        var to: String
        var label: String?
        var direction: String?
        var `protocol`: String?
        var data: String?
        var condition: String?
        var props: [String: String]?
        var layers: [String]?
    }

    struct WireNote: Codable {
        var text: String
        var at: [Double]?
        var size: [Double]?
    }

    /// A recorded traffic journey. `steps` is ordered; each step is the hops
    /// that fire TOGETHER (usually one; several = a fan-out). A hop names the
    /// connector it travels by endpoints, with `via` (matching the edge's
    /// label or protocol) to pick among parallel connectors.
    struct WireFlow: Codable {
        var name: String
        var source: String
        var steps: [[WireHop]]
    }

    struct WireHop: Codable {
        var from: String
        var to: String
        var via: String?
    }
}

// MARK: - Board → Wire

extension WireBoard {
    init(from board: Board) {
        format = LLMInterchange.formatName
        version = LLMInterchange.formatVersion
        title = board.title

        // Layers by name (only when the board actually uses them).
        let baseLayerID = board.layers.first?.id
        let layerName = Dictionary(board.layers.map { ($0.id, $0.name) },
                                   uniquingKeysWith: { first, _ in first })
        let usesLayers = board.layers.count > 1
        if usesLayers {
            layers = board.layers.map { layer in
                WireLayer(name: layer.name, tint: layer.colorTint,
                          hidden: layer.isVisible ? nil : true)
            }
        }
        func membership(of element: Element) -> [String]? {
            guard usesLayers else { return nil }
            let names = element.layerIDs.compactMap { layerName[$0] }.sorted()
            if names.isEmpty { return nil }
            if let baseLayerID, element.layerIDs == [baseLayerID] { return nil }
            return names
        }

        // Assign readable, unique slug ids to nodes.
        var idForElement: [ElementID: String] = [:]
        var usedSlugs: Set<String> = []
        var wireNodes: [WireNode] = []
        for element in board.elementsInZOrder {
            guard let node = element.node else { continue }
            let base = Self.slug(node.semantic.name.isEmpty ? node.semantic.kind.rawValue : node.semantic.name)
            let slug = Self.unique(base.isEmpty ? "node" : base, in: &usedSlugs)
            idForElement[element.id] = slug
            nodeSourceIDs.append(element.id)
            wireNodes.append(WireNode(
                id: slug,
                kind: node.semantic.kind == .generic ? nil : node.semantic.kind.rawValue,
                name: node.semantic.name.isEmpty ? nil : node.semantic.name,
                shape: node.shape == .rectangle ? nil : node.shape.rawValue,
                orientation: (node.shape == .triangle && node.orientation != .up) ? node.orientation.rawValue : nil,
                at: [Self.round(node.frame.x), Self.round(node.frame.y)],
                size: [Self.round(node.frame.width), Self.round(node.frame.height)],
                layers: membership(of: element)
            ))
        }
        nodes = wireNodes

        var wireEdges: [WireEdge] = []
        var wireEdgeSources: [ElementID] = []
        var edgeSlugPair: [ElementID: (from: String, to: String, via: String?)] = [:]
        for element in board.elementsInZOrder {
            guard let edge = element.edge,
                  let fromID = edge.from.elementID, let from = idForElement[fromID],
                  let toID = edge.to.elementID, let to = idForElement[toID] else { continue }
            wireEdgeSources.append(element.id)
            var props = edge.semantic.properties
            let proto = props.removeValue(forKey: WellKnownEdgeProperty.protocolKey)
            let data = props.removeValue(forKey: WellKnownEdgeProperty.data)
            let condition = props.removeValue(forKey: WellKnownEdgeProperty.condition)
            edgeSlugPair[element.id] = (from, to, edge.semantic.label ?? proto)
            wireEdges.append(WireEdge(
                from: from, to: to,
                label: edge.semantic.label,
                direction: edge.semantic.direction == .forward ? nil : edge.semantic.direction.rawValue,
                protocol: proto, data: data, condition: condition,
                props: props.isEmpty ? nil : props,
                layers: membership(of: element)
            ))
        }
        edges = wireEdges
        edgeSourceIDs = wireEdgeSources

        // Flows: steps of hops addressed by node slugs (+ via to pick among
        // parallel connectors). Stale references are silently dropped.
        let wireFlows: [WireFlow] = board.flows.compactMap { flow in
            guard let source = idForElement[flow.source] else { return nil }
            let steps: [[WireHop]] = flow.steps.compactMap { step in
                let hops = step.edges.compactMap { edgeID -> WireHop? in
                    guard let pair = edgeSlugPair[edgeID] else { return nil }
                    return WireHop(from: pair.from, to: pair.to, via: pair.via)
                }
                return hops.isEmpty ? nil : hops
            }
            guard !steps.isEmpty else { return nil }
            return WireFlow(name: flow.name, source: source, steps: steps)
        }
        flows = wireFlows.isEmpty ? nil : wireFlows

        let noteElements = board.elementsInZOrder.compactMap { element -> WireNote? in
            guard case .note(let note) = element.content else { return nil }
            return WireNote(
                text: note.text,
                at: [Self.round(note.frame.x), Self.round(note.frame.y)],
                size: [Self.round(note.frame.width), Self.round(note.frame.height)]
            )
        }
        notes = noteElements.isEmpty ? nil : noteElements
    }
}

// MARK: - Wire → Board

extension WireBoard {
    func toBoard() -> LLMInterchange.ParseResult {
        var board = Board(title: title ?? "Imported")
        var warnings: [String] = []

        // Layers: the first wire layer becomes the base; the rest append in
        // order. Element `layers` referencing an undeclared name creates it
        // implicitly (visible, untinted) with a warning.
        var layerIDByName: [String: LayerID] = [:]
        if let wireLayers = layers, let first = wireLayers.first {
            board.layers[0].name = first.name
            board.layers[0].colorTint = first.tint
            board.layers[0].isVisible = first.hidden != true
            layerIDByName[first.name] = board.layers[0].id
            for wireLayer in wireLayers.dropFirst() {
                guard layerIDByName[wireLayer.name] == nil else {
                    warnings.append("duplicate layer '\(wireLayer.name)' — keeping the first")
                    continue
                }
                let newLayer = Layer(name: wireLayer.name, colorTint: wireLayer.tint,
                                     isVisible: wireLayer.hidden != true)
                try? board.apply(.insertLayer(newLayer, at: board.layers.count))
                layerIDByName[wireLayer.name] = newLayer.id
            }
        } else {
            layerIDByName[board.layers[0].name] = board.layers[0].id
        }
        let layer = board.layers[0].id
        func resolveLayers(_ names: [String]?) -> Set<LayerID> {
            guard let names, !names.isEmpty else { return [layer] }
            var ids: Set<LayerID> = []
            for name in names {
                if let id = layerIDByName[name] {
                    ids.insert(id)
                } else {
                    let implicit = Layer(name: name)
                    try? board.apply(.insertLayer(implicit, at: board.layers.count))
                    layerIDByName[name] = implicit.id
                    ids.insert(implicit.id)
                    warnings.append("layer '\(name)' was not declared — created it")
                }
            }
            return ids.isEmpty ? [layer] : ids
        }

        // Nodes that omit positions get auto-laid-out left→right by data-flow
        // depth (so an agent-built system reads like an architecture diagram,
        // not a grid). Falls back to a grid when there are no edges to infer
        // flow from.
        let autoFrames = Self.autoLayoutFrames(nodes: nodes, edges: edges)

        var elementForSlug: [String: ElementID] = [:]
        for wireNode in nodes {
            let frame: Rect
            if let at = wireNode.at, at.count == 2, let size = wireNode.size, size.count == 2 {
                frame = Rect(x: at[0], y: at[1], width: max(size[0], 24), height: max(size[1], 24))
            } else {
                frame = autoFrames[wireNode.id] ?? Rect(x: 80, y: 80, width: 160, height: 80)
            }
            // A missing name falls back to the id slug — an agent that only
            // sets `id` must still produce labeled, recognizable blocks.
            let name = (wireNode.name?.isEmpty == false) ? wireNode.name! : wireNode.id
            let element = Element(
                layerIDs: resolveLayers(wireNode.layers),
                sortKey: board.topSortKey,
                content: .node(Node(
                    semantic: NodeSemantic(
                        kind: wireNode.kind.map(NodeKind.init(rawValue:)) ?? .generic,
                        name: name
                    ),
                    frame: frame,
                    shape: wireNode.shape.map(NodeShape.init(rawValue:)) ?? .rectangle,
                    orientation: wireNode.orientation.map(ShapeOrientation.init(rawValue:)) ?? .up
                ))
            )
            if elementForSlug[wireNode.id] != nil {
                warnings.append("duplicate node id '\(wireNode.id)' — keeping the first")
            } else {
                elementForSlug[wireNode.id] = element.id
                try? board.apply(.insertElement(element))
            }
        }

        for wireEdge in edges {
            guard let from = elementForSlug[wireEdge.from] else {
                warnings.append("edge skipped: unknown 'from' node '\(wireEdge.from)'")
                continue
            }
            guard let to = elementForSlug[wireEdge.to] else {
                warnings.append("edge skipped: unknown 'to' node '\(wireEdge.to)'")
                continue
            }
            var properties: [String: String] = wireEdge.props ?? [:]
            if let proto = wireEdge.protocol { properties[WellKnownEdgeProperty.protocolKey] = proto }
            if let data = wireEdge.data { properties[WellKnownEdgeProperty.data] = data }
            if let condition = wireEdge.condition { properties[WellKnownEdgeProperty.condition] = condition }
            let element = Element(
                layerIDs: resolveLayers(wireEdge.layers),
                sortKey: board.topSortKey,
                content: .edge(Edge(
                    semantic: EdgeSemantic(
                        label: wireEdge.label,
                        direction: wireEdge.direction.map(EdgeDirection.init(rawValue:)) ?? .forward,
                        properties: properties
                    ),
                    from: .element(from, side: nil, offset: nil),
                    to: .element(to, side: nil, offset: nil)
                ))
            )
            try? board.apply(.insertElement(element))
        }

        for wireNote in notes ?? [] {
            let frame: Rect
            if let at = wireNote.at, at.count == 2, let size = wireNote.size, size.count == 2 {
                frame = Rect(x: at[0], y: at[1], width: size[0], height: size[1])
            } else {
                frame = Rect(x: 80, y: 80, width: 200, height: 60)
            }
            let element = Element(
                layerIDs: [layer],
                sortKey: board.topSortKey,
                content: .note(Note(text: wireNote.text, frame: frame))
            )
            try? board.apply(.insertElement(element))
        }

        // Flows: resolve each hop to a connector. Endpoint pair first, then
        // `via` (label or protocol) picks among parallels; ambiguity takes
        // the first match with a warning.
        var edgesByPair: [String: [(id: ElementID, label: String?, proto: String?)]] = [:]
        for element in board.elements.values {
            guard let edge = element.edge,
                  let fromID = edge.from.elementID, let toID = edge.to.elementID else { continue }
            let fromSlug = elementForSlug.first(where: { $0.value == fromID })?.key
            let toSlug = elementForSlug.first(where: { $0.value == toID })?.key
            guard let fromSlug, let toSlug else { continue }
            edgesByPair["\(fromSlug)|\(toSlug)", default: []].append(
                (element.id, edge.semantic.label, edge.semantic.properties[WellKnownEdgeProperty.protocolKey]))
        }
        for (index, wireFlow) in (flows ?? []).enumerated() {
            guard let source = elementForSlug[wireFlow.source] else {
                warnings.append("flow '\(wireFlow.name)' skipped: unknown source '\(wireFlow.source)'")
                continue
            }
            var steps: [Flow.Step] = []
            for wireStep in wireFlow.steps {
                var stepEdges: [ElementID] = []
                var stepNodes: [ElementID] = []
                for hop in wireStep {
                    let candidates = (edgesByPair["\(hop.from)|\(hop.to)"] ?? [])
                        + (edgesByPair["\(hop.to)|\(hop.from)"] ?? [])
                    let matches = hop.via == nil
                        ? candidates
                        : candidates.filter { $0.label == hop.via || $0.proto == hop.via }
                    guard let chosen = matches.first ?? candidates.first else {
                        warnings.append("flow '\(wireFlow.name)': no connector \(hop.from)->\(hop.to) — hop skipped")
                        continue
                    }
                    if matches.count > 1 {
                        warnings.append("flow '\(wireFlow.name)': several connectors match \(hop.from)->\(hop.to) — set 'via' to a label; using the first")
                    }
                    stepEdges.append(chosen.id)
                    if let target = elementForSlug[hop.to] { stepNodes.append(target) }
                }
                if !stepEdges.isEmpty { steps.append(Flow.Step(edges: stepEdges, nodes: stepNodes)) }
            }
            guard !steps.isEmpty else {
                warnings.append("flow '\(wireFlow.name)' skipped: no resolvable steps")
                continue
            }
            try? board.apply(.insertFlow(
                Flow(name: wireFlow.name, source: source, steps: steps, colorIndex: index % 6),
                at: board.flows.count
            ))
        }

        return LLMInterchange.ParseResult(board: board, warnings: warnings, providedTitle: title)
    }

    /// Frames for nodes that omit `at`/`size`. With edges present: longest-path
    /// layering (left→right columns by flow depth, cycle-bounded), stacking
    /// rows within a column. Without edges: a simple grid.
    static func autoLayoutFrames(nodes: [WireNode], edges: [WireEdge]) -> [String: Rect] {
        let needing = nodes.filter { !($0.at?.count == 2 && $0.size?.count == 2) }
        guard !needing.isEmpty else { return [:] }
        var frames: [String: Rect] = [:]

        guard !edges.isEmpty else {
            for (index, node) in needing.enumerated() {
                frames[node.id] = Rect(
                    x: 80 + Double(index % 6) * 200,
                    y: 80 + Double(index / 6) * 140,
                    width: 160, height: 80
                )
            }
            return frames
        }

        // Longest-path depth from sources; the pass/increment bounds make
        // cycles terminate with sensible depths.
        var depth = Dictionary(nodes.map { ($0.id, 0) }, uniquingKeysWith: { first, _ in first })
        let bound = nodes.count
        var changed = true
        var passes = 0
        while changed, passes < bound {
            changed = false
            passes += 1
            for edge in edges {
                guard let from = depth[edge.from], let to = depth[edge.to],
                      from + 1 > to, from + 1 < bound else { continue }
                depth[edge.to] = from + 1
                changed = true
            }
        }

        var rowInColumn: [Int: Int] = [:]
        for node in needing {
            let column = depth[node.id] ?? 0
            let row = rowInColumn[column, default: 0]
            rowInColumn[column] = row + 1
            frames[node.id] = Rect(
                x: 80 + Double(column) * 260,
                y: 80 + Double(row) * 140,
                width: 160, height: 80
            )
        }
        return frames
    }
}

// MARK: - Slug helpers

extension WireBoard {
    static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        var result = ""
        var lastDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash, !result.isEmpty {
                result.append("-")
                lastDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }

    static func unique(_ base: String, in used: inout Set<String>) -> String {
        if used.insert(base).inserted { return base }
        var index = 2
        while !used.insert("\(base)-\(index)").inserted { index += 1 }
        return "\(base)-\(index)"
    }

    /// Positions are rounded to whole points so LLM edits and diffs stay clean.
    static func round(_ value: Double) -> Double { value.rounded() }
}
