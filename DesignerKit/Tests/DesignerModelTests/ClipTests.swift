import XCTest
@testable import DesignerModel

final class ClipTests: XCTestCase {
    private var board = Board(title: "Source")
    private var layerID: LayerID { board.layers[0].id }

    @discardableResult
    private func addNode(_ name: String, _ frame: Rect) -> Element {
        let element = Element(
            layerIDs: [layerID], sortKey: board.topSortKey,
            content: .node(Node(semantic: NodeSemantic(name: name), frame: frame))
        )
        try! board.apply(.insertElement(element))
        return element
    }

    @discardableResult
    private func connect(_ a: Element, _ b: Element) -> Element {
        let edge = Element(
            layerIDs: [layerID], sortKey: board.topSortKey,
            content: .edge(Edge(
                from: .element(a.id, side: nil, offset: nil),
                to: .element(b.id, side: nil, offset: nil)
            ))
        )
        try! board.apply(.insertElement(edge))
        return edge
    }

    func testClipFlattensLayersAndKeepsInternalEdges() {
        let a = addNode("a", Rect(x: 0, y: 0, width: 100, height: 60))
        let b = addNode("b", Rect(x: 300, y: 0, width: 100, height: 60))
        let edge = connect(a, b)

        let clip = board.makeClip(of: [a.id, b.id, edge.id])
        XCTAssertEqual(clip.layers.count, 1)
        XCTAssertEqual(clip.elements.count, 3)
        let clipLayer = clip.layers[0].id
        XCTAssertTrue(clip.elements.values.allSatisfy { $0.layerIDs == [clipLayer] })
        // Internal edge keeps both element anchors.
        let clipEdge = clip.elements[edge.id]?.edge
        XCTAssertEqual(clipEdge?.from.elementID, a.id)
        XCTAssertEqual(clipEdge?.to.elementID, b.id)
    }

    func testClipClampsEdgeToOutsideNode() {
        let a = addNode("a", Rect(x: 0, y: 0, width: 100, height: 60))
        let b = addNode("b", Rect(x: 300, y: 0, width: 100, height: 60))
        let edge = connect(a, b)

        // Clip only a + edge; b is outside → that endpoint becomes free.
        let clip = board.makeClip(of: [a.id, edge.id])
        let clipEdge = clip.elements[edge.id]?.edge
        XCTAssertEqual(clipEdge?.from.elementID, a.id)
        if case .free = clipEdge?.to {} else {
            XCTFail("edge endpoint to the excluded node should be a free point")
        }
    }

    func testInstantiateGivesFreshIDsAndRemapsEdges() throws {
        let a = addNode("a", Rect(x: 0, y: 0, width: 100, height: 60))
        let b = addNode("b", Rect(x: 300, y: 0, width: 100, height: 60))
        let edge = connect(a, b)
        let clip = board.makeClip(of: [a.id, b.id, edge.id])

        var target = Board(title: "Target")
        let targetLayer = target.layers[0].id
        let (operations, newIDs) = target.instantiateOperations(
            from: clip, offsetBy: 50, 40, onto: targetLayer
        )
        try target.apply(.batch(operations))

        XCTAssertEqual(target.elements.count, 3)
        XCTAssertEqual(Set(target.elements.keys), newIDs)
        // No original IDs leaked.
        XCTAssertNil(target.elements[a.id])
        XCTAssertNil(target.elements[edge.id])

        // The instantiated edge re-points to the instantiated nodes.
        let newEdge = try XCTUnwrap(target.elements.values.first { $0.edge != nil }?.edge)
        let newNodeIDs = Set(target.elements.values.filter { $0.node != nil }.map(\.id))
        XCTAssertTrue(newNodeIDs.contains(newEdge.from.elementID!))
        XCTAssertTrue(newNodeIDs.contains(newEdge.to.elementID!))

        // Geometry is offset.
        let movedA = try XCTUnwrap(target.elements.values.first { $0.node?.semantic.name == "a" }?.node)
        XCTAssertEqual(movedA.frame.x, 50, accuracy: 1e-9)
        XCTAssertEqual(movedA.frame.y, 40, accuracy: 1e-9)

        // Everything lands on the target layer.
        XCTAssertTrue(target.elements.values.allSatisfy { $0.layerIDs == [targetLayer] })
    }

    func testInstantiateTwiceDoesNotCollide() throws {
        let a = addNode("a", Rect(x: 0, y: 0, width: 100, height: 60))
        let clip = board.makeClip(of: [a.id])

        var target = Board(title: "Target")
        let layer = target.layers[0].id
        let first = target.instantiateOperations(from: clip, offsetBy: 0, 0, onto: layer)
        try target.apply(.batch(first.operations))
        let second = target.instantiateOperations(from: clip, offsetBy: 20, 20, onto: layer)
        try target.apply(.batch(second.operations))

        XCTAssertEqual(target.elements.count, 2, "two instantiations must not collide on IDs")
        XCTAssertTrue(first.newIDs.isDisjoint(with: second.newIDs))
    }

    func testContentBounds() {
        addNode("a", Rect(x: 100, y: 100, width: 100, height: 60))
        addNode("b", Rect(x: 300, y: 200, width: 100, height: 60))
        let bounds = board.contentBounds()
        XCTAssertEqual(bounds?.x, 100)
        XCTAssertEqual(bounds?.y, 100)
        XCTAssertEqual(bounds?.maxX, 400)
        XCTAssertEqual(bounds?.maxY, 260)
    }
}
