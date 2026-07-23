import XCTest
@testable import DesignerModel

/// Flow compositions: tree Codable, board persistence/migration, undo
/// inverses, tree editing, and staleness.
final class FlowCompositionTests: XCTestCase {
    private func comp() -> FlowComposition {
        FlowComposition(name: "Boot sequence", mode: .serial, children: [
            .flow("f1"),
            .group(mode: .parallel, children: [.flow("f2"), .flow("f3")]),
            .flow("f4"),
        ])
    }

    // MARK: Codable

    func testNestedTreeRoundTrips() throws {
        let original = comp()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FlowComposition.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testUnknownChildKindThrows() {
        let json = """
        {"id":"c1","name":"x","mode":"serial","children":[{"kind":"wormhole","id":"f1"}]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(FlowComposition.self, from: json))
    }

    func testMemberFlowIDsInTreeOrder() {
        XCTAssertEqual(comp().memberFlowIDs, ["f1", "f2", "f3", "f4"])
    }

    // MARK: Board persistence

    func testBoardWithCompositionsRoundTrips() throws {
        var board = Board(title: "b")
        let c = comp()
        board.compositions = [c]
        let decoded = try JSONDecoder().decode(Board.self, from: JSONEncoder().encode(board))
        XCTAssertEqual(decoded.compositions, [c])
    }

    func testOldBoardWithoutCompositionsDecodesEmpty() throws {
        var board = Board(title: "b")
        board.compositions = []
        let data = try JSONEncoder().encode(board)
        // No `compositions` key is emitted when empty; it still decodes to [].
        let string = String(data: data, encoding: .utf8)!
        XCTAssertFalse(string.contains("compositions"), "empty compositions omitted from JSON")
        let decoded = try JSONDecoder().decode(Board.self, from: data)
        XCTAssertEqual(decoded.compositions, [])
    }

    func testCompositionsKeyNotSweptIntoExtra() throws {
        var board = Board(title: "b")
        board.compositions = [comp()]
        let decoded = try JSONDecoder().decode(Board.self, from: JSONEncoder().encode(board))
        XCTAssertNil(decoded.extra["compositions"], "known key must not leak into the tolerant bag")
        XCTAssertEqual(decoded.compositions.count, 1)
    }

    // MARK: Operations + undo

    func testInsertRemoveReplaceInverses() throws {
        var board = Board(title: "b")
        let c = comp()
        let insertInverse = try board.apply(.insertComposition(c, at: 0))
        XCTAssertEqual(board.compositions, [c])

        var renamed = c
        renamed.name = "Renamed"
        let replaceInverse = try board.apply(.replaceComposition(renamed))
        XCTAssertEqual(board.compositions.first?.name, "Renamed")
        try board.apply(replaceInverse)
        XCTAssertEqual(board.compositions.first?.name, "Boot sequence")

        try board.apply(insertInverse) // removeComposition
        XCTAssertTrue(board.compositions.isEmpty)
    }

    func testDuplicateInsertAndNotFoundThrow() throws {
        var board = Board(title: "b")
        let c = comp()
        try board.apply(.insertComposition(c, at: 0))
        XCTAssertThrowsError(try board.apply(.insertComposition(c, at: 0)))
        XCTAssertThrowsError(try board.apply(.removeComposition("missing")))
        XCTAssertThrowsError(try board.apply(.replaceComposition(FlowComposition(id: "missing", name: "y"))))
        XCTAssertThrowsError(try board.apply(.insertComposition(FlowComposition(name: "z"), at: 9)))
    }

    func testReplaceBoardCarriesCompositions() throws {
        var board = Board(title: "b")
        let c = comp()
        var replacement = Board(title: "b2")
        replacement.compositions = [c]
        try board.apply(.replaceBoard(replacement))
        XCTAssertEqual(board.compositions, [c], "replaceBoard must copy compositions or version-restore drops them")
    }

    // MARK: Tree editing

    func testTreeEdits() {
        var c = FlowComposition(name: "c", mode: .serial, children: [.flow("f1"), .flow("f2")])
        c.appendChild(.flow("f3"), toGroupAt: [])
        XCTAssertEqual(c.memberFlowIDs, ["f1", "f2", "f3"])

        c.appendChild(.group(mode: .parallel, children: [.flow("f4")]), toGroupAt: [])
        // Add a flow inside the nested group at path [3].
        c.appendChild(.flow("f5"), toGroupAt: [3])
        XCTAssertEqual(c.memberFlowIDs, ["f1", "f2", "f3", "f4", "f5"])

        c.toggleMode(atGroupPath: [3])
        if case .group(let mode, _)? = c.child(at: [3]) {
            XCTAssertEqual(mode, .serial)
        } else { XCTFail("expected a group at [3]") }

        c.moveChild(at: [1], up: false) // swap f2 and f3
        XCTAssertEqual(c.memberFlowIDs, ["f1", "f3", "f2", "f4", "f5"])

        c.removeChild(at: [0]) // remove f1
        XCTAssertEqual(c.memberFlowIDs, ["f3", "f2", "f4", "f5"])

        c.toggleMode(atGroupPath: []) // root serial → parallel
        XCTAssertEqual(c.mode, .parallel)
    }

    // MARK: Staleness

    func testStalenessFromMissingOrStaleFlow() {
        var board = Board(title: "b")
        let a = insertNode(&board, "a")
        let flow = Flow(id: "f1", name: "f", source: a, steps: [])
        try! board.apply(.insertFlow(flow, at: 0))

        let good = FlowComposition(name: "ok", children: [.flow("f1")])
        XCTAssertFalse(good.isStale(in: board))

        let dangling = FlowComposition(name: "bad", children: [.flow("missing")])
        XCTAssertTrue(dangling.isStale(in: board), "a referenced flow that doesn't exist is stale")
    }

    private func insertNode(_ board: inout Board, _ name: String) -> ElementID {
        let e = Element(layerIDs: [board.layers[0].id], sortKey: board.topSortKey,
                        content: .node(Node(semantic: NodeSemantic(name: name), frame: Rect(x: 0, y: 0, width: 80, height: 40))))
        try! board.apply(.insertElement(e))
        return e.id
    }
}
