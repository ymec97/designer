import XCTest
@testable import DesignerAgent
import DesignerModel
import DesignerInterop

private final class StubBridge: AgentBoardBridge {
    var board: Board?
    var stagedProposal: Board?
    var stagedNote: String?

    func currentBoard() -> Board? { board }

    func stageProposal(_ proposed: Board, note: String?) -> BoardDiff {
        stagedProposal = proposed
        stagedNote = note
        return LLMInterchange.diff(current: board ?? Board(title: "empty"), proposed: proposed)
    }
}

final class MCPHandlerTests: XCTestCase {
    private var bridge = StubBridge()
    private var handler = MCPHandler()

    override func setUp() {
        bridge = StubBridge()
        handler = MCPHandler(bridge: bridge)
        bridge.board = try! LLMInterchange.parse(
            "# designer-board\n\n" + #"{"nodes":[{"id":"web","name":"web","kind":"client"},{"id":"api","name":"api","kind":"gateway"}],"edges":[{"from":"web","to":"api","protocol":"HTTPS"}]}"# + "\n"
        ).board
    }

    private func call(_ json: String) -> [String: Any] {
        let out = handler.handle(Data(json.utf8))!
        return try! JSONSerialization.jsonObject(with: out) as! [String: Any]
    }

    private func toolText(_ response: [String: Any]) -> String {
        let result = response["result"] as! [String: Any]
        let content = result["content"] as! [[String: Any]]
        return content.first?["text"] as? String ?? ""
    }

