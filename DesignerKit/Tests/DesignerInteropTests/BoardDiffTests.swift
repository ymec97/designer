import XCTest
@testable import DesignerInterop
import DesignerModel

final class BoardDiffTests: XCTestCase {
    private func board(_ text: String) -> Board {
        try! LLMInterchange.parse(text).board
    }

    private func wrap(_ json: String) -> String {
        "# designer-board\n\n\(json)\n"
    }

    func testAddedAndRemovedNodes() {
        let current = board(wrap(#"{"nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"}],"edges":[]}"#))
        let proposed = board(wrap(#"{"nodes":[{"id":"a","name":"a"},{"id":"c","name":"c"}],"edges":[]}"#))
        let diff = LLMInterchange.diff(current: current, proposed: proposed)
        XCTAssertEqual(diff.addedNodes, ["c"])
        XCTAssertEqual(diff.removedNodes, ["b"])
        XCTAssertTrue(diff.changedNodes.isEmpty)
    }

    func testChangedNodeKind() {
        let current = board(wrap(#"{"nodes":[{"id":"db","name":"db","kind":"generic"}],"edges":[]}"#))
        let proposed = board(wrap(#"{"nodes":[{"id":"db","name":"db","kind":"database"}],"edges":[]}"#))
        let diff = LLMInterchange.diff(current: current, proposed: proposed)
        XCTAssertTrue(diff.addedNodes.isEmpty)
        XCTAssertEqual(diff.changedNodes.count, 1)
        XCTAssertEqual(diff.changedNodes.first?.id, "db")
    }

    func testMoveIsNotAChange() {
        // Same everything except position — should not register as changed.
        let current = board(wrap(#"{"nodes":[{"id":"a","name":"a","at":[0,0],"size":[100,50]}],"edges":[]}"#))
        let proposed = board(wrap(#"{"nodes":[{"id":"a","name":"a","at":[500,500],"size":[100,50]}],"edges":[]}"#))
        let diff = LLMInterchange.diff(current: current, proposed: proposed)
        XCTAssertTrue(diff.isEmpty, "a pure move should not be a structural change")
    }

    func testAddedAndRemovedEdges() {
        let current = board(wrap(#"{"nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"},{"id":"c","name":"c"}],"edges":[{"from":"a","to":"b"}]}"#))
        let proposed = board(wrap(#"{"nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"},{"id":"c","name":"c"}],"edges":[{"from":"a","to":"c"}]}"#))
        let diff = LLMInterchange.diff(current: current, proposed: proposed)
        XCTAssertEqual(diff.addedEdges.count, 1)
        XCTAssertTrue(diff.addedEdges.first?.contains("a → c") == true)
        XCTAssertEqual(diff.removedEdges.count, 1)
        XCTAssertTrue(diff.removedEdges.first?.contains("a → b") == true)
    }

    func testChangedEdgeProtocol() {
        let current = board(wrap(#"{"nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"}],"edges":[{"from":"a","to":"b","protocol":"HTTP"}]}"#))
        let proposed = board(wrap(#"{"nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"}],"edges":[{"from":"a","to":"b","protocol":"gRPC"}]}"#))
        let diff = LLMInterchange.diff(current: current, proposed: proposed)
        XCTAssertEqual(diff.changedEdges.count, 1)
        XCTAssertTrue(diff.changedEdges.first?.before.contains("HTTP") == true)
        XCTAssertTrue(diff.changedEdges.first?.after.contains("gRPC") == true)
    }

    func testIdenticalBoardsHaveEmptyDiff() {
        let json = wrap(#"{"nodes":[{"id":"a","name":"a"},{"id":"b","kind":"cache"}],"edges":[{"from":"a","to":"b","protocol":"HTTP"}]}"#)
        let diff = LLMInterchange.diff(current: board(json), proposed: board(json))
        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.summaryLine, "No changes")
    }

    func testSummaryLine() {
        let current = board(wrap(#"{"nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"}],"edges":[{"from":"a","to":"b"}]}"#))
        let proposed = board(wrap(#"{"nodes":[{"id":"a","name":"a"},{"id":"c","name":"c"},{"id":"d","name":"d"}],"edges":[]}"#))
        let diff = LLMInterchange.diff(current: current, proposed: proposed)
        // +2 blocks (c,d), −1 block (b), −1 connector (a→b)
        XCTAssertTrue(diff.summaryLine.contains("+2 blocks"))
        XCTAssertTrue(diff.summaryLine.contains("−1 block"))
        XCTAssertTrue(diff.summaryLine.contains("−1 connector"))
    }
}
