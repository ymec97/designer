import XCTest
@testable import DesignerModel

final class GroupingTests: XCTestCase {
    private var board = Board(title: "Groups")
    private var layer: LayerID { board.layers[0].id }

    @discardableResult
    private func node(_ name: String) -> ElementID {
        let element = Element(
            layerIDs: [layer], sortKey: board.topSortKey,
            content: .node(Node(semantic: NodeSemantic(name: name), frame: Rect(x: 0, y: 0, width: 80, height: 40)))
        )
        try! board.apply(.insertElement(element))
        return element.id
    }

    func testGroupUngroupRoundTrip() {
        let a = node("a"), b = node("b")
        guard let (operation, groupID) = board.groupOperation(for: [a, b]) else {
            return XCTFail("group op missing")
        }
        let inverse = try! board.apply(operation)
        XCTAssertEqual(board.elements[a]?.groupID, groupID)
        XCTAssertEqual(board.elements[b]?.groupID, groupID)
        XCTAssertEqual(board.groups.count, 1)
        XCTAssertEqual(board.groups.first?.memberIDs, [a, b])

        // Click-selection expansion covers the whole group.
        XCTAssertEqual(board.expandSelectionToGroups([a]), [a, b])

        // Undo restores exactly.
        try! board.apply(inverse)
        XCTAssertNil(board.elements[a]?.groupID)
        XCTAssertTrue(board.groups.isEmpty)
    }

    func testUngroupOperation() {
        let a = node("a"), b = node("b")
        let (op, groupID) = board.groupOperation(for: [a, b])!
        try! board.apply(op)
        try! board.apply(board.ungroupOperation(groupID)!)
        XCTAssertNil(board.elements[a]?.groupID)
        XCTAssertNil(board.elements[b]?.groupID)
        XCTAssertTrue(board.groups.isEmpty)
    }

    func testRegroupingMigratesAndPrunes() {
        let a = node("a"), b = node("b"), c = node("c")
        try! board.apply(board.groupOperation(for: [a, b])!.operation)
        // Regroup b+c: old group {a,b} loses b → below 2 members → dissolved.
        try! board.apply(board.groupOperation(for: [b, c])!.operation)
        XCTAssertEqual(board.groups.count, 1)
        XCTAssertNil(board.elements[a]?.groupID, "orphaned single member is freed")
        XCTAssertNotNil(board.elements[b]?.groupID)
        XCTAssertEqual(board.elements[b]?.groupID, board.elements[c]?.groupID)
    }

    func testSingleElementCannotGroup() {
        let a = node("a")
        XCTAssertNil(board.groupOperation(for: [a]))
    }

    func testBoundaryCodableRoundTrip() throws {
        let element = Element(
            layerIDs: [layer], sortKey: board.topSortKey,
            content: .boundary(Note(text: "Payments zone", frame: Rect(x: 10, y: 20, width: 400, height: 300)))
        )
        try board.apply(.insertElement(element))
        let data = try JSONEncoder().encode(board)
        let decoded = try JSONDecoder().decode(Board.self, from: data)
        guard case .boundary(let boundary) = decoded.elements[element.id]?.content else {
            return XCTFail("boundary role didn't round-trip")
        }
        XCTAssertEqual(boundary.text, "Payments zone")
        XCTAssertEqual(boundary.frame, Rect(x: 10, y: 20, width: 400, height: 300))
    }
}
