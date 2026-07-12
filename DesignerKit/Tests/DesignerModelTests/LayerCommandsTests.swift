import XCTest
@testable import DesignerModel

final class LayerCommandsTests: XCTestCase {
    private var board = Board(title: "Layers")
    private var baseID: LayerID { board.layers[0].id }

    @discardableResult
    private func addNode(on layers: Set<LayerID>) -> Element {
        let element = Element(
            layerIDs: layers,
            sortKey: board.topSortKey,
            content: .node(Node(frame: Rect(x: 0, y: 0, width: 100, height: 60)))
        )
        try! board.apply(.insertElement(element))
        return element
    }

    func testMoveLayerAndInverse() throws {
        let base = baseID
        let second = Layer(name: "Second")
        let third = Layer(name: "Third")
        try board.apply(.insertLayer(second, at: 1))
        try board.apply(.insertLayer(third, at: 2))
        let before = board

        let inverse = try board.apply(.moveLayer(third.id, to: 0))
        XCTAssertEqual(board.layers.map(\.id), [third.id, base, second.id])
        try board.apply(inverse)
        XCTAssertEqual(board, before)
    }

    func testDuplicateLayerSharesElements() throws {
        let node = addNode(on: [baseID])
        let operations = try XCTUnwrap(board.duplicateLayerOperations(baseID))
        try board.apply(.batch(operations))

        XCTAssertEqual(board.layers.count, 2)
        let copy = board.layers[1]
        XCTAssertEqual(copy.name, "Base Copy")
        XCTAssertEqual(
            board.elements[node.id]?.layerIDs, [baseID, copy.id],
            "element exists once, member of both layers"
        )
        XCTAssertEqual(board.elementCount(onLayer: copy.id), 1)
    }

    func testDeleteLayerMigratesSoleMembers() throws {
        let second = Layer(name: "Second")
        try board.apply(.insertLayer(second, at: 1))
        let soleMember = addNode(on: [second.id])
        let dualMember = addNode(on: [baseID, second.id])

        let operations = try XCTUnwrap(board.deleteLayerOperations(second.id))
        let inverse = try board.apply(.batch(operations))

        XCTAssertEqual(board.layers.count, 1)
        XCTAssertEqual(
            board.elements[soleMember.id]?.layerIDs, [baseID],
            "sole member migrates instead of vanishing"
        )
        XCTAssertEqual(board.elements[dualMember.id]?.layerIDs, [baseID])

        // One undo restores the layer AND memberships.
        try board.apply(inverse)
        XCTAssertEqual(board.elements[soleMember.id]?.layerIDs, [second.id])
        XCTAssertEqual(board.elements[dualMember.id]?.layerIDs, [baseID, second.id])
    }

    func testDeleteLastLayerRefused() {
        XCTAssertNil(board.deleteLayerOperations(baseID))
    }

    func testAssignAndUnassign() throws {
        let second = Layer(name: "Second")
        try board.apply(.insertLayer(second, at: 1))
        let node = addNode(on: [baseID])

        try board.apply(.batch(board.assignOperations([node.id], toLayer: second.id)))
        XCTAssertEqual(board.elements[node.id]?.layerIDs, [baseID, second.id])

        try board.apply(.batch(board.unassignOperations([node.id], fromLayer: baseID)))
        XCTAssertEqual(board.elements[node.id]?.layerIDs, [second.id])

        // Unassigning the only remaining layer is refused.
        XCTAssertTrue(board.unassignOperations([node.id], fromLayer: second.id).isEmpty)
    }
}
