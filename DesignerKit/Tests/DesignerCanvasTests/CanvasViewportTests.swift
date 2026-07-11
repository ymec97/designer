import XCTest
import DesignerModel
@testable import DesignerCanvas

final class CanvasViewportTests: XCTestCase {
    func testWorldViewRoundTrip() {
        var viewport = CanvasViewport(origin: Point(x: 100, y: -50), scale: 2)
        let world = Point(x: 123.5, y: 456.25)
        let back = viewport.toWorld(viewport.toView(world))
        XCTAssertEqual(back.x, world.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, world.y, accuracy: 1e-9)

        viewport.pan(viewDeltaX: 40, viewDeltaY: -20)
        let back2 = viewport.toWorld(viewport.toView(world))
        XCTAssertEqual(back2.x, world.x, accuracy: 1e-9)
        XCTAssertEqual(back2.y, world.y, accuracy: 1e-9)
    }

    func testPanMovesOriginInWorldUnits() {
        var viewport = CanvasViewport(origin: .zero, scale: 2)
        viewport.pan(viewDeltaX: 100, viewDeltaY: 50)
        // Scrolling content right/down by view pixels moves the origin left/up
        // by pixels ÷ scale.
        XCTAssertEqual(viewport.origin.x, -50, accuracy: 1e-9)
        XCTAssertEqual(viewport.origin.y, -25, accuracy: 1e-9)
    }

    func testZoomKeepsAnchorFixed() {
        var viewport = CanvasViewport(origin: Point(x: 10, y: 20), scale: 1)
        let anchor = CGPoint(x: 300, y: 200)
        let anchorWorldBefore = viewport.toWorld(anchor)
        viewport.zoom(by: 2.5, at: anchor)
        let anchorWorldAfter = viewport.toWorld(anchor)
        XCTAssertEqual(anchorWorldBefore.x, anchorWorldAfter.x, accuracy: 1e-9)
        XCTAssertEqual(anchorWorldBefore.y, anchorWorldAfter.y, accuracy: 1e-9)
        XCTAssertEqual(viewport.scale, 2.5, accuracy: 1e-9)
    }

    func testScaleClamping() {
        var viewport = CanvasViewport()
        viewport.zoom(by: 1e9, at: .zero)
        XCTAssertEqual(viewport.scale, CanvasViewport.maxScale)
        viewport.zoom(by: 1e-12, at: .zero)
        XCTAssertEqual(viewport.scale, CanvasViewport.minScale)
        XCTAssertEqual(CanvasViewport(origin: .zero, scale: 500).scale, CanvasViewport.maxScale)
    }

    func testFitCentersAndContains() {
        var viewport = CanvasViewport()
        let world = Rect(x: 1000, y: 2000, width: 800, height: 400)
        let viewSize = CGSize(width: 1600, height: 1000)
        viewport.fit(world, in: viewSize, padding: 40)

        // The whole rect (with padding) must be inside the visible region.
        let visible = viewport.visibleWorldRect(viewSize: viewSize)
        XCTAssertLessThanOrEqual(visible.x, world.x)
        XCTAssertLessThanOrEqual(visible.y, world.y)
        XCTAssertGreaterThanOrEqual(visible.maxX, world.maxX)
        XCTAssertGreaterThanOrEqual(visible.maxY, world.maxY)

        // And centered: world rect center maps to view center.
        let center = viewport.toView(Point(x: world.midX, y: world.midY))
        XCTAssertEqual(center.x, viewSize.width / 2, accuracy: 0.5)
        XCTAssertEqual(center.y, viewSize.height / 2, accuracy: 0.5)
    }

    func testVisibleWorldRect() {
        let viewport = CanvasViewport(origin: Point(x: 100, y: 200), scale: 2)
        let visible = viewport.visibleWorldRect(viewSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(visible.x, 100)
        XCTAssertEqual(visible.y, 200)
        XCTAssertEqual(visible.width, 400)
        XCTAssertEqual(visible.height, 300)
    }
}
