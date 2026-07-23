import XCTest
@testable import DesignerModel

final class SnapEngineTests: XCTestCase {
    func testSnapsLeftEdgeToOtherLeftEdge() {
        // Moving box left edge at x=103, another box left edge at x=100.
        let moving = Rect(x: 103, y: 200, width: 80, height: 50)
        let other = Rect(x: 100, y: 0, width: 80, height: 50)
        let result = SnapEngine.snap(movingBox: moving, others: [other], threshold: 6)
        XCTAssertEqual(result.dx, -3, accuracy: 1e-9, "should nudge left edge onto x=100")
        XCTAssertEqual(result.dy, 0, accuracy: 1e-9)
        XCTAssertTrue(result.guides.contains { $0.axis == .vertical && abs($0.position - 100) < 1e-9 })
    }

    func testSnapsCenterToCenter() {
        let moving = Rect(x: 0, y: 0, width: 100, height: 60) // midX 50, midY 30
        let other = Rect(x: 200, y: 48, width: 100, height: 60) // midX 250, midY 78
        // Move so vertical centers align (midX 50 → 250 needs +200) is beyond
        // threshold; horizontal centers (midY 30 vs 78, delta 48) also beyond.
        let far = SnapEngine.snap(movingBox: moving, others: [other], threshold: 6)
        XCTAssertEqual(far.dx, 0)
        XCTAssertEqual(far.dy, 0)

        // Now within threshold on Y centers.
        let nearMoving = Rect(x: 0, y: 44, width: 100, height: 60) // midY 74
        let near = SnapEngine.snap(movingBox: nearMoving, others: [other], threshold: 6)
        XCTAssertEqual(near.dy, 4, accuracy: 1e-9, "midY 74 → 78")
    }

    func testNoSnapBeyondThreshold() {
        // Far enough that no edge/center combination is within threshold.
        let moving = Rect(x: 400, y: 400, width: 50, height: 50)
        let other = Rect(x: 100, y: 100, width: 50, height: 50)
        let result = SnapEngine.snap(movingBox: moving, others: [other], threshold: 6)
        XCTAssertEqual(result.dx, 0)
        XCTAssertEqual(result.dy, 0)
        XCTAssertTrue(result.guides.isEmpty)
    }

    func testResizeSnapsMovingEdgeOnly() {
        // Original 100×50 at (100,100). Drag the right edge out to x=203; a
        // neighbor's right edge sits at x=200 → the right edge snaps to 200
        // while the (unmoved) left edge stays put.
        let original = Rect(x: 100, y: 100, width: 100, height: 50)
        let resized = Rect(x: 100, y: 100, width: 103, height: 50) // right edge 203
        let other = Rect(x: 150, y: 300, width: 50, height: 40)     // maxX 200
        let out = SnapEngine.snapResize(frame: resized, original: original, others: [other], threshold: 6)
        XCTAssertEqual(out.frame.x, 100, accuracy: 1e-9, "left edge didn't move, so it doesn't snap")
        XCTAssertEqual(out.frame.maxX, 200, accuracy: 1e-9, "moving right edge snaps onto 200")
        XCTAssertTrue(out.guides.contains { $0.axis == .vertical && abs($0.position - 200) < 1e-9 })
    }

    func testResizeIgnoresStationaryEdges() {
        // The moved (top) edge is far from any line; nothing snaps, and the
        // stationary bottom edge — which happens to align with a neighbor — is
        // NOT snapped because it didn't move.
        let original = Rect(x: 0, y: 100, width: 80, height: 60) // bottom 160
        let resized = Rect(x: 0, y: 130, width: 80, height: 30)  // top moved to 130, bottom still 160
        let other = Rect(x: 200, y: 160, width: 40, height: 40)  // top at 160 == our bottom
        let out = SnapEngine.snapResize(frame: resized, original: original, others: [other], threshold: 6)
        XCTAssertEqual(out.frame.y, 130, accuracy: 1e-9)
        XCTAssertEqual(out.frame.maxY, 160, accuracy: 1e-9)
        XCTAssertTrue(out.guides.isEmpty, "no moved edge is within threshold of a neighbor line")
    }

    func testPicksNearestAmongCandidates() {
        let moving = Rect(x: 98, y: 0, width: 40, height: 40) // left 98, right 138
        // One box wants left→100 (delta +2), another wants right→140 (delta +2).
        let a = Rect(x: 100, y: 0, width: 40, height: 40)
        let b = Rect(x: 200, y: 0, width: 40, height: 40) // maxX 240 — far
        let result = SnapEngine.snap(movingBox: moving, others: [a, b], threshold: 6)
        XCTAssertEqual(result.dx, 2, accuracy: 1e-9)
    }

    func testBothAxesSnapIndependently() {
        let moving = Rect(x: 103, y: 205, width: 80, height: 50)
        let other = Rect(x: 100, y: 200, width: 80, height: 50)
        let result = SnapEngine.snap(movingBox: moving, others: [other], threshold: 6)
        XCTAssertEqual(result.dx, -3, accuracy: 1e-9)
        XCTAssertEqual(result.dy, -5, accuracy: 1e-9)
        XCTAssertEqual(result.guides.count, 2)
    }
}
