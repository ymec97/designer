import XCTest
@testable import DesignerModel

/// Node → board links: stored in the tolerant extra bag, round-trip through
/// board.json, removable.
final class NodeLinkTests: XCTestCase {
    func testLinkRoundTripsThroughJSON() throws {
        let target = BoardID()
        var semantic = NodeSemantic(name: "API")
        semantic.linkedBoardID = target
        XCTAssertEqual(semantic.linkedBoardID, target)

        let decoded = try JSONDecoder().decode(
            NodeSemantic.self, from: JSONEncoder().encode(semantic))
        XCTAssertEqual(decoded.linkedBoardID, target, "link survives encode/decode")

        var cleared = decoded
        cleared.linkedBoardID = nil
        XCTAssertNil(cleared.linkedBoardID)
        XCTAssertNil(cleared.extra[NodeSemantic.linkedBoardKey], "unlink removes the key")
    }

    func testGarbageLinkValueReadsAsNil() {
        var semantic = NodeSemantic(name: "X")
        semantic.extra[NodeSemantic.linkedBoardKey] = .string("not-a-uuid")
        XCTAssertNil(semantic.linkedBoardID)
        semantic.extra[NodeSemantic.linkedBoardKey] = .int(7)
        XCTAssertNil(semantic.linkedBoardID)
    }
}
