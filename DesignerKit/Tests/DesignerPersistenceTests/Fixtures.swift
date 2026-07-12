import Foundation
import DesignerModel

/// Builds a board exercising every element role, both anchor types, unknown
/// fields at several levels, and non-trivial semantics — the shared fixture
/// for round-trip and persistence tests.
enum Fixtures {
    static func sampleBoard() -> Board {
        let infraLayer = Layer(name: "Infra", colorTint: "#4A90D9")
        let dataLayer = Layer(name: "Data Flow", isVisible: true)
        let securityLayer = Layer(name: "Security", isVisible: false, isLocked: true)

        let apiNode = Element(
            layerIDs: [infraLayer.id, dataLayer.id],
            sortKey: "i",
            content: .node(Node(
                semantic: NodeSemantic(
                    kind: .gateway,
                    name: "api-gateway",
                    tags: ["edge", "public"],
                    properties: ["region": "eu-west-1"]
                ),
                frame: Rect(x: 100, y: 100, width: 160, height: 80),
                style: Style(fill: "#FFFFFF", stroke: "#333333", strokeWidth: 1.5)
            ))
        )

        let dbNode = Element(
            layerIDs: [infraLayer.id],
            sortKey: SortKey.after("i"),
            content: .node(Node(
                semantic: NodeSemantic(kind: .database, name: "orders-db"),
                frame: Rect(x: 400, y: 100, width: 140, height: 80),
                shape: .ellipse
            )),
            extra: ["futureField": .string("preserved")]
        )

        let edge = Element(
            layerIDs: [dataLayer.id],
            sortKey: SortKey.after(dbNode.sortKey),
            content: .edge(Edge(
                semantic: EdgeSemantic(
                    label: "order created",
                    direction: .forward,
                    properties: [
                        WellKnownEdgeProperty.protocolKey: "gRPC",
                        WellKnownEdgeProperty.data: "OrderEvent",
                        WellKnownEdgeProperty.condition: "on checkout",
                    ]
                ),
                from: .element(apiNode.id, side: .right, offset: 0.5),
                to: .element(dbNode.id, side: nil, offset: nil),
                routing: .orthogonal,
                waypoints: [Point(x: 300, y: 140)]
            ))
        )

        let ink = Element(
            layerIDs: [securityLayer.id],
            sortKey: SortKey.after(edge.sortKey),
            content: .ink(Ink(
                points: [
                    StrokePoint(x: 10, y: 10, pressure: 0.4, time: 0),
                    StrokePoint(x: 20, y: 14, pressure: 0.8, time: 0.016),
                    StrokePoint(x: 32, y: 22, pressure: 0.9, time: 0.031),
                ],
                style: Style(stroke: "#D0021B", strokeWidth: 2)
            ))
        )

        let note = Element(
            layerIDs: [infraLayer.id],
            sortKey: SortKey.after(ink.sortKey),
            content: .note(Note(
                text: "Trust boundary: everything right of the gateway is internal.",
                frame: Rect(x: 100, y: 250, width: 300, height: 60)
            ))
        )

        let group = Group(name: "storage", memberIDs: [dbNode.id])

        var board = Board(
            title: "Sample System",
            layers: [infraLayer, dataLayer, securityLayer],
            elements: [apiNode, dbNode, edge, ink, note],
            groups: [group]
        )
        board.extra = ["boardLevelFutureField": .object(["nested": .bool(true)])]
        return board
    }
}
