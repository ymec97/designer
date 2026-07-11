import AppKit
import DesignerCanvas
import DesignerModel

/// Scripted navigation benchmark over a synthetic 2,000-node board — the M1
/// exit criterion (D12) as a repeatable command:
///
///     Designer.app/Contents/MacOS/Designer --perf-test
///
/// Three phases (pan at 1×, pan zoomed-out with all nodes visible, continuous
/// zoom), driven by a display link so every tick is one intended frame.
/// Reports frame pacing and exits 0 only if dropped frames stay under 2%.
final class PerfTestDriver: NSObject {
    static let nodeCount = 2000
    private static let phaseDuration: CFTimeInterval = 2.5

    private let canvasView: CanvasView
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var deltas: [Double] = []
    private var phases: [Int] = []
    private var initialViewport = CanvasViewport()
    private var fitViewport = CanvasViewport()

    static func makeSyntheticBoard() -> Board {
        var board = Board(title: "Perf \(nodeCount)")
        let layerID = board.layers[0].id
        let kinds: [NodeKind] = [.service, .database, .queue, .cache, .gateway, .client]
        let totalElements = nodeCount * 3 // nodes + up to ~2 edges each
        var elementIndex = 0
        var nodeIDs: [ElementID] = []
        for i in 0..<nodeCount {
            let key = SortKey.bulk(elementIndex, of: totalElements)
            elementIndex += 1
            let element = Element(
                layerIDs: [layerID],
                sortKey: key,
                content: .node(Node(
                    semantic: NodeSemantic(
                        kind: kinds[i % kinds.count],
                        name: "service-\(i)"
                    ),
                    frame: Rect(
                        x: Double(i % 50) * 220,
                        y: Double(i / 50) * 140,
                        width: 160, height: 80
                    )
                ))
            )
            board.elements[element.id] = element
            nodeIDs.append(element.id)
        }

        // ~4k connectors (D12): grid neighbors right + down, mixed routing,
        // captions on a subset to exercise the label path.
        var edgeCount = 0
        for i in 0..<nodeCount {
            for target in [i % 50 < 49 ? i + 1 : nil, i + 50 < nodeCount ? i + 50 : nil].compactMap({ $0 }) {
                let key = SortKey.bulk(elementIndex, of: totalElements)
                elementIndex += 1
                var semantic = EdgeSemantic()
                if edgeCount % 5 == 0 {
                    semantic.label = "call \(edgeCount)"
                    semantic.properties[WellKnownEdgeProperty.protocolKey] = "gRPC"
                }
                let element = Element(
                    layerIDs: [layerID],
                    sortKey: key,
                    content: .edge(Edge(
                        semantic: semantic,
                        from: .element(nodeIDs[i], side: nil, offset: nil),
                        to: .element(nodeIDs[target], side: nil, offset: nil),
                        routing: edgeCount % 3 == 0 ? .orthogonal : .straight
                    ))
                )
                board.elements[element.id] = element
                edgeCount += 1
            }
        }
        return board
    }

    init(canvasView: CanvasView) {
        self.canvasView = canvasView
        super.init()
    }

    func start() {
        if CommandLine.arguments.contains("--perf-probe") {
            var counter = 0
            CanvasView.perfProbe = { report in
                counter += 1
                if counter % 45 == 0 { print("PROBE", report) }
            }
        }
        canvasView.zoomToFit(nil)
        fitViewport = canvasView.viewport
        var start = fitViewport
        start.setScale(1, at: CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY))
        initialViewport = start
        canvasView.viewport = start

        let link = canvasView.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link

        // The display link silently pauses when the window is occluded
        // (locked screen, display asleep). Fail loudly instead of hanging.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.startTime == 0 else { return }
            FileHandle.standardError.write(Data(
                "PERF-TEST STALLED: display link never fired — the screen is likely locked or asleep. Run again with the display awake.\n".utf8
            ))
            exit(2)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        if startTime == 0 {
            startTime = link.timestamp
            lastTimestamp = link.timestamp
            return
        }
        let elapsed = link.timestamp - startTime
        let phase = Int(elapsed / Self.phaseDuration)
        deltas.append(link.timestamp - lastTimestamp)
        phases.append(phase)
        lastTimestamp = link.timestamp
        let t = (elapsed - Double(phase) * Self.phaseDuration) / Self.phaseDuration

        switch phase {
        case 0:
            // Pan at working zoom (~100 nodes visible).
            var viewport = initialViewport
            viewport.origin.x += sin(t * 2 * .pi) * 1200
            viewport.origin.y += cos(t * 2 * .pi) * 800
            canvasView.viewport = viewport
        case 1:
            // Pan fully zoomed out: all 2,000 nodes on screen — worst case.
            var viewport = fitViewport
            viewport.origin.x += sin(t * 2 * .pi) * 900
            canvasView.viewport = viewport
        case 2:
            // Continuous zoom through the full range.
            var viewport = fitViewport
            let scale = fitViewport.scale * pow(1 / fitViewport.scale, 0.5 + 0.5 * sin(t * 2 * .pi))
            viewport.setScale(scale, at: CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY))
            canvasView.viewport = viewport
        default:
            finish(refreshInterval: link.duration)
        }
    }

    private func finish(refreshInterval: CFTimeInterval) {
        displayLink?.invalidate()
        displayLink = nil

        let sorted = deltas.sorted()
        guard !sorted.isEmpty else {
            print("PERF-TEST FAIL: no frames recorded")
            exit(1)
        }
        let nominal = refreshInterval > 0 ? refreshInterval : sorted[sorted.count / 2]
        let average = deltas.reduce(0, +) / Double(deltas.count)
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        let dropped = deltas.filter { $0 > nominal * 1.6 }.count
        let droppedFraction = Double(dropped) / Double(deltas.count)

        let edgeCount = canvasView.board.elements.values.filter { $0.edge != nil }.count
        let report = String(
            format: "PERF-TEST nodes=%d edges=%d refresh=%.1fHz frames=%d avg=%.2fms p95=%.2fms max=%.2fms dropped=%d (%.1f%%)",
            Self.nodeCount, edgeCount, 1 / nominal, deltas.count,
            average * 1000, p95 * 1000, (sorted.last ?? 0) * 1000,
            dropped, droppedFraction * 100
        )
        print(report)

        for phase in 0...2 {
            let phaseDeltas = zip(phases, deltas).filter { $0.0 == phase }.map(\.1)
            guard !phaseDeltas.isEmpty else { continue }
            let phaseAverage = phaseDeltas.reduce(0, +) / Double(phaseDeltas.count)
            let phaseDropped = phaseDeltas.filter { $0 > nominal * 1.6 }.count
            let names = ["pan@1x", "pan@fit", "zoom-sweep"]
            print(String(
                format: "  phase %d (%@): avg=%.2fms dropped=%d/%d",
                phase, names[phase], phaseAverage * 1000, phaseDropped, phaseDeltas.count
            ))
        }

        if droppedFraction < 0.02 {
            print("PERF-TEST PASS")
            exit(0)
        } else {
            print("PERF-TEST FAIL: dropped-frame budget exceeded")
            exit(1)
        }
    }
}
