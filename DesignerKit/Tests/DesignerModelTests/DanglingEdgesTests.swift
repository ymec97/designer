import XCTest
@testable import DesignerModel

final class DanglingEdgesTests: XCTestCase {
    private var board = Board(title: "Dangling")
    private var layerID: LayerID { board.layers[0].id }

    @discardableResult
    private func addNode(_ name: String, frame: Rect) -> Element {
        let element = Element(
            layerIDs: [layerID],
            sortKey: board.topSortKey,
            content: .node(Node(semantic: NodeSemantic(name: name), frame: frame))
        )
        try! board.apply(.insertElement(element))
        return element
    }

    @discardableResult
    private func connect(_ from: Element, _ to: Element) -> Element {
        let edge = Element(
            layerIDs: [layerID],
            sortKey: board.topSortKey,
            content: .edge(Edge(
                from: .element(from.id, side: nil, offset: nil),
                to: .element(to.id, side: nil, offset: nil)
            ))
        )
        try! board.apply(.insertElement(edge))
        return edge
    }

    func testDeletingNodeDetachesEdgeInsteadOfRemovingIt() throws {
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 100, height: 60))
        let b = addNode("b", frame: Rect(x: 400, y: 0, width: 100, height: 60))
        let edgeElement = connect(a, b)

        try board.apply(.batch(board.deleteDetachingEdges([b.id])))

        XCTAssertNil(board.elements[b.id])
        let edge = try XCTUnwrap(board.elements[edgeElement.id]?.edge, "edge must survive")
        XCTAssertTrue(board.isDangling(edge))
        XCTAssertEqual(edge.from.elementID, a.id, "attached end untouched")
        // The free end is pinned where b's border was (b's left side midpoint).
        guard case .free(let point) = edge.to else {
            return XCTFail("detached end should be a free anchor")
        }
        XCTAssertEqual(point.x, 400, accuracy: 1e-9)
        XCTAssertEqual(point.y, 30, accuracy: 1e-9)

        // The dangling edge still resolves to a drawable route.
        XCTAssertNotNil(EdgeGeometry.route(for: edge, frames: board.frameProvider()))
    }

    func testDetachingDeleteIsOneUndoStep() throws {
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 100, height: 60))
        let b = addNode("b", frame: Rect(x: 400, y: 0, width: 100, height: 60))
        connect(a, b)
        let before = board

        let inverse = try board.apply(.batch(board.deleteDetachingEdges([b.id])))
        try board.apply(inverse)
        XCTAssertEqual(board, before, "one undo restores node + attachment")
    }

    func testNewNodeSnapsDanglingEndpointBackIn() throws {
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 100, height: 60))
        let b = addNode("b", frame: Rect(x: 400, y: 0, width: 100, height: 60))
        let edgeElement = connect(a, b)
        try board.apply(.batch(board.deleteDetachingEdges([b.id])))

        // A new block dropped where b used to be (free endpoint at 400,30).
        let replacement = Element(
            layerIDs: [layerID],
            sortKey: board.topSortKey,
            content: .node(Node(frame: Rect(x: 390, y: 10, width: 120, height: 70)))
        )
        let expanded = board.expandingWithReattachments(.insertElement(replacement))
        try board.apply(expanded)

        let edge = try XCTUnwrap(board.elements[edgeElement.id]?.edge)
        XCTAssertFalse(board.isDangling(edge), "endpoint should have snapped in")
        XCTAssertEqual(edge.to.elementID, replacement.id)
    }

    func testFarAwayNodeDoesNotSnap() throws {
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 100, height: 60))
        let b = addNode("b", frame: Rect(x: 400, y: 0, width: 100, height: 60))
        let edgeElement = connect(a, b)
        try board.apply(.batch(board.deleteDetachingEdges([b.id])))

        let farNode = Element(
            layerIDs: [layerID],
            sortKey: board.topSortKey,
            content: .node(Node(frame: Rect(x: 900, y: 900, width: 100, height: 60)))
        )
        try board.apply(board.expandingWithReattachments(.insertElement(farNode)))

        let edge = try XCTUnwrap(board.elements[edgeElement.id]?.edge)
        XCTAssertTrue(board.isDangling(edge), "distant node must not steal the endpoint")
    }

    func testSnapNeverCreatesSelfLoop() throws {
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 100, height: 60))
        let b = addNode("b", frame: Rect(x: 130, y: 0, width: 100, height: 60))
        let edgeElement = connect(a, b)
        // Delete BOTH endpoints' nodes → fully dangling edge with two close ends.
        try board.apply(.batch(board.deleteDetachingEdges([a.id, b.id])))

        // One new node near both free endpoints: only one end may snap.
        let node = Element(
            layerIDs: [layerID],
            sortKey: board.topSortKey,
            content: .node(Node(frame: Rect(x: 90, y: 0, width: 60, height: 60)))
        )
        try board.apply(board.expandingWithReattachments(.insertElement(node)))

        let edge = try XCTUnwrap(board.elements[edgeElement.id]?.edge)
        XCTAssertFalse(
            edge.from.elementID == node.id && edge.to.elementID == node.id,
            "snap-in must not produce a self-loop"
        )
    }

    func testDeletingEdgeItselfStillRemovesIt() throws {
        let a = addNode("a", frame: Rect(x: 0, y: 0, width: 100, height: 60))
        let b = addNode("b", frame: Rect(x: 400, y: 0, width: 100, height: 60))
        let edgeElement = connect(a, b)

        try board.apply(.batch(board.deleteDetachingEdges([edgeElement.id])))
        XCTAssertNil(board.elements[edgeElement.id], "deleting the edge itself deletes it")
        XCTAssertNotNil(board.elements[a.id])
        XCTAssertNotNil(board.elements[b.id])
    }
}
