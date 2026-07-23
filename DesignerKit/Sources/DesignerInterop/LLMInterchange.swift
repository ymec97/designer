import Foundation
import DesignerModel

/// LLM text interchange (D16, phase 1): a canonical, human- and LLM-legible
/// representation of a board that any chat model can read, analyze, and edit,
/// then be pasted back. Nodes are addressed by readable slug ids (derived
/// from names) rather than UUIDs, so a model can reliably talk about "the edge
/// from api-gateway to orders-db".
public enum LLMInterchange {
    public static let formatName = "designer-board"
    public static let formatVersion = 1

    // MARK: Export

    /// A primer paragraph followed by the board as pretty JSON. `selection`,
    /// if given, exports only those elements (as a self-contained clip).
    public static func export(_ board: Board, selection: Set<ElementID>? = nil) -> String {
        let source: Board
        if let selection, !selection.isEmpty {
            source = board.makeClip(of: selection, title: board.title)
        } else {
            source = board
        }
        let wire = WireBoard(from: source)
        let data = (try? Self.encoder.encode(wire)) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return primer + "\n\n" + json + "\n"
    }

    static let primer = """
    # Designer board (\(formatName) v\(formatVersion))
    # This JSON describes a software-architecture diagram. Edit it and paste it
    # back into Designer to apply changes.
    # - nodes: components. `id` is a stable slug you reference from edges.
    #   ALWAYS set a human-readable `name` and a `kind` ∈ service|database|
    #   queue|cache|gateway|client|external|generic (kind drives the tint).
    #   `shape` ∈ rectangle|ellipse|diamond|triangle — convention: ellipse for
    #   databases/data stores, diamond for decision points, triangle for
    #   alerts, rectangle otherwise. `at` = [x, y] top-left, `size` =
    #   [width, height] in points. Optional appearance: `fill`/`stroke` (hex
    #   "#RRGGBB[AA]" or "none" for no background), `opacity` (0-1) — set these
    #   to recolor a block instead of changing `kind`. PREFER omitting `at`/`size`: Designer then
    #   lays the board out like a human would (entry points left, flow
    #   left-to-right, related blocks adjacent, externals at the edge,
    #   compact). Keep names SHORT (2-4 words; details go in props/notes).
    # - layout (optional, top level): flow direction — "left-right"
    #   (default) | "right-left" | "top-down".
    # - edges: connections. `from`/`to` are node ids. ALWAYS set `label`
    #   (what happens) and `protocol` (HTTPS, gRPC, SQL, Kafka…). `direction` ∈
    #   forward|backward|both|none. `data`, `condition` describe the payload
    #   and when it fires; any other key/value goes under `props`.
    # - notes: free-text annotations with `at` and `size`.
    # - layers (optional): objects with `name`, `tint`, `hidden` — views over
    #   the same elements. First layer = base. Elements pick layers by NAME
    #   via their own `layers` array (omitted = base). Use for progressive
    #   disclosure: a simple "Overview" base, then one layer per concern.
    # - flows (optional): recorded journeys played as animated packets. Each
    #   has `name`, `source` (node id), and `steps`: an ordered array where
    #   each step is an array of hops firing together; a hop has `from`,
    #   `to`, and `via` (a connector's label/protocol, to pick among
    #   parallel connectors).
    # Add, remove, relabel, and reconnect freely; keep ids unique.
    """

    // MARK: Import

    public struct ParseResult {
        public let board: Board
        /// Non-fatal issues (e.g. an edge referencing an unknown node id).
        public let warnings: [String]
        /// The title as given in the JSON, or nil if the document omitted it
        /// (so callers can inherit an existing title instead of "Imported").
        public let providedTitle: String?
    }

    public enum ImportError: Error, LocalizedError, Equatable {
        case noJSONObject
        case invalidJSON(String)
        case wrongFormat(String)

        public var errorDescription: String? {
            switch self {
            case .noJSONObject:
                return "Couldn't find a JSON object in the pasted text."
            case .invalidJSON(let detail):
                return "The board JSON is invalid: \(detail)"
            case .wrongFormat(let detail):
                return "This doesn't look like a Designer board: \(detail)"
            }
        }
    }

    /// Parses pasted text (which may contain surrounding prose or ``` fences)
    /// into a board. Tolerant of missing positions and unknown edge endpoints.
    public static func parse(_ text: String) throws -> ParseResult {
        try parse(text, anchoredTo: nil)
    }

