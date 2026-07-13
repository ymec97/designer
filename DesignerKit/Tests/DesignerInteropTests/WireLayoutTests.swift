import XCTest
@testable import DesignerInterop
import DesignerModel

/// The flow auto-layout used when an imported/proposed board omits positions.
final class WireLayoutTests: XCTestCase {
    private func board(_ json: String) -> Board {
        try! LLMInterchange.parse("# designer-board\n\n\(json)\n").board
    }

    private func frame(_ board: Board, _ name: String) -> Rect {
        board.elements.values.first { $0.node?.semantic.name == name }!.node!.frame
    }

    func testChainFlowsLeftToRight() {
        let b = board(#"{"nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"},{"id":"c","name":"c"}],"edges":[{"from":"a","to":"b"},{"from":"b","to":"c"}]}"#)
        XCTAssertLessThan(frame(b, "a").x, frame(b, "b").x)
        XCTAssertLessThan(frame(b, "b").x, frame(b, "c").x)
    }

    func testFanOutSharesColumn() {
        let b = board(#"{"nodes":[{"id":"gw","name":"gw"},{"id":"a","name":"a"},{"id":"b","name":"b"}],"edges":[{"from":"gw","to":"a"},{"from":"gw","to":"b"}]}"#)
        XCTAssertLessThan(frame(b, "gw").x, frame(b, "a").x)
        XCTAssertEqual(frame(b, "a").x, frame(b, "b").x, "siblings share a column")
        XCTAssertNotEqual(frame(b, "a").y, frame(b, "b").y, "siblings stack vertically")
    }

    func testDiamondJoinLandsAfterBothBranches() {
        let b = board(#"{"nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"},{"id":"c","name":"c"},{"id":"d","name":"d"}],"edges":[{"from":"a","to":"b"},{"from":"a","to":"c"},{"from":"b","to":"d"},{"from":"c","to":"d"}]}"#)
        XCTAssertGreaterThan(frame(b, "d").x, frame(b, "b").x)
        XCTAssertGreaterThan(frame(b, "d").x, frame(b, "c").x)
    }

    func testCycleTerminatesWithPositions() {
        let b = board(#"{"nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"},{"id":"c","name":"c"}],"edges":[{"from":"a","to":"b"},{"from":"b","to":"c"},{"from":"c","to":"a"}]}"#)
        XCTAssertEqual(b.elements.values.filter { $0.node != nil }.count, 3)
        for name in ["a", "b", "c"] {
            XCTAssertGreaterThan(frame(b, name).width, 0)
        }
    }

    func testGivenPositionsAreKept() {
        let b = board(#"{"nodes":[{"id":"a","name":"a","at":[500,600],"size":[100,50]},{"id":"b","name":"b"}],"edges":[{"from":"a","to":"b"}]}"#)
        XCTAssertEqual(frame(b, "a").x, 500)
        XCTAssertEqual(frame(b, "a").y, 600)
        XCTAssertGreaterThan(frame(b, "b").x, 80 - 1, "auto node still placed")
    }

    func testNoEdgesFallsBackToGrid() {
        let b = board(#"{"nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"}],"edges":[]}"#)
        // Same row, different x — the grid path.
        XCTAssertEqual(frame(b, "a").y, frame(b, "b").y)
        XCTAssertNotEqual(frame(b, "a").x, frame(b, "b").x)
    }
}
