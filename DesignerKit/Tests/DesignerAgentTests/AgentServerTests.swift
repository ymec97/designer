import XCTest
@testable import DesignerAgent
import DesignerModel
import DesignerInterop

private final class ServerStubBridge: AgentBoardBridge {
    let board: Board
    var staged: Board?
    init(_ board: Board) { self.board = board }
    func currentBoard() -> Board? { board }
    func stageProposal(_ proposed: Board, note: String?) -> BoardDiff {
        staged = proposed
        return LLMInterchange.diff(current: board, proposed: proposed)
    }
}

final class AgentServerTests: XCTestCase {
    func testEndToEndOverLocalhost() throws {
        let board = try LLMInterchange.parse(
            "# designer-board\n\n" + #"{"nodes":[{"id":"web","name":"web"},{"id":"api","name":"api","kind":"gateway"}],"edges":[{"from":"web","to":"api"}]}"# + "\n"
        ).board
        let bridge = ServerStubBridge(board)
        let server = AgentServer(bridge: bridge)

        let ready = expectation(description: "listener ready")
        try server.start(preferredPort: 0) { _ in ready.fulfill() }
        wait(for: [ready], timeout: 5)
        defer { server.stop() }
        XCTAssertGreaterThan(server.port, 0)

        // tools/list over the wire.
        let listResponse = try post(to: server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#)
        let tools = ((listResponse["result"] as! [String: Any])["tools"] as! [[String: Any]])
        XCTAssertEqual(tools.count, 6)

        // get_board over the wire returns parseable board text.
        let getResponse = try post(to: server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_board","arguments":{}}}"#)
        let text = (((getResponse["result"] as! [String: Any])["content"] as! [[String: Any]]).first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("web"))
        XCTAssertNoThrow(try LLMInterchange.parse(text))
    }

    func testBrowserOriginRejectedAndGETRefused() throws {
        let board = try LLMInterchange.parse(
            "# designer-board\n\n" + #"{"nodes":[{"id":"a","name":"a"}],"edges":[]}"# + "\n"
        ).board
        let server = AgentServer(bridge: ServerStubBridge(board))
        let ready = expectation(description: "ready")
        try server.start(preferredPort: 0) { _ in ready.fulfill() }
        wait(for: [ready], timeout: 5)
        defer { server.stop() }

        // A cross-origin browser POST carries an Origin header → 403.
        var post = URLRequest(url: URL(string: server.endpointURL)!)
        post.httpMethod = "POST"
        post.setValue("https://evil.example", forHTTPHeaderField: "Origin")
        post.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.utf8)
        XCTAssertEqual(try status(of: post), 403)

        // GET has no SSE stream to offer → 405 per Streamable HTTP.
        var get = URLRequest(url: URL(string: server.endpointURL)!)
        get.httpMethod = "GET"
        XCTAssertEqual(try status(of: get), 405)
    }

    private func status(of request: URLRequest) throws -> Int {
        var code = -1
        var thrown: Error?
        let done = expectation(description: "status \(request.httpMethod ?? "")")
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error { thrown = error }
            code = (response as? HTTPURLResponse)?.statusCode ?? -1
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        if let thrown { throw thrown }
        return code
    }

    /// Synchronous POST to the server's endpoint; returns the parsed JSON-RPC reply.
    private func post(to server: AgentServer, _ body: String) throws -> [String: Any] {
        let url = URL(string: server.endpointURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        var result: [String: Any] = [:]
        var thrown: Error?
        let done = expectation(description: "post \(body.prefix(30))")
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error { thrown = error }
            else if let data { result = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        if let thrown { throw thrown }
        return result
    }
}
