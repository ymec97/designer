import AppKit
import DesignerModel
import DesignerPersistence

/// Renders a demo board to a PNG and exits:
///
///     Designer.app/Contents/MacOS/Designer --screenshot /path/out.png
///
/// Captures the real window content (canvas + toolbar) via cacheDisplay, so
/// what lands in the file is exactly what the app draws.
enum ScreenshotDriver {
    static func makeDemoBoard() -> Board {
        var board = Board(title: "Demo")
        board.layers[0].name = "Infra"
        board.layers.append(Layer(name: "Security", colorTint: "#D95757"))
        board.layers.append(Layer(name: "Data Flow", colorTint: "#4A90D9"))
        let layer = board.layers[0].id
        var keyIndex = 0
        func key() -> String {
            keyIndex += 1
            return SortKey.bulk(keyIndex, of: 64)
        }
        func node(
            _ name: String, _ kind: NodeKind, _ frame: Rect, shape: NodeShape = .rectangle
        ) -> Element {
            Element(
                layerIDs: [layer], sortKey: key(),
                content: .node(Node(
                    semantic: NodeSemantic(kind: kind, name: name),
                    frame: frame,
                    shape: shape
                ))
            )
        }

        let client = node("web-client", .client, Rect(x: 60, y: 200, width: 150, height: 70))
        let gateway = node("api-gateway", .gateway, Rect(x: 320, y: 200, width: 160, height: 70))
        let orders = node("orders-svc", .service, Rect(x: 600, y: 90, width: 150, height: 70))
        let payments = node("payments-svc", .service, Rect(x: 600, y: 310, width: 150, height: 70))
        let database = node("orders-db", .database, Rect(x: 830, y: 90, width: 140, height: 70), shape: .ellipse)
        let decision = node("fraud?", .service, Rect(x: 610, y: 470, width: 140, height: 100), shape: .diamond)
        let alert = node("alert", .external, Rect(x: 300, y: 470, width: 140, height: 110), shape: .triangle)
        for element in [client, gateway, orders, payments, database, decision, alert] {
            board.elements[element.id] = element
        }

        func edge(
            _ from: Element, _ to: Element, label: String?,
            protocolName: String? = nil, direction: EdgeDirection = .forward
        ) -> Element {
            var semantic = EdgeSemantic(label: label, direction: direction)
            if let protocolName {
                semantic.properties[WellKnownEdgeProperty.protocolKey] = protocolName
            }
            return Element(
                layerIDs: [layer], sortKey: key(),
                content: .edge(Edge(
                    semantic: semantic,
                    from: .element(from.id, side: nil, offset: nil),
                    to: .element(to.id, side: nil, offset: nil)
                ))
            )
        }

        let checkout = edge(client, gateway, label: "checkout", protocolName: "HTTPS")
        let toOrders = edge(gateway, orders, label: "order created", protocolName: "gRPC")
        let toPayments = edge(gateway, payments, label: "charge", protocolName: "gRPC", direction: .both)
        let toDatabase = edge(orders, database, label: nil)
        for element in [checkout, toOrders, toPayments, toDatabase] {
            board.elements[element.id] = element
        }

        // A dangling connector: its target was deleted.
        let dangling = Element(
            layerIDs: [layer], sortKey: key(),
            content: .edge(Edge(
                semantic: EdgeSemantic(label: "audit events"),
                from: .element(payments.id, side: nil, offset: nil),
                to: .free(Point(x: 940, y: 345))
            ))
        )
        board.elements[dangling.id] = dangling

        // A freehand annotation that stayed ink (on the Security layer).
        let ink = Element(
            layerIDs: [board.layers[1].id], sortKey: key(),
            content: .ink(Ink(
                points: (0...30).map { i in
                    let t = Double(i) / 30
                    return StrokePoint(
                        x: 90 + t * 150 + sin(t * 14) * 6,
                        y: 330 + t * 18 + cos(t * 11) * 5,
                        pressure: 0.4 + 0.3 * sin(t * .pi)
                    )
                },
                style: Style(strokeWidth: 2)
            ))
        )
        board.elements[ink.id] = ink

        return board
    }

    static func run(saveTo url: URL) {
        let controller = NSDocumentController.shared
        guard let typeName = controller.defaultType,
              let document = try? controller.makeUntitledDocument(ofType: typeName) as? BoardDocument
        else {
            FileHandle.standardError.write(Data("SCREENSHOT FAIL: cannot create document\n".utf8))
            exit(1)
        }
        controller.addDocument(document)
        document.board = makeDemoBoard()
        document.makeWindowControllers()
        document.showWindows()

        guard let window = document.windowControllers.first?.window,
              let contentView = window.contentViewController?.view else {
            FileHandle.standardError.write(Data("SCREENSHOT FAIL: no window\n".utf8))
            exit(1)
        }
        window.setContentSize(NSSize(width: 1140, height: 700))
        window.makeKeyAndOrderFront(nil)
        if let controller = window.contentViewController as? CanvasViewController {
            controller.toggleLayersPanel(nil) // show the panel in the capture
        }

        // Give layout + SwiftUI toolbar one runloop turn, then capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
                FileHandle.standardError.write(Data("SCREENSHOT FAIL: no bitmap\n".utf8))
                exit(1)
            }
            contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("SCREENSHOT FAIL: png encode\n".utf8))
                exit(1)
            }
            do {
                try png.write(to: url)
                print("SCREENSHOT PASS: \(url.path)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("SCREENSHOT FAIL: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }
}