    /// Parse for PROPOSALS: nodes matching a block on `current` (by wire id
    /// or slugged name) that omit positions inherit that block's frame, so
    /// an agent edit lands ON the existing graph instead of rebuilding it
    /// far away; only genuinely new nodes are auto-placed.
    public static func parse(_ text: String, anchoredTo current: Board?) throws -> ParseResult {
        guard let jsonString = extractJSONObject(from: text) else {
            throw ImportError.noJSONObject
        }
        var wire: WireBoard
        do {
            wire = try decoder.decode(WireBoard.self, from: Data(jsonString.utf8))
        } catch let error as DecodingError {
            throw ImportError.invalidJSON(Self.describe(error))
        } catch {
            throw ImportError.invalidJSON((error as NSError).localizedDescription)
        }
        guard wire.format == nil || wire.format == formatName else {
            throw ImportError.wrongFormat("format is '\(wire.format ?? "")'")
        }
        if let current {
            wire.anchorPositions(to: current)
        }
        var result = wire.toBoard()
        if let current {
            // The wire carries fill/stroke/opacity but NOT strokeWidth/image,
            // so a matched block MERGES: start from the current style, then
            // let the agent's explicit fill/stroke/opacity win. Fields the
            // agent left unset keep the current look (and image survives).
            result = ParseResult(
                board: inheritingStyles(result.board, from: current),
                warnings: result.warnings,
                providedTitle: result.providedTitle
            )
        }
        return result
    }

    /// Blocks matching a current block by slugged name keep the current
    /// block's style for fields the wire can't express (strokeWidth, image),
    /// while the agent's explicit fill/stroke/opacity override.
    private static func inheritingStyles(_ board: Board, from current: Board) -> Board {
        var styleForSlug: [String: Style] = [:]
        var extraForSlug: [String: [String: JSONValue]] = [:]
        for element in current.elementsInZOrder {
            guard let node = element.node else { continue }
            let key = WireBoard.slug(node.semantic.name.isEmpty
                                     ? node.semantic.kind.rawValue : node.semantic.name)
            guard !key.isEmpty else { continue }
            if styleForSlug[key] == nil { styleForSlug[key] = node.style }
            if extraForSlug[key] == nil, !node.semantic.extra.isEmpty {
                extraForSlug[key] = node.semantic.extra
            }
        }
        guard !styleForSlug.isEmpty || !extraForSlug.isEmpty else { return board }

        var updated = board
        for element in board.elements.values {
            guard var node = element.node else { continue }
            let key = WireBoard.slug(node.semantic.name.isEmpty
                                     ? node.semantic.kind.rawValue : node.semantic.name)
            var changed = false
            if let inherited = styleForSlug[key] {
                var merged = inherited
                // Agent-set appearance (parsed from the wire) wins field by field.
                if node.style.fill != nil { merged.fill = node.style.fill }
                if node.style.stroke != nil { merged.stroke = node.style.stroke }
                if node.style.opacity != nil { merged.opacity = node.style.opacity }
                if merged != node.style { node.style = merged; changed = true }
            }
            // Board links (and any other agent-invisible data) live in
            // NodeSemantic.extra, which never crosses the wire — so a matched
            // node comes back with an empty extra bag. Restore the current
            // node's extra so accepting a proposal can't WIPE a node's board
            // link (the v0.9 no-wipe guarantee). Any agent-set key would win,
            // but the wire carries none today.
            if let inheritedExtra = extraForSlug[key] {
                var mergedExtra = inheritedExtra
                for (k, v) in node.semantic.extra { mergedExtra[k] = v }
                if mergedExtra != node.semantic.extra {
                    node.semantic.extra = mergedExtra
                    changed = true
                }
            }
            guard changed else { continue }
            var replaced = element
            replaced.content = .node(node)
            try? updated.apply(.replaceElement(replaced))
        }
        return updated
    }

    /// Finds the outermost balanced `{ … }` (ignoring braces inside strings),
    /// so prose or Markdown fences around the JSON are tolerated.
    static func extractJSONObject(from text: String) -> String? {
        let chars = Array(text)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for i in start..<chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(chars[start...i]) }
            default: break
            }
        }
        return nil
    }

    // MARK: JSON config (canonical for stable diffs)

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder = JSONDecoder()

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "missing '\(key.stringValue)' at \(path(context))"
        case .typeMismatch(_, let context):
            return "wrong type at \(path(context)): \(context.debugDescription)"
        case .valueNotFound(_, let context):
            return "null at \(path(context))"
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return String(describing: error)
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let joined = context.codingPath.map(\.stringValue).joined(separator: ".")
        return joined.isEmpty ? "(root)" : joined
    }
}
