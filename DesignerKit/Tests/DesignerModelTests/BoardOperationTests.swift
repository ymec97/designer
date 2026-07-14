import XCTest
@testable import DesignerModel

final class BoardOperationTests: XCTestCase {
    private var board = Board(title: "Ops")
    private var layerID: LayerID { board.layers[0].id }

    private func makeNode(name: String = "n") -> Element {
        Element(
            layerIDs: [layerID],
            sortKey: board.topSortKey,
            content: .node(Node(
                semantic: NodeSemantic(kind: .service, name: name),
                frame: Rect(x: 0, y: 0, width: 100, height: 60)
            ))
        )
    }

    // MARK: apply / inverse symmetry

    func testEveryOperationInverseRestoresBoard() throws {
        let node = makeNode()
        try board.apply(.insertElement(node))
        var moved = node
        moved.content = .node(Node(
            semantic: node.node!.semantic,
            frame: Rect(x: 50, y: 50, width: 100, height: 60)
        ))
        let extraLayer = Layer(name: "Second")

        let operations: [BoardOperation] = [
            .insertElement(makeNode(name: "other")),
            .replaceElement(moved),
            .removeElement(node.id),
            .setTitle("Renamed"),
            .insertLayer(extraLayer, at: 1),
            .replaceLayer(Layer(id: layerID, name: "Base*")),
            .batch([.setTitle("A"), .setTitle("B")]),
        ]

        for operation in operations {
            let before = board
            let inverse = try board.apply(operation)
            XCTAssertNotEqual(board, before, "\(operation) should change the board")
            try board.apply(inverse)
            XCTAssertEqual(board, before, "inverse of \(operation) must restore the board")
            // Re-apply so later operations see the mutated board.
            try board.apply(operation)
        }
    }

    func testSetExtraTogglesAndInverts() throws {
        XCTAssertFalse(board.isSketchy)
        let inverse = try board.apply(.setExtra(key: Board.sketchyExtraKey, value: .bool(true)))
        XCTAssertTrue(board.isSketchy)
        XCTAssertEqual(inverse, .setExtra(key: Board.sketchyExtraKey, value: nil))
        try board.apply(inverse)
        XCTAssertFalse(board.isSketchy)
        XCTAssertNil(board.extra[Board.sketchyExtraKey], "clearing removes the key entirely")
    }

    func testSketchJitterIsDeterministicAndAnchored() {
        let line = [Point(x: 0, y: 0), Point(x: 300, y: 0)]
        let a = Sketch.roughPolyline(line, seed: 7, pass: 0)
        let b = Sketch.roughPolyline(line, seed: 7, pass: 0)
        XCTAssertEqual(a, b, "same seed, same wobble")
        XCTAssertNotEqual(a, Sketch.roughPolyline(line, seed: 8, pass: 0), "different seed differs")
        XCTAssertNotEqual(a, Sketch.roughPolyline(line, seed: 7, pass: 1), "passes differ")
        XCTAssertEqual(a.first, line.first)
        XCTAssertEqual(a.last, line.last, "endpoints never move")
        XCTAssertGreaterThan(a.count, 2, "segments subdivide")
    }

    func testReplaceBoardSwapsContentKeepsIdentity() throws {
        try board.apply(.insertElement(makeNode(name: "mine")))
        let originalID = board.id
        let before = board

        var replacement = Board(title: "Restored")
        let otherLayer = replacement.layers[0].id
        try replacement.apply(.insertElement(Element(
            layerIDs: [otherLayer], sortKey: replacement.topSortKey,
            content: .node(Node(semantic: NodeSemantic(name: "theirs"),
                                frame: Rect(x: 0, y: 0, width: 50, height: 30)))
        )))

        let inverse = try board.apply(.replaceBoard(replacement))
        XCTAssertEqual(board.title, "Restored")
        XCTAssertEqual(board.elements.values.first?.node?.semantic.name, "theirs")
        XCTAssertEqual(board.layers.map(\.id), [otherLayer])
        XCTAssertEqual(board.id, originalID, "identity never changes on restore")

        try board.apply(inverse)
        XCTAssertEqual(board, before, "replaceBoard round-trips exactly")
    }

    func testUndoRedoChain() throws {
        let original = board
        var undoStack: [BoardOperation] = []

        let a = makeNode(name: "a")
        undoStack.append(try board.apply(.insertElement(a)))
        undoStack.append(try board.apply(.setTitle("Working")))
        var movedA = a
        movedA.sortKey = SortKey.after(a.sortKey)
        undoStack.append(try board.apply(.replaceElement(movedA)))

        let afterAll = board
        var redoStack: [BoardOperation] = []
        while let inverse = undoStack.popLast() {
            redoStack.append(try board.apply(inverse))
        }
        XCTAssertEqual(board, original, "full undo returns the original board")

        while let redo = redoStack.popLast() {
            try board.apply(redo)
        }
        XCTAssertEqual(board, afterAll, "full redo returns the final board")
    }

    // MARK: validation

    func testInsertDuplicateFails() throws {
        let node = makeNode()
        try board.apply(.insertElement(node))
        XCTAssertThrowsError(try board.apply(.insertElement(node))) {
            XCTAssertEqual($0 as? BoardOperationError, .elementAlreadyExists(node.id))
        }
    }

    func testRemoveMissingFails() {
        let ghost = ElementID()
        XCTAssertThrowsError(try board.apply(.removeElement(ghost))) {
            XCTAssertEqual($0 as? BoardOperationError, .elementNotFound(ghost))
        }
    }

    func testRemoveLastLayerFails() {
        XCTAssertThrowsError(try board.apply(.removeLayer(layerID))) {
            XCTAssertEqual($0 as? BoardOperationError, .cannotRemoveLastLayer)
        }
    }

    func testRemoveInhabitedLayerFails() throws {
        try board.apply(.insertLayer(Layer(name: "Second"), at: 1))
        try board.apply(.insertElement(makeNode()))
        XCTAssertThrowsError(try board.apply(.removeLayer(layerID))) {
            XCTAssertEqual($0 as? BoardOperationError, .layerInUse(layerID, elementCount: 1))
        }
    }

    func testFailedBatchRollsBackCompletely() throws {
        let before = board
        let node = makeNode()
        // Third child fails (duplicate insert) — the first two must roll back.
        XCTAssertThrowsError(try board.apply(.batch([
            .insertElement(node),
            .setTitle("changed"),
            .insertElement(node),
        ])))
        XCTAssertEqual(board, before, "failed batch must leave the board untouched")
    }

    func testBoardUnchangedOnAnyFailure() {
        let before = board
        XCTAssertThrowsError(try board.apply(.removeElement(ElementID())))
        XCTAssertThrowsError(try board.apply(.replaceLayer(Layer(name: "ghost"))))
        XCTAssertThrowsError(try board.apply(.insertLayer(Layer(name: "x"), at: 99)))
        XCTAssertEqual(board, before)
    }
}
