import Foundation
import DesignerModel
import DesignerInterop

/// A minimal Model Context Protocol server (JSON-RPC 2.0). Handles `initialize`,
/// `tools/list`, and `tools/call` for a small, coarse tool set that lets an
/// agent read the open board and *propose* edits (which the user approves in
/// the app — nothing here mutates the document directly).
///
/// Kept transport-agnostic and pure so it's unit-testable by feeding raw
/// JSON-RPC bytes; `AgentServer` wraps it in a localhost HTTP listener.
public final class MCPHandler {
    public weak var bridge: AgentBoardBridge?
    public static let protocolVersion = "2025-06-18"
    public static let serverName = "Designer"

    public init(bridge: AgentBoardBridge? = nil) {
        self.bridge = bridge
    }

    /// Handle one JSON-RPC message. Returns response bytes, or nil for a
    /// notification (which gets no reply).
    public func handle(_ data: Data) -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(errorResponse(id: nil, code: -32700, message: "Parse error"))
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return encode(errorResponse(id: id, code: -32600, message: "Invalid Request"))
        }
        let params = message["params"] as? [String: Any] ?? [:]

        // Notifications (no id) get no reply.
        if id == nil, method.hasPrefix("notifications/") { return nil }

        switch method {
        case "initialize":
            // Echo the client's requested version — our tools-only surface is
            // identical across MCP revisions, so don't force a disconnect.
            let requested = params["protocolVersion"] as? String
            return encode(result(id: id, [
                "protocolVersion": (requested?.isEmpty == false) ? requested! : Self.protocolVersion,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": Self.serverName, "version": "1"],
                // Clients inject this into the agent's context: how to author
                // boards well and what the app can do.
                "instructions": AgentGuide.text,
            ]))
        case "ping":
            return encode(result(id: id, [:]))
        case "tools/list":
            return encode(result(id: id, ["tools": Self.toolDefinitions]))
        case "tools/call":
            return encode(callTool(id: id, params: params))
        default:
            return encode(errorResponse(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    // MARK: Tool dispatch

    private func callTool(id: Any?, params: [String: Any]) -> [String: Any] {
        guard let name = params["name"] as? String else {
            return errorResponse(id: id, code: -32602, message: "Missing tool name")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        switch name {
        case "get_guide": return toolResult(id: id, .text(AgentGuide.text))
        case "describe_board": return toolResult(id: id, describeBoard())
        case "get_board": return toolResult(id: id, getBoard())
        case "search_board": return toolResult(id: id, searchBoard(query: arguments["query"] as? String ?? ""))
        case "propose_board":
            return toolResult(id: id, proposeBoard(
                text: arguments["board"] as? String ?? "",
                note: arguments["note"] as? String
            ))
        default:
            return errorResponse(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
    }

    private func describeBoard() -> ToolOutcome {
        guard let board = bridge?.currentBoard() else { return .error(Self.noBoardMessage) }
        let nodes = board.elements.values.compactMap { $0.node }
        let edges = board.elements.values.compactMap { $0.edge }
        var lines = ["Board \"\(board.title)\": \(nodes.count) blocks, \(edges.count) connectors, \(board.layers.count) layers."]
        if !nodes.isEmpty {
            lines.append("Blocks: " + nodes.map { node in
                let kind = node.semantic.kind == .generic ? "" : " (\(node.semantic.kind.rawValue))"
                return "\(node.semantic.name.isEmpty ? "untitled" : node.semantic.name)\(kind)"
            }.joined(separator: ", "))
        }
        if bridge?.hasPendingProposal() == true {
            lines.append("A previous proposal is still awaiting the user's Accept/Reject in Designer.")
        }
        lines.append("Call get_board for the full editable representation.")
        return .text(lines.joined(separator: "\n"))
    }

    private func getBoard() -> ToolOutcome {
        guard let board = bridge?.currentBoard() else { return .error(Self.noBoardMessage) }
        return .text(LLMInterchange.export(board))
    }

    private func searchBoard(query: String) -> ToolOutcome {
        guard let board = bridge?.currentBoard() else { return .error(Self.noBoardMessage) }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return .error("Provide a non-empty 'query'.") }
        var hits: [String] = []
        for element in board.elementsInZOrder {
            if let node = element.node {
                if node.semantic.name.lowercased().contains(q) || node.semantic.kind.rawValue.contains(q) {
                    hits.append("block: \(node.semantic.name.isEmpty ? "untitled" : node.semantic.name) [\(node.semantic.kind.rawValue)]")
                }
            } else if let edge = element.edge {
                let hay = ([edge.semantic.label ?? ""] + edge.semantic.properties.values).joined(separator: " ").lowercased()
                if hay.contains(q) { hits.append("connector: \(edge.semantic.label ?? "(unlabeled)")") }
            }
        }
        return .text(hits.isEmpty ? "No matches for \"\(query)\"." : hits.joined(separator: "\n"))
    }

    private func proposeBoard(text: String, note: String?) -> ToolOutcome {
        guard let bridge, let current = bridge.currentBoard() else { return .error(Self.noBoardMessage) }
        let parsed: LLMInterchange.ParseResult
        do {
            parsed = try LLMInterchange.parse(text)
        } catch {
            return .error("Couldn't parse the proposed board: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
        var proposed = parsed.board
        // A proposal that omits the title keeps the board's name; only an
        // explicit title in the JSON counts as a rename (and shows in the diff).
        if parsed.providedTitle == nil {
            proposed.title = current.title
        }
        let replacesPending = bridge.hasPendingProposal()
        let diff = bridge.stageProposal(proposed, note: note)
        if diff.isEmpty {
            return .text("The proposed board is identical to the current one — nothing to review.")
        }
        var lines = ["Proposal staged for review in Designer: \(diff.summaryLine)."]
        if replacesPending {
            lines.append("(This replaces your earlier proposal, which was still pending.)")
        }
        let currentBlocks = current.elements.values.filter { $0.node != nil }.count
        if currentBlocks >= 3, diff.removedNodes.count * 2 >= currentBlocks {
            lines.append("")
            lines.append("""
            ⚠️ This proposal removes \(diff.removedNodes.count) of the \(currentBlocks) existing blocks. \
            propose_board replaces the ENTIRE diagram — if you meant to add or edit, start from the \
            latest get_board output and include every element you want to keep.
            """)
        }
        lines.append("")
        lines.append(diff.detail)
        // Spatial feedback: agents can't see the canvas, so the tool result
        // reports how the proposal actually LAYS OUT — and what to fix.
        lines.append("")
        lines.append(contentsOf: Self.layoutReport(for: proposed))
        if !parsed.warnings.isEmpty {
            lines.append("")
            lines.append("Warnings: " + parsed.warnings.joined(separator: "; "))
        }
        lines.append("")
        lines.append("The user will Accept or Reject this in the app; it has not been applied yet. Call get_board afterwards to see what they decided before proposing further changes.")
        return .text(lines.joined(separator: "\n"))
    }

    private static let noBoardMessage = "No board is open in Designer right now."

    /// Extent, connector stretch, and crowding metrics for a proposed board,
    /// with actionable warnings — the agent's only view of the geometry.
    static func layoutReport(for board: Board) -> [String] {
        let frames = board.elements.values.compactMap(\.node?.frame)
        guard frames.count >= 2 else { return [] }
        let minX = frames.map(\.x).min() ?? 0
        let maxX = frames.map(\.maxX).max() ?? 0
        let minY = frames.map(\.y).min() ?? 0
        let maxY = frames.map(\.maxY).max() ?? 0
        let width = maxX - minX, height = maxY - minY

        var lengths: [Double] = []
        for element in board.elements.values {
            guard let edge = element.edge,
                  let from = edge.from.elementID.flatMap({ board.elements[$0]?.node?.frame }),
                  let to = edge.to.elementID.flatMap({ board.elements[$0]?.node?.frame }) else { continue }
            lengths.append(hypot(from.midX - to.midX, from.midY - to.midY))
        }
        let averageLength = lengths.isEmpty ? 0 : lengths.reduce(0, +) / Double(lengths.count)

        var minGap = Double.infinity
        if frames.count <= 150 {
            for i in 0..<frames.count {
                for j in (i + 1)..<frames.count {
                    let a = frames[i], b = frames[j]
                    let dx = max(max(a.x - b.maxX, b.x - a.maxX), 0)
                    let dy = max(max(a.y - b.maxY, b.y - a.maxY), 0)
                    minGap = min(minGap, max(dx, dy))
                }
            }
        }

        var lines = [String(format: "Layout: %d blocks spanning %.0f × %.0f pt; average connector length %.0f pt.",
                            frames.count, width, height, averageLength)]
        // ~3–4 screens is the outer comfort zone (screen ≈ 1450×900).
        if width > 5800 || height > 3600 {
            lines.append("⚠️ The board is very spread out — a reader would pan for days. Tighten the layout: related blocks adjacent, ~120pt gaps, or omit at/size and let Designer lay it out.")
        }
        if minGap.isFinite, minGap < 60 {
            lines.append(String(format: "⚠️ Some blocks are only %.0f pt apart — connector labels have no room. Leave at least 120 pt between blocks.", minGap))
        }
        if averageLength > 900, lengths.count >= 5 {
            lines.append("⚠️ Connectors are long on average — logically related blocks should sit near each other.")
        }
        return lines
    }

    // MARK: Tool result / JSON-RPC envelope helpers

    private enum ToolOutcome {
        case text(String)
        case error(String)
    }

    private func toolResult(id: Any?, _ outcome: ToolOutcome) -> [String: Any] {
        let text: String
        var isError = false
        switch outcome {
        case .text(let t): text = t
        case .error(let t): text = t; isError = true
        }
        return result(id: id, [
            "content": [["type": "text", "text": text]],
            "isError": isError,
        ])
    }

    private func result(id: Any?, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value]
    }

    private func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    // MARK: Tool schemas

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "get_guide",
            "description": "Read Designer's authoring guide: node kinds and shape conventions, connector labeling (protocol/data/condition), the propose workflow, and the app features (layers, flows, simulation) you can explain to the user. Read this before your first edit.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "describe_board",
            "description": "Summarize the software-architecture diagram currently open in Designer: its blocks (components), connectors, and layers.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "get_board",
            "description": "Return the full open board as an editable, name-addressed JSON document. Edit this and send it to propose_board to suggest changes.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "search_board",
            "description": "Find blocks and connectors in the open board whose name, kind, label, or properties match a query.",
            "inputSchema": [
                "type": "object",
                "properties": ["query": ["type": "string", "description": "Text to search for."]],
                "required": ["query"],
            ],
        ],
        [
            "name": "propose_board",
            "description": "Propose an edited version of the board. IMPORTANT: send the COMPLETE board in the get_board JSON format (start from the latest get_board output and modify it) — the proposal replaces the entire diagram, so any element you omit is treated as a deletion. Keep existing nodes' at/size so the layout is preserved; omit at/size only for NEW nodes to have them auto-placed. Designer shows the user a diff to Accept or Reject; nothing is applied automatically.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "board": ["type": "string", "description": "The full edited board document (get_board format)."],
                    "note": ["type": "string", "description": "Optional one-line summary of what you changed and why."],
                ],
                "required": ["board"],
            ],
        ],
    ]
}
