import XCTest
@testable import DesignerModel

final class SpatialIndexTests: XCTestCase {
    private func node(at rect: Rect, layer: LayerID) -> Element {
        Element(
            layerIDs: [layer],
            sortKey: "i",
            content: .node(Node(frame: rect))
        )
    }

    func testQueryFindsIntersectingOnly() {
        var index = SpatialIndex(cellSize: 100)
        let a = ElementID(), b = ElementID(), c = ElementID()
        index.insert(a, bounds: Rect(x: 0, y: 0, width: 50, height: 50))
        index.insert(b, bounds: Rect(x: 500, y: 500, width: 50, height: 50))
        index.insert(c, bounds: Rect(x: 40, y: 40, width: 50, height: 50))

        XCTAssertEqual(index.query(Rect(x: 0, y: 0, width: 60, height: 60)), [a, c])
        XCTAssertEqual(index.query(Rect(x: 490, y: 490, width: 100, height: 100)), [b])
        XCTAssertEqual(index.query(Rect(x: 2000, y: 2000, width: 10, height: 10)), [])
    }

    func testElementsSpanningManyCells() {
        var index = SpatialIndex(cellSize: 100)
        let wide = ElementID()
        index.insert(wide, bounds: Rect(x: -250, y: -50, width: 900, height: 60))
        XCTAssertEqual(index.query(Rect(x: -240, y: -40, width: 5, height: 5)), [wide])
        XCTAssertEqual(index.query(Rect(x: 600, y: 0, width: 5, height: 5)), [wide])
        XCTAssertEqual(index.query(Rect(x: 0, y: 200, width: 5, height: 5)), [])
    }

    func testRemoveAndUpdate() {
        var index = SpatialIndex(cellSize: 100)
        let id = ElementID()
        index.insert(id, bounds: Rect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(index.hits(at: Point(x: 5, y: 5)), [id])

        index.insert(id, bounds: Rect(x: 300, y: 300, width: 10, height: 10))
        XCTAssertEqual(index.hits(at: Point(x: 5, y: 5)), [])
        XCTAssertEqual(index.hits(at: Point(x: 305, y: 305)), [id])

        index.remove(id)
        XCTAssertEqual(index.hits(at: Point(x: 305, y: 305)), [])
    }

    func testBuildFromBoardAndInkBounds() throws {
        var board = Board(title: "Idx")
        let layer = board.layers[0].id
        let n = node(at: Rect(x: 10, y: 10, width: 100, height: 50), layer: layer)
        let ink = Element(
            layerIDs: [layer],
            sortKey: "j",
            content: .ink(Ink(points: [
                StrokePoint(x: 200, y: 200),
                StrokePoint(x: 260, y: 240),
                StrokePoint(x: 220, y: 280),
            ]))
        )
        try board.apply(.insertElement(n))
        try board.apply(.insertElement(ink))

        let index = SpatialIndex(board: board)
        XCTAssertEqual(index.query(Rect(x: 0, y: 0, width: 120, height: 70)), [n.id])
        XCTAssertEqual(index.query(Rect(x: 195, y: 195, width: 10, height: 10)), [ink.id])
        XCTAssertEqual(index.storedBounds(of: ink.id), Rect(x: 200, y: 200, width: 60, height: 80))
    }

    func testNegativeCoordinates() {
        var index = SpatialIndex(cellSize: 100)
        let id = ElementID()
        index.insert(id, bounds: Rect(x: -150, y: -150, width: 20, height: 20))
        XCTAssertEqual(index.hits(at: Point(x: -140, y: -140)), [id])
        XCTAssertEqual(index.hits(at: Point(x: -50, y: -50)), [])
    }

    func testManyElementsQueryPerformance() {
        var index = SpatialIndex()
        var board = Board(title: "Perf")
        let layer = board.layers[0].id
        for i in 0..<2000 {
            let rect = Rect(
                x: Double(i % 50) * 200, y: Double(i / 50) * 150,
                width: 160, height: 80
            )
            let element = node(at: rect, layer: layer)
            board.elements[element.id] = element
            index.insert(element.id, bounds: rect)
        }
        measure {
            // A viewport-sized query against 2k elements.
            for _ in 0..<100 {
                _ = index.query(Rect(x: 2000, y: 1500, width: 1600, height: 1000))
            }
        }
    }
}
