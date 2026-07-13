import XCTest
@testable import DesignerAgent

final class ChatStreamParserTests: XCTestCase {
    // Trimmed real lines captured from `claude -p --output-format stream-json`.
    private let initLine = #"{"type":"system","subtype":"init","cwd":"/tmp","session_id":"33944477-05c2-4f40-a135-4832ebc2847b","tools":["Task"],"model":"claude-opus-4-8"}"#
    private let textLine = #"{"type":"assistant","message":{"model":"claude-opus-4-8","id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}]},"session_id":"s"}"#
    private let toolLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"mcp__designer__propose_board","input":{}}]},"session_id":"s"}"#
    private let resultLine = #"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s"}"#
    private let errorResult = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Invalid API key","session_id":"s"}"#

    func testParsesInit() {
        XCTAssertEqual(ChatStreamParser.parse(Data(initLine.utf8)),
                       [.sessionStarted(id: "33944477-05c2-4f40-a135-4832ebc2847b")])
    }

    func testParsesAssistantText() {
        XCTAssertEqual(ChatStreamParser.parse(Data(textLine.utf8)), [.assistantText("ok")])
    }

    func testParsesToolUse() {
        XCTAssertEqual(ChatStreamParser.parse(Data(toolLine.utf8)),
                       [.toolUse(name: "mcp__designer__propose_board")])
    }

    func testParsesResults() {
        XCTAssertEqual(ChatStreamParser.parse(Data(resultLine.utf8)),
                       [.finished(success: true, summary: "done")])
        XCTAssertEqual(ChatStreamParser.parse(Data(errorResult.utf8)),
                       [.finished(success: false, summary: "Invalid API key")])
    }

    func testUnknownAndMalformedAreIgnored() {
        XCTAssertEqual(ChatStreamParser.parse(Data(#"{"type":"rate_limit_event"}"#.utf8)), [.ignored])
        XCTAssertEqual(ChatStreamParser.parse(Data("not json at all".utf8)), [.ignored])
    }

    func testDrainLinesKeepsPartialTail() {
        var buffer = Data("{\"a\":1}\n{\"b\":2}\n{\"partial".utf8)
        let lines = ChatStreamParser.drainLines(from: &buffer)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(data: buffer, encoding: .utf8), "{\"partial")
        buffer.append(Data("\":3}\n".utf8))
        XCTAssertEqual(ChatStreamParser.drainLines(from: &buffer).count, 1)
        XCTAssertTrue(buffer.isEmpty)
    }
}
