import AppKit
import AVFoundation
import DesignerCanvas
import DesignerModel

/// Scripted demo (`--demo-flow <out.mov>`): builds a small system live on
/// the canvas — including parallel gRPC + HTTP connectors — records a flow by
/// walking the blocks, plays it back, and captures the window's content into
/// a movie the whole time. Recording happens in-process (no screen-recording
/// permission needed) and therefore contains ONLY the Designer window.
final class DemoFlowDriver {
    private let document: BoardDocument
    private let controller: CanvasViewController
    private let canvasView: CanvasView
    private let window: NSWindow
    private let outputURL: URL
    private var recorder: WindowMovieRecorder?

    init?(document: BoardDocument, outputURL: URL) {
        guard let window = document.windowControllers.first?.window,
              let controller = window.contentViewController as? CanvasViewController else {
            return nil
        }
        self.document = document
        self.controller = controller
        self.canvasView = controller.canvasView
        self.window = window
        self.outputURL = outputURL
    }

    // MARK: Script

    private var ids: [String: ElementID] = [:]

    func run() {
        NSApp.activate(ignoringOtherApps: true)
        window.setContentSize(NSSize(width: 1180, height: 720))
        window.center()
        window.makeKeyAndOrderFront(nil)
        // The first composited image can lag the window's appearance; retry
        // briefly instead of failing the whole demo.
        attemptStart(retriesLeft: 30)
    }

    private func attemptStart(retriesLeft: Int) {
        if let recorder = WindowMovieRecorder(window: window, outputURL: outputURL) {
            self.recorder = recorder
            recorder.start()
            runScript()
            return
        }
        guard retriesLeft > 0 else {
            FileHandle.standardError.write(Data("DEMO FAIL: cannot start movie writer\n".utf8))
            exit(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.attemptStart(retriesLeft: retriesLeft - 1)
        }
    }

    private func runScript() {
        var t = 0.6
        func at(_ delay: Double, _ action: @escaping () -> Void) {
            t += delay
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { action() }
        }

        // Build the system, one element at a time.
        at(0.4) { self.addNode("client", kind: .client, x: 40, y: 250) }
        at(0.9) { self.addNode("gateway", kind: .gateway, x: 300, y: 250) }
        at(0.9) { self.addNode("orders-svc", kind: .service, x: 700, y: 250) }
        at(0.9) { self.addNode("billing", kind: .service, x: 1000, y: 70) }
        at(0.9) { self.addNode("Postgres", kind: .database, shape: .ellipse, x: 1000, y: 430) }
        at(0.6) { self.canvasView.reveal(worldRect: Rect(x: -30, y: 10, width: 1240, height: 590)) }
        at(0.9) { self.connect("client", "gateway", label: "checkout", proto: "HTTPS") }
        at(1.0) { self.connect("gateway", "orders-svc", label: "create order", proto: "gRPC") }
        // The parallel pair — watch the two connectors spread apart.
        at(1.2) { self.connect("gateway", "orders-svc", label: "legacy path", proto: "HTTP") }
        at(1.2) { self.connect("orders-svc", "billing", label: "charge", proto: "gRPC") }
        at(1.0) { self.connect("orders-svc", "Postgres", label: "persist", proto: "SQL") }

        // Record the flow node-first: select the source, then walk the blocks.
        at(1.4) {
            self.canvasView.select([self.ids["client"]!])
        }
        at(0.9) { self.controller.recordFlow(nil) }
        at(1.6) { self.recordHop(to: "gateway") }
        at(1.6) { self.recordHop(to: "orders-svc", preferProtocol: "gRPC") } // the parallel choice
        at(1.6) { self.recordHop(to: "billing") }
        at(1.2) { self.recordHop(to: "Postgres") }

        // Save + play.
        at(1.4) { self.saveFlow(named: "Checkout (gRPC)") }
        at(1.0) { self.playSavedFlow() }
        at(9.0) { self.finish() }
    }

    // MARK: Actions

    private func addNode(_ name: String, kind: NodeKind, shape: NodeShape = .rectangle, x: Double, y: Double) {
        let element = Element(
            layerIDs: [document.board.layers[0].id],
            sortKey: document.board.topSortKey,
            content: .node(Node(
                semantic: NodeSemantic(kind: kind, name: name),
                frame: Rect(x: x, y: y, width: 150, height: 64),
                shape: shape
            ))
        )
        ids[name] = element.id
        document.perform(.insertElement(element), actionName: "Add Block")
    }

    private func connect(_ from: String, _ to: String, label: String, proto: String) {
        let element = Element(
            layerIDs: [document.board.layers[0].id],
            sortKey: document.board.topSortKey,
            content: .edge(Edge(
                semantic: EdgeSemantic(
                    label: label,
                    properties: [WellKnownEdgeProperty.protocolKey: proto]
                ),
                from: .element(ids[from]!, side: nil, offset: nil),
                to: .element(ids[to]!, side: nil, offset: nil)
            ))
        )
        document.perform(.insertElement(element), actionName: "Connect")
    }

    /// What clicking the target block does; for parallel connectors, what
    /// picking an entry in the chooser menu does.
    private func recordHop(to target: String, preferProtocol: String? = nil) {
        guard let recorder = canvasView.flowRecorder, let targetID = ids[target] else { return }
        let choices = recorder.candidates(to: targetID, in: document.board)
        let choice = choices.first { candidate in
            guard let preferProtocol else { return true }
            let edge = document.board.elements[candidate.edge]?.edge
            return edge?.semantic.properties[WellKnownEdgeProperty.protocolKey] == preferProtocol
        } ?? choices.first
        if let choice { canvasView.recordFlowCandidate(choice) }
    }

    private var savedFlowID: FlowID?

    private func saveFlow(named name: String) {
        guard let recorder = canvasView.finishFlowRecording() else { return }
        let flow = recorder.finish(
            name: name,
            colorIndex: document.board.flows.count % Graphite.flowColors.count
        )
        savedFlowID = flow.id
        document.perform(.insertFlow(flow, at: document.board.flows.count), actionName: "Record Flow")
    }

    private func playSavedFlow() {
        guard let flow = document.board.flows.first(where: { $0.id == savedFlowID }) else { return }
        canvasView.startFlowPlayback(flow)
    }

    private func finish() {
        recorder?.stop { url in
            print("DEMO PASS: \(url.path)")
            exit(0)
        }
    }
}

// MARK: - Window movie recorder

/// Captures a window's composited image at ~30 fps into an H.264 .mov via
/// AVAssetWriter. In-process by design: sandbox/TCC rules block external
/// screen capture, and this guarantees nothing but the app window is filmed.
/// (CGWindowList reads YOUR OWN window without capture permission, and takes
/// milliseconds where re-rendering via cacheDisplay took over a second.)
final class WindowMovieRecorder {
    private let windowID: CGWindowID
    private let outputURL: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let pixelSize: CGSize
    private var timer: Timer?
    private var startTime: CFTimeInterval = 0
    private var frameCount = 0
    /// Keeps App Nap from throttling the capture timer when the app runs
    /// unfocused (launched from a terminal).
    private var activity: NSObjectProtocol?

