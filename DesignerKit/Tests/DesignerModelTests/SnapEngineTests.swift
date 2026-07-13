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
