import DesignerModel

/// A small, real-looking system used for onboarding (opened on first launch
/// and via Help ▸ Open Example). Shows nodes of several kinds, labeled
/// connectors with protocols, an ellipse datastore, and two layers.
enum ExampleBoard {
    static func make() -> Board {
        var board = Board(title: "Example System")
        board.layers[0].name = "Infra"
        let infra = board.layers[0].id
        let flowLayer = Layer(name: "Data Flow", colorTint: "#4A90D9")
        let flow = flowLayer.id
        board.layers.append(flowLayer)

        var key = 0
        func nextKey() -> String { defer { key += 1 }; return SortKey.bulk(key, of: 32) }
        func node(_ name: String, _ kind: NodeKind, _ frame: Rect, shape: NodeShape = .rectangle) -> Element {
            Element(
                layerIDs: [infra], sortKey: nextKey(),
                content: .node(Node(semantic: NodeSemantic(kind: kind, name: name), frame: frame, shape: shape))
            )
        }

        let client = node("web-client", .client, Rect(x: 80, y: 180, width: 150, height: 70))
        let gateway = node("api-gateway", .gateway, Rect(x: 320, y: 180, width: 160, height: 70))
        let orders = node("orders-svc", .service, Rect(x: 580, y: 80, width: 150, height: 70))
        let payments = node("payments-svc", .service, Rect(x: 580, y: 280, width: 150, height: 70))
        let database = node("orders-db", .database, Rect(x: 820, y: 80, width: 140, height: 70), shape: .ellipse)
        let queue = node("events", .queue, Rect(x: 820, y: 280, width: 140, height: 70))
        for element in [client, gateway, orders, payments, database, queue] {
            board.elements[element.id] = element
        }

        func edge(_ from: Element, _ to: Element, _ label: String, _ proto: String, both: Bool = false) -> Element {
            Element(
                layerIDs: [flow], sortKey: nextKey(),
                content: .edge(Edge(
                    semantic: EdgeSemantic(
                        label: label,
                        direction: both ? .both : .forward,
                        properties: [WellKnownEdgeProperty.protocolKey: proto]
                    ),
                    from: .element(from.id, side: nil, offset: nil),
                    to: .element(to.id, side: nil, offset: nil)
                ))
            )
        }
        let edges = [
            edge(client, gateway, "checkout", "HTTPS"),
            edge(gateway, orders, "create order", "gRPC"),
            edge(gateway, payments, "charge", "gRPC", both: true),
            edge(orders, database, "persist", "SQL"),
            edge(payments, queue, "payment.event", "Kafka"),
        ]
        for element in edges { board.elements[element.id] = element }

        let note = Element(
            layerIDs: [infra], sortKey: nextKey(),
            content: .note(Note(
                text: "Draw a box or arrow with the Draw tool (D) — sketches snap into shapes.",
                frame: Rect(x: 80, y: 380, width: 420, height: 40)
            ))
        )
        board.elements[note.id] = note
        return board
    }
}
