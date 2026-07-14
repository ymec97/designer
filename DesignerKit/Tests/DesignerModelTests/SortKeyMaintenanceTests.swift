import XCTest
@testable import DesignerModel

final class SortKeyMaintenanceTests: XCTestCase {
    private func nodeElement(_ layer: LayerID, sortKey: String, name: String) -> Element {
        Element(layerIDs: [layer], sortKey: sortKey,
                content: .node(Node(semantic: NodeSemantic(name: name),
                                    frame: Rect(x: 0, y: 0, width: 10, height: 10))))
    }

    func testSequentialInsertionGrowsKeysAndNormalizationShrinksThem() {
        var board = Board(title: "B2")
        let layer = board.layers[0].id
        // Simulate the pathological pattern: thousands of sequential inserts,
        // each keyed after the previous maximum.
        for index in 0..<800 {
            try! board.apply(.insertElement(nodeElement(layer, sortKey: board.topSortKey, name: "n\(index)")))
        }
        let longest = board.elements.values.map(\.sortKey.count).max() ?? 0
        XCTAssertGreaterThan(longest, Board.sortKeyLengthThreshold,
                             "the pathology must actually manifest for this test to mean anything")
        XCTAssertTrue(board.needsSortKeyNormalization)

        let orderBefore = board.elementsInZOrder.map(\.id)
        board.normalizeSortKeysIfNeeded()

        XCTAssertEqual(board.elementsInZOrder.map(\.id), orderBefore, "z-order must be preserved exactly")
        let longestAfter = board.elements.values.map(\.sortKey.count).max() ?? 0
        XCTAssertLessThanOrEqual(longestAfter, 6, "keys should be compact after normalization")
        XCTAssertFalse(board.needsSortKeyNormalization)
    }

    func testHealthyBoardIsLeftAlone() {
        var board = Board(title: "ok")
        let layer = board.layers[0].id
        try! board.apply(.insertElement(nodeElement(layer, sortKey: "a", name: "x")))
        let before = board
        board.normalizeSortKeysIfNeeded()
        XCTAssertEqual(board, before, "no rewrite when keys are healthy")
    }
}