    func testInitialize() {
        let r = call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        let result = r["result"] as! [String: Any]
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "Designer")
        XCTAssertNotNil(result["protocolVersion"])
        let instructions = result["instructions"] as? String ?? ""
        XCTAssertTrue(instructions.contains("propose_board"), "initialize must carry the agent guide")
        XCTAssertTrue(instructions.contains("ellipse"), "guide must include shape conventions")
    }

    func testGuideTool() {
        let text = toolText(call(#"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"get_guide","arguments":{}}}"#))
        XCTAssertTrue(text.contains("Flows"), "guide should cover app features")
        XCTAssertTrue(text.contains("kind"), "guide should cover authoring conventions")
    }

    func testNotificationGetsNoReply() {
        XCTAssertNil(handler.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)))
    }

    func testToolsListHasSixTools() {
        let r = call(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)
        let tools = (r["result"] as! [String: Any])["tools"] as! [[String: Any]]
        XCTAssertEqual(Set(tools.map { $0["name"] as! String }),
                       ["get_guide", "describe_board", "get_board", "search_board",
                        "propose_board", "set_layer_visibility"])
    }

    func testSetLayerVisibilityUnknownLayerErrors() {
        let r = call(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"set_layer_visibility","arguments":{"layer":"Nope","visible":false}}}"#)
        let result = r["result"] as! [String: Any]
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testDescribeBoard() {
        let text = toolText(call(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"describe_board","arguments":{}}}"#))
        XCTAssertTrue(text.contains("2 blocks"))
        XCTAssertTrue(text.contains("1 connectors") || text.contains("1 connector"))
    }

    func testGetBoardRoundTrips() {
        let text = toolText(call(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_board","arguments":{}}}"#))
        XCTAssertTrue(text.contains("web"))
        XCTAssertNoThrow(try LLMInterchange.parse(text))
    }

    func testSearchBoard() {
        let text = toolText(call(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"search_board","arguments":{"query":"gateway"}}}"#))
        XCTAssertTrue(text.contains("api"))
        XCTAssertFalse(text.contains("No matches"))
    }

    func testProposeBoardStagesAndDiffs() {
        // Add a database node + an edge from api to it.
        let proposed = #"{"nodes":[{"id":"web","name":"web","kind":"client"},{"id":"api","name":"api","kind":"gateway"},{"id":"db","name":"db","kind":"database"}],"edges":[{"from":"web","to":"api","protocol":"HTTPS"},{"from":"api","to":"db"}]}"#
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 6, "method": "tools/call",
            "params": ["name": "propose_board", "arguments": ["board": proposed, "note": "add a database"]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: request)
        let r = try! JSONSerialization.jsonObject(with: handler.handle(data)!) as! [String: Any]
        let text = toolText(r)

        XCTAssertNotNil(bridge.stagedProposal, "propose_board must stage, not apply")
        XCTAssertEqual(bridge.stagedNote, "add a database")
        XCTAssertTrue(text.contains("+1 block"), "diff summary should mention the added block")
        XCTAssertTrue(text.contains("not been applied"), "must tell the agent it's pending approval")
    }

    /// The user-reported case: a proposal that resends existing blocks
    /// WITHOUT positions must keep them where they are (reuse, not rebuild),
    /// so the review ghost overlays the current graph.
    func testProposeWithoutPositionsReusesCurrentLayout() {
        // Give the current blocks distinctive positions far from the origin.
        var current = bridge.board!
        for id in current.elements.keys {
            guard var element = current.elements[id], var node = element.node else { continue }
            node.frame = Rect(x: node.semantic.name == "web" ? 3000 : 3400, y: 2500,
                              width: 160, height: 80)
            element.content = .node(node)
            try! current.apply(.replaceElement(element))
        }
        bridge.board = current

        // Agent resends the same blocks with NO at/size + one new block.
        let proposed = #"{"nodes":[{"id":"web","name":"web","kind":"client"},{"id":"api","name":"api","kind":"gateway"},{"id":"db","name":"db","kind":"database"}],"edges":[{"from":"web","to":"api"},{"from":"api","to":"db"}]}"#
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 8, "method": "tools/call",
            "params": ["name": "propose_board", "arguments": ["board": proposed]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: request)
        _ = handler.handle(data)

        let staged = bridge.stagedProposal!
        func frame(_ name: String) -> Rect {
            staged.elements.values.first { $0.node?.semantic.name == name }!.node!.frame
        }
        XCTAssertEqual(frame("web").x, 3000, "matched block stays put")
        XCTAssertEqual(frame("api").x, 3400, "matched block stays put")
        XCTAssertGreaterThan(frame("db").x, 3000,
                             "the new block lands beside the graph, not at the layout origin")
    }

    func testProposeInvalidBoardIsError() {
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": ["name": "propose_board", "arguments": ["board": "this is not json"]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: request)
        let r = try! JSONSerialization.jsonObject(with: handler.handle(data)!) as! [String: Any]
        let result = r["result"] as! [String: Any]
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertNil(bridge.stagedProposal)
    }

    func testUnknownMethod() {
        let r = call(#"{"jsonrpc":"2.0","id":8,"method":"frobnicate","params":{}}"#)
        XCTAssertNotNil(r["error"])
    }

    func testProposalWithoutTitleKeepsBoardName() {
        var named = bridge.board!
        named.title = "My System"
        bridge.board = named
        let proposed = #"{"nodes":[{"id":"web","name":"web","kind":"client"},{"id":"api","name":"api","kind":"gateway"},{"id":"db","name":"db"}],"edges":[{"from":"web","to":"api","protocol":"HTTPS"}]}"#
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 9, "method": "tools/call",
            "params": ["name": "propose_board", "arguments": ["board": proposed]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: request)
        _ = handler.handle(data)
        XCTAssertEqual(bridge.stagedProposal?.title, "My System",
                       "omitting the title must not rename the board to 'Imported'")
    }

    func testMassDeletionWarns() {
        // Current board has 2 blocks; make it 4 so the guard engages.
        bridge.board = try! LLMInterchange.parse(
            "# designer-board\n\n" + #"{"nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"},{"id":"c","name":"c"},{"id":"d","name":"d"}],"edges":[]}"# + "\n"
        ).board
        // Proposal keeps only one — the agent probably sent just its changes.
        let proposed = #"{"nodes":[{"id":"e","name":"e"}],"edges":[]}"#
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 10, "method": "tools/call",
            "params": ["name": "propose_board", "arguments": ["board": proposed]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: request)
        let r = try! JSONSerialization.jsonObject(with: handler.handle(data)!) as! [String: Any]
        let text = toolText(r)
        XCTAssertTrue(text.contains("removes 4 of the 4 existing blocks"), "must warn on mass deletion: \(text)")
        XCTAssertTrue(text.contains("ENTIRE diagram"))
    }

    func testExplicitTitleChangeShowsInDiff() {
        var named = bridge.board!
        named.title = "My System"
        bridge.board = named
        let proposed = #"{"title":"Renamed System","nodes":[{"id":"web","name":"web","kind":"client"},{"id":"api","name":"api","kind":"gateway"}],"edges":[{"from":"web","to":"api","protocol":"HTTPS"}]}"#
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 11, "method": "tools/call",
            "params": ["name": "propose_board", "arguments": ["board": proposed]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: request)
        let r = try! JSONSerialization.jsonObject(with: handler.handle(data)!) as! [String: Any]
        XCTAssertTrue(toolText(r).contains("board renamed"), "explicit rename must be visible in review")
    }
}