    init?(window: NSWindow, outputURL: URL) {
        self.windowID = CGWindowID(window.windowNumber)
        self.outputURL = outputURL
        // A probe grab fixes the movie dimensions (H.264 wants them even).
        guard let probe = Self.grab(windowID) else { return nil }
        pixelSize = CGSize(
            width: CGFloat(probe.width / 2 * 2),
            height: CGFloat(probe.height / 2 * 2)
        )
        try? FileManager.default.removeItem(at: outputURL)
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else { return nil }
        self.writer = writer
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(pixelSize.width),
                kCVPixelBufferHeightKey as String: Int(pixelSize.height),
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
    }

    func start() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled],
            reason: "Recording demo movie"
        )
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        startTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.captureFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop(completion: @escaping (URL) -> Void) {
        timer?.invalidate()
        timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        print("DEMO frames captured: \(frameCount)")
        input.markAsFinished()
        let url = outputURL
        writer.finishWriting {
            DispatchQueue.main.async { completion(url) }
        }
    }

    private func captureFrame() {
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        guard let cgImage = Self.grab(windowID) else { return }

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(pixelSize.width), height: Int(pixelSize.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: pixelSize))

        let elapsed = CACurrentMediaTime() - startTime
        if adaptor.append(buffer, withPresentationTime: CMTime(seconds: elapsed, preferredTimescale: 600)) {
            frameCount += 1
        }
    }

    private static func grab(_ windowID: CGWindowID) -> CGImage? {
        CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        )
    }
}
