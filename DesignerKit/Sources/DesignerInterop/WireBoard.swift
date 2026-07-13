import Foundation
import DesignerModel

/// The LLM-facing shape of a board: name-addressed, positions optional,
/// well-known edge properties promoted to top-level keys. Distinct from the
/// on-disk schema, which is UUID-addressed and lossless.
struct WireBoard: Codable {
    var format: String?
    var version: Int?
    var title: String?
    var nodes: [WireNode]
    var edges: [WireEdge]
    var notes: [WireNote]?

    struct WireNode: Codable {
        var id: String
        var kind: String?
        var name: String?
        var shape: String?
        var orientation: String?
        var at: [Double]?
        var size: [Double]?
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
    }

    struct WireNote: Codable {
        var text: String
        var at: [Double]?
        var size: [Double]?
    }
}

// MARK: - Board → Wire

extension WireBoard {
    init(from board: Board) {
        format = LLMInterchange.formatName
        version = LLMInterchange.formatVersion
        title = board.title

        // Assign readable, unique slug ids to nodes.
        var idForElement: [ElementID: String] = [:]
        var usedSlugs: Set<String> = []
        var wireNodes: [WireNode] = []
        for element in board.elementsInZOrder {
            guard let node = element.node else { continue }
            let base = Self.slug(node.semantic.name.isEmpty ? node.semantic.kind.rawValue : node.semantic.name)
            let slug = Self.unique(base.isEmpty ? "node" : base, in: &usedSlugs)
            idForElement[element.id] = slug
            wireNodes.append(WireNode(
                id: slug,
                kind: node.semantic.kind == .generic ? nil : node.semantic.kind.rawValue,
                name: node.semantic.name.isEmpty ? nil : node.semantic.name,
                shape: node.shape == .rectangle ? nil : node.shape.rawValue,
                orientation: (node.shape == .triangle && node.orientation != .up) ? node.orientation.rawValue : nil,
                at: [Self.round(node.frame.x), Self.round(node.frame.y)],
                size: [Self.round(node.frame.width), Self.round(node.frame.height)]
            ))
        }
        nodes = wireNodes

        edges = board.elementsInZOrder.compactMap { element in
            guard let edge = element.edge,
                  let fromID = edge.from.elementID, let from = idForElement[fromID],
                  let toID = edge.to.elementID, let to = idForElement[toID] else { return nil }
            var props = edge.semantic.properties
            let proto = props.removeValue(forKey: WellKnownEdgeProperty.protocolKey)
            let data = props.removeValue(forKey: WellKnownEdgeProperty.data)
            let condition = props.removeValue(forKey: WellKnownEdgeProperty.condition)
            return WireEdge(
                from: from, to: to,
                label: edge.semantic.label,
                direction: edge.semantic.direction == .forward ? nil : edge.semantic.direction.rawValue,
                protocol: proto, data: data, condition: condition,
                props: props.isEmpty ? nil : props
            )
        }

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
        let layer = board.layers[0].id
        var warnings: [String] = []

        // Node ids → new element ids; auto-place nodes that omit positions.
        var elementForSlug: [String: ElementID] = [:]
        var autoIndex = 0
        for wireNode in nodes {
            let frame: Rect
            if let at = wireNode.at, at.count == 2, let size = wireNode.size, size.count == 2 {
                frame = Rect(x: at[0], y: at[1], width: max(size[0], 24), height: max(size[1], 24))
            } else {
                frame = Rect(
                    x: 80 + Double(autoIndex % 6) * 200,
                    y: 80 + Double(autoIndex / 6) * 140,
                    width: 160, height: 80
                )
                autoIndex += 1
            }
            let element = Element(
                layerIDs: [layer],
                sortKey: board.topSortKey,
                content: .node(Node(
                    semantic: NodeSemantic(
                        kind: wireNode.kind.map(NodeKind.init(rawValue:)) ?? .generic,
                        name: wireNode.name ?? ""
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
                layerIDs: [layer],
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

        return LLMInterchange.ParseResult(board: board, warnings: warnings)
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
