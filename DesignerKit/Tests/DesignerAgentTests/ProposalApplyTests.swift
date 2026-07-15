import XCTest
@testable import DesignerAgent
import DesignerModel
import DesignerInterop

final class ProposalApplyTests: XCTestCase {
    private func board(_ json: String) -> Board {
        try! LLMInterchange.parse("# designer-board\n\n\(json)\n").board
    }

    func testReplaceThenUndoRestores() {
        var current = board(#"{"nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"}],"edges":[{"from":"a","to":"b"}]}"#)
        let proposed = board(#"{"nodes":[{"id":"a","name":"a"},{"id":"c","name":"c"},{"id":"d","name":"d"}],"edges":[]}"#)
        let before = LLMInterchange.export(current)

        let op = ProposalApply.replaceOperation(current: current, proposed: proposed)
        let inverse = try! current.apply(op)

        // The board now matches the proposal (structurally).
        XCTAssertTrue(LLMInterchange.diff(current: current, proposed: proposed).isEmpty,
                      "after apply, board should equal the proposal")
        // All elements live on the target layer.
        XCTAssertTrue(current.elements.values.allSatisfy { $0.layerIDs == [current.layers[0].id] })

        // Undo restores the original exactly.
        try! current.apply(inverse)
        XCTAssertEqual(LLMInterchange.export(current), before)
    }

    func testInkIsPreservedAcrossProposal() {
        // A board with one node and one ink stroke; the agent (who can't see
        // ink) proposes a node-only board. The ink must survive.
        var current = board(#"{"nodes":[{"id":"a","name":"a"}],"edges":[]}"#)
        let layer = current.layers[0].id
        let inkID = ElementID()
        try! current.apply(.insertElement(Element(
            id: inkID, layerIDs: [layer], sortKey: current.topSortKey,
            content: .ink(Ink(points: [StrokePoint(x: 0, y: 0), StrokePoint(x: 10, y: 10)])))))
        XCTAssertEqual(current.elements.count, 2)

        let proposed = board(#"{"nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"}],"edges":[]}"#)
        var applied = current
        _ = try! applied.apply(ProposalApply.replaceOperation(
            current: current, proposed: proposed))

        XCTAssertNotNil(applied.elements[inkID], "ink stroke must survive an agent proposal")
        XCTAssertEqual(applied.elements.values.filter { $0.node != nil }.count, 2)
    }

    func testProposalCreatesLayersAndFlows() {
        var current = board(#"{"nodes":[{"id":"a","name":"a"}],"edges":[]}"#)
        let proposed = board("""
        {"layers": [{"name": "Overview"}, {"name": "Caching", "tint": "#38D9A9"}],
         "nodes": [{"id": "a", "name": "a"},
                   {"id": "cache", "name": "cache", "layers": ["Caching"]}],
         "edges": [{"from": "a", "to": "cache", "label": "fill", "layers": ["Caching"]}],
         "flows": [{"name": "Fill", "source": "a",
                    "steps": [[{"from": "a", "to": "cache"}]]}]}
        """)

        let inverse = try! current.apply(ProposalApply.replaceOperation(
            current: current, proposed: proposed))

        XCTAssertEqual(current.layers.map(\.name), ["Base", "Caching"],
                       "proposed base maps onto the existing base; new layers append")
        let cachingID = current.layers[1].id
        let cacheNode = current.elements.values.first { $0.node?.semantic.name == "cache" }
        XCTAssertEqual(cacheNode?.layerIDs, [cachingID])
        XCTAssertEqual(current.flows.count, 1)
        XCTAssertEqual(current.flows[0].name, "Fill")
        XCTAssertNotNil(current.elements[current.flows[0].source],
                        "flow references inserted proposed elements")

        // One undo step returns everything: layers, flows, elements.
        try! current.apply(inverse)
        XCTAssertEqual(current.layers.count, 1)
        XCTAssertTrue(current.flows.isEmpty)
    }

    func testProposedElementIdsArePreserved() {
        let current = board(#"{"nodes":[{"id":"a","name":"a"}],"edges":[]}"#)
        let proposed = board(#"{"nodes":[{"id":"a","name":"a"},{"id":"b","name":"b"}],"edges":[]}"#)
        let proposedIDs = Set(proposed.elements.keys)

        var applied = current
        _ = try! applied.apply(ProposalApply.replaceOperation(
            current: current, proposed: proposed))
        XCTAssertEqual(Set(applied.elements.keys), proposedIDs)
    }
}
