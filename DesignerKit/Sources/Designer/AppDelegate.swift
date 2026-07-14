import AppKit
import DesignerAgent
import DesignerModel
import DesignerPersistence

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private static let hasLaunchedKey = "HasLaunchedBefore"

    private var isTestRun: Bool { CommandLine.arguments.contains { $0.hasPrefix("--") } }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        AppActions.newCanvas = { [weak self] in self?.newCanvas() }
        AppActions.open = { [weak self] url in self?.open(url) }
        AppActions.openPanel = { NSDocumentController.shared.openDocument(nil) }
        AppActions.openExample = { [weak self] in self?.openExampleBoard(nil) }
    }

    /// The start screen replaces the blank-document behaviour: on launch (or
    /// when the last window closes) we show the catalog, not an empty canvas.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if isTestRun { return false }
        // First ever launch seeds the example board so the catalog isn't empty.
        if !UserDefaults.standard.bool(forKey: Self.hasLaunchedKey) {
            UserDefaults.standard.set(true, forKey: Self.hasLaunchedKey)
            DispatchQueue.main.async { self.openExampleBoard(nil) }
            return false
        }
        DispatchQueue.main.async { CatalogWindowController.shared.present() }
        return false
    }

    /// Re-show the catalog when the user closes the last document window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, !isTestRun { CatalogWindowController.shared.present() }
        return true
    }

    /// Headless catalog check: writes boards into a temp folder, verifies the
    /// index lists them newest-first, and that new-board naming avoids
    /// collisions. Exits 0 on success.
    private func runCatalogTest() {
        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("CATALOG-TEST FAIL: \(message)\n".utf8))
            exit(1)
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        func writeBoard(_ title: String, modified: Date) {
            var board = DesignerModel.Board(title: title)
            board.modifiedAt = modified
            let url = temp.appendingPathComponent("\(title).\(BoardPackage.fileExtension)")
            try? BoardPackage.write(board, to: url)
        }
        writeBoard("Older", modified: Date(timeIntervalSince1970: 1_000_000))
        writeBoard("Newer", modified: Date(timeIntervalSince1970: 2_000_000))

        let entries = BoardCatalog.entries(in: temp, includeRecents: false)
        guard entries.count == 2 else { fail("expected 2 entries, got \(entries.count)") }
        guard entries.map(\.title) == ["Newer", "Older"] else {
            fail("entries not sorted newest-first: \(entries.map(\.title))")
        }
        let fresh = BoardCatalog.newBoardURL(in: temp)
        guard !FileManager.default.fileExists(atPath: fresh.path) else {
            fail("newBoardURL returned an existing path")
        }
        print("CATALOG-TEST PASS: \(entries.count) entries, sorted, fresh URL OK")
        exit(0)
    }

    /// Seeds a few boards into the managed folder, presents the catalog, and
    /// captures it — for reviewing the start screen. Cleans up the seeds.
    private func runCatalogScreenshot(saveTo url: URL) {
        if CommandLine.arguments.contains("--dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        let folder = BoardCatalog.boardsFolder()
        var seeded: [URL] = []
        for (title, board) in [
            ("Checkout flow", ExampleBoard.make()),
            ("Payments platform", ExampleBoard.make()),
            ("Event pipeline", ExampleBoard.make()),
        ] {
            var b = board; b.title = title
            let boardURL = folder.appendingPathComponent("__demo_\(title).\(BoardPackage.fileExtension)")
            try? BoardPackage.write(b, to: boardURL)
            seeded.append(boardURL)
        }
        CatalogWindowController.shared.present()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            defer { seeded.forEach { try? FileManager.default.removeItem(at: $0) } }
            guard let view = CatalogWindowController.shared.window?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                exit(1)
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
                print("CATALOG-SHOT PASS: \(url.path)")
            }
            exit(0)
        }
    }

    /// Loads the example board, runs a simulation, and captures a mid-flow
    /// frame — for reviewing the animation styling.
    private func runSimulationScreenshot(saveTo url: URL) {
        if CommandLine.arguments.contains("--dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        let controller = NSDocumentController.shared
        guard let typeName = controller.defaultType,
              let document = try? controller.makeUntitledDocument(ofType: typeName) as? BoardDocument else {
            exit(1)
        }
        document.board = ExampleBoard.make()
        controller.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        guard let window = document.windowControllers.first?.window,
              let canvasController = window.contentViewController as? CanvasViewController else { exit(1) }
        window.setContentSize(NSSize(width: 1140, height: 700))
        window.makeKeyAndOrderFront(nil)

        // Source = the gateway (fans out to services).
        let source = document.board.elements.values.first { $0.node?.semantic.name == "api-gateway" }?.id
            ?? document.board.elements.values.first { $0.node != nil }?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let source { canvasController.canvasView.startSimulation(from: source) }
            canvasController.canvasView.simulationSpeed = 0.6
            // Capture partway through the flow.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                let view = canvasController.view
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: url)
                    print("SIM-SHOT PASS: \(url.path)")
                }
                exit(0)
            }
        }
    }

    @objc func showCatalog(_ sender: Any?) {
        CatalogWindowController.shared.present()
    }

    /// Builds the correlated-traffic demo (parallel gRPC+HTTP connectors),
    /// records the gRPC journey as a flow, opens the Flows panel, and captures
    /// playback mid-flight — for reviewing the F5 visuals.
    private func runFlowsScreenshot(saveTo url: URL) {
        if CommandLine.arguments.contains("--dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        var board = Board(title: "Correlated traffic")
        let layer = board.layers[0].id
        func node(_ name: String, _ kind: NodeKind, _ x: Double, _ y: Double) -> Element {
            let element = Element(layerIDs: [layer], sortKey: board.topSortKey,
                                  content: .node(Node(semantic: NodeSemantic(kind: kind, name: name),
                                                      frame: Rect(x: x, y: y, width: 150, height: 70))))
            try? board.apply(.insertElement(element))
            return element
        }
        func edge(_ from: Element, _ to: Element, _ proto: String, label: String, condition: String? = nil) -> Element {
            var properties = [WellKnownEdgeProperty.protocolKey: proto]
            if let condition { properties[WellKnownEdgeProperty.condition] = condition }
            let element = Element(layerIDs: [layer], sortKey: board.topSortKey,
                                  content: .edge(Edge(
                                      semantic: EdgeSemantic(label: label, properties: properties),
                                      from: .element(from.id, side: nil, offset: nil),
                                      to: .element(to.id, side: nil, offset: nil))))
            try? board.apply(.insertElement(element))
            return element
        }
        let a = node("service-a", .service, 120, 240)
        let b = node("service-b", .service, 480, 240)
        let c = node("service-c", .service, 840, 240)
        let abGRPC = edge(a, b, "gRPC", label: "create order")
        _ = edge(a, b, "HTTP", label: "health")
        let bcGRPC = edge(b, c, "gRPC", label: "reserve stock", condition: "only when gRPC in")
        _ = edge(b, c, "HTTP", label: "metrics")

        let flow = Flow(name: "gRPC journey", source: a.id, steps: [
            Flow.Step(edges: [abGRPC.id], nodes: [b.id]),
            Flow.Step(edges: [bcGRPC.id], nodes: [c.id]),
        ], colorIndex: 1)
        board.flows = [flow]

        let controller = NSDocumentController.shared
        guard let typeName = controller.defaultType,
              let document = try? controller.makeUntitledDocument(ofType: typeName) as? BoardDocument else { exit(1) }
        document.board = board
        controller.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        guard let window = document.windowControllers.first?.window,
              let canvasController = window.contentViewController as? CanvasViewController else { exit(1) }
        window.setContentSize(NSSize(width: 1140, height: 700))
        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            canvasController.toggleFlowsPanel(nil)
            canvasController.canvasView.simulationSpeed = 0.55
            canvasController.canvasView.startFlowPlayback(flow)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
                let view = canvasController.view
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: url)
                    print("FLOWS-SHOT PASS: \(url.path)")
                }
                exit(0)
            }
        }
    }

    /// Headless end-to-end agent check: opens the example board, enables the
    /// real MCP server, and drives it over actual localhost HTTP the way
    /// Claude Desktop would — initialize, get_board, then propose_board with
    /// an added block — verifying the proposal lands as pending in the window.
    private func runAgentTest() {
        func fail(_ message: String) {
            FileHandle.standardError.write(Data("AGENT-TEST FAIL: \(message)\n".utf8))
            exit(1)
        }
        let controller = NSDocumentController.shared
        guard let typeName = controller.defaultType,
              let document = try? controller.makeUntitledDocument(ofType: typeName) as? BoardDocument else {
            fail("no document"); return
        }
        document.board = ExampleBoard.make()
        controller.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        guard let canvasController = document.windowControllers.first?.window?.contentViewController as? CanvasViewController else {
            fail("no controller"); return
        }

        try? AgentController.shared.enable { port in
            DispatchQueue.global().async {
                func post(_ body: String) -> [String: Any] {
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
                    request.httpMethod = "POST"
                    request.httpBody = Data(body.utf8)
                    var out: [String: Any] = [:]
                    let sema = DispatchSemaphore(value: 0)
                    URLSession.shared.dataTask(with: request) { data, _, _ in
                        if let data { out = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }
                        sema.signal()
                    }.resume()
                    sema.wait()
                    return out
                }
                func toolText(_ r: [String: Any]) -> String {
                    (((r["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                }

                let initReply = post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
                guard ((initReply["result"] as? [String: Any])?["protocolVersion"] as? String) == "2025-03-26" else {
                    fail("initialize didn't echo protocol version"); return
                }
                let boardText = toolText(post(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_board","arguments":{}}}"#))
                guard boardText.contains("api-gateway") else { fail("get_board missing content"); return }

                // Edit the returned board: append one node (no position → auto-layout).
                guard let key = boardText.range(of: "\"nodes\""),
                      let open = boardText.range(of: "[", range: key.upperBound..<boardText.endIndex) else {
                    fail("couldn't find nodes array"); return
                }
                var edited = boardText
                edited.insert(contentsOf: "\n    {\"id\": \"agent-cache\", \"kind\": \"cache\", \"name\": \"agent-cache\"},", at: open.upperBound)
                let proposal: [String: Any] = [
                    "jsonrpc": "2.0", "id": 3, "method": "tools/call",
                    "params": ["name": "propose_board", "arguments": ["board": edited, "note": "e2e"]],
                ]
                let proposalData = try! JSONSerialization.data(withJSONObject: proposal)
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
                request.httpMethod = "POST"
                request.httpBody = proposalData
                var replyText = ""
                let sema = DispatchSemaphore(value: 0)
                URLSession.shared.dataTask(with: request) { data, _, _ in
                    if let data, let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        replyText = toolText(r)
                    }
                    sema.signal()
                }.resume()
                sema.wait()
                guard replyText.contains("+1 block") else { fail("propose diff wrong: \(replyText)"); return }

                DispatchQueue.main.async {
                    guard canvasController.hasPendingProposal else { fail("proposal not pending in window"); return }
                    canvasController.acceptAgentProposal(nil)
                    let added = document.board.elements.values.contains { $0.node?.semantic.name == "agent-cache" }
                    guard added else { fail("accept didn't add the block"); return }
                    print("AGENT-TEST PASS: initialize→get_board→propose→accept over live localhost MCP")
                    exit(0)
                }
            }
        }
    }

    /// Opens the example board, stages an agent proposal (add a cache), and
    /// captures the review banner — for reviewing the proposal UI.
    private func runProposalScreenshot(saveTo url: URL) {
        if CommandLine.arguments.contains("--dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        let controller = NSDocumentController.shared
        guard let typeName = controller.defaultType,
              let document = try? controller.makeUntitledDocument(ofType: typeName) as? BoardDocument else { exit(1) }
        document.board = ExampleBoard.make()
        controller.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        guard let window = document.windowControllers.first?.window,
              let canvasController = window.contentViewController as? CanvasViewController else { exit(1) }
        window.setContentSize(NSSize(width: 1140, height: 720))
        window.makeKeyAndOrderFront(nil)

        // Propose: relabel a service and add a cache in front of it.
        var proposed = document.board
        if let orders = proposed.elements.values.first(where: { $0.node?.semantic.name == "orders-svc" }),
           var node = orders.node {
            let layer = proposed.layers[0].id
            let cache = Element(layerIDs: [layer], sortKey: proposed.topSortKey,
                                content: .node(Node(semantic: NodeSemantic(kind: .cache, name: "orders-cache"),
                                                    frame: Rect(x: node.frame.x, y: node.frame.y - 160, width: 150, height: 70))))
            try? proposed.apply(.insertElement(cache))
            node.semantic.name = "orders-service"
            var updated = orders; updated.content = .node(node)
            try? proposed.apply(.replaceElement(updated))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            canvasController.presentAgentProposal(proposed, note: "Add a read cache in front of orders and rename it for clarity.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let view = canvasController.view
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: url)
                    print("PROPOSAL-SHOT PASS: \(url.path)")
                }
                exit(0)
            }
        }
    }

    static let agentAccessKey = "AgentAccessEnabled"

    /// Toggle the local agent (MCP) server. On enable, show the endpoint the
    /// user pastes into Claude Desktop (or any MCP client); it stays local.
    /// The choice persists — the server auto-starts on future launches.
    @objc func toggleAgentAccess(_ sender: Any?) {
        if AgentController.shared.isEnabled {
            AgentController.shared.disable()
            UserDefaults.standard.set(false, forKey: Self.agentAccessKey)
            return
        }
        do {
            try AgentController.shared.enable { port in
                UserDefaults.standard.set(true, forKey: Self.agentAccessKey)
                let alert = NSAlert()
                alert.messageText = "Agent access is on"
                var body = """
                An agent on this Mac can now read your board and propose edits \
                (you approve each change). Add this as a custom connector in \
                Claude Desktop or another MCP client:

                http://127.0.0.1:\(port)/mcp

                It listens on this Mac only, and stays enabled across launches \
                until you turn it off from the Board menu.
                """
                if port != AgentServer.defaultPort {
                    body += "\n\n⚠️ The usual port (\(AgentServer.defaultPort)) was taken, so this launch uses \(port) — update your connector if you saved the old address."
                }
                alert.informativeText = body
                alert.addButton(withTitle: "Copy Endpoint")
                alert.addButton(withTitle: "Done")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AgentController.shared.endpointURL, forType: .string)
                }
            }
        } catch {
            NSApp.presentError(error)
        }
    }

    /// Auto-start the server on launch when the user previously enabled it.
    func restoreAgentAccessIfEnabled() {
        guard UserDefaults.standard.bool(forKey: Self.agentAccessKey),
              !AgentController.shared.isEnabled else { return }
        try? AgentController.shared.enable { _ in }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAgentAccess(_:)) {
            let enabled = AgentController.shared.isEnabled
            menuItem.state = enabled ? .on : .off
            menuItem.title = enabled
                ? "Agent Access: On (port \(AgentController.shared.server.port))"
                : "Enable Agent Access"
        }
        return true
    }

    @objc func newCanvasMenu(_ sender: Any?) { newCanvas() }

    /// A new canvas is saved into the managed Boards folder immediately, so it
    /// is tracked, autosaves in place, and appears in the catalog next time.
    @objc func newCanvas() {
        let controller = NSDocumentController.shared
        guard let typeName = controller.defaultType,
              let document = try? controller.makeUntitledDocument(ofType: typeName) as? BoardDocument else {
            return
        }
        let url = BoardCatalog.newBoardURL()
        document.board.title = url.deletingPathExtension().lastPathComponent
        controller.addDocument(document)
        document.save(to: url, ofType: typeName, for: .saveOperation) { _ in
            document.makeWindowControllers()
            document.showWindows()
            CatalogWindowController.shared.window?.close()
        }
    }

    func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in
            CatalogWindowController.shared.window?.close()
        }
    }

    @objc func openExampleBoard(_ sender: Any?) {
        let controller = NSDocumentController.shared
        guard let typeName = controller.defaultType,
              let document = try? controller.makeUntitledDocument(ofType: typeName) as? BoardDocument else {
            return
        }
        document.board = ExampleBoard.make()
        controller.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        CatalogWindowController.shared.window?.close()
    }

    private var perfTestDriver: PerfTestDriver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--version") {
            let info = Bundle.main.infoDictionary ?? [:]
            let version = info["CFBundleShortVersionString"] as? String ?? "dev"
            let build = info["CFBundleVersion"] as? String ?? "0"
            let buildInfo = info["DesignerBuildInfo"] as? String ?? ""
            print("Designer v\(version) (build \(build)\(buildInfo.isEmpty ? "" : ", \(buildInfo)"))")
            exit(0)
        }
        if !isTestRun {
            restoreAgentAccessIfEnabled()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--smoke-test"),
           CommandLine.arguments.indices.contains(index + 1) {
            runSmokeTest(saveTo: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        if CommandLine.arguments.contains("--perf-test") {
            runPerfTest()
        }
        if CommandLine.arguments.contains("--ui-test") {
            runUITest()
        }
        if CommandLine.arguments.contains("--catalog-test") {
            runCatalogTest()
        }
        if CommandLine.arguments.contains("--agent-test") {
            runAgentTest()
        }
        // Scripted feature demo, self-recorded to a movie (see DemoFlow.swift).
        if let index = CommandLine.arguments.firstIndex(of: "--demo-flow"),
           CommandLine.arguments.indices.contains(index + 1) {
            runFlowDemo(saveTo: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        // Debug/testing: open the example board with the agent server running
        // and stay alive (drive it externally, e.g. from the claude CLI).
        if CommandLine.arguments.contains("--agent-serve") {
            let controller = NSDocumentController.shared
            if let typeName = controller.defaultType,
               let document = try? controller.makeUntitledDocument(ofType: typeName) as? BoardDocument {
                document.board = ExampleBoard.make()
                controller.addDocument(document)
                document.makeWindowControllers()
                document.showWindows()
                try? AgentController.shared.enable { port in
                    print("AGENT-SERVE READY: http://127.0.0.1:\(port)/mcp")
                }
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--screenshot-catalog"),
           CommandLine.arguments.indices.contains(index + 1) {
            runCatalogScreenshot(saveTo: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--screenshot-sim"),
           CommandLine.arguments.indices.contains(index + 1) {
            runSimulationScreenshot(saveTo: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--screenshot-proposal"),
           CommandLine.arguments.indices.contains(index + 1) {
            runProposalScreenshot(saveTo: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--screenshot-flows"),
           CommandLine.arguments.indices.contains(index + 1) {
            runFlowsScreenshot(saveTo: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--screenshot"),
           CommandLine.arguments.indices.contains(index + 1) {
            ScreenshotDriver.run(saveTo: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
    }

    private var demoFlowDriver: DemoFlowDriver?

    private func runFlowDemo(saveTo url: URL) {
        let controller = NSDocumentController.shared
        guard let typeName = controller.defaultType,
              let document = try? controller.makeUntitledDocument(ofType: typeName) as? BoardDocument
        else {
            FileHandle.standardError.write(Data("DEMO FAIL: cannot create document\n".utf8))
            exit(1)
        }
        controller.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        guard let driver = DemoFlowDriver(document: document, outputURL: url) else {
            FileHandle.standardError.write(Data("DEMO FAIL: no canvas window or writer\n".utf8))
            exit(1)
        }
        demoFlowDriver = driver
        DispatchQueue.main.async { driver.run() }
    }

    private func runUITest() {
        let controller = NSDocumentController.shared
        guard let typeName = controller.defaultType,
              let document = try? controller.makeUntitledDocument(ofType: typeName) as? BoardDocument
        else {
            FileHandle.standardError.write(Data("UI-TEST FAIL: cannot create document\n".utf8))
            exit(1)
        }
        controller.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        guard let driver = UITestDriver(document: document) else {
            FileHandle.standardError.write(Data("UI-TEST FAIL: no canvas window\n".utf8))
            exit(1)
        }
        DispatchQueue.main.async { driver.run() }
    }

    /// See PerfTestDriver — the M1/D12 frame-pacing criterion as a command.
    private func runPerfTest() {
        let controller = NSDocumentController.shared
        guard let typeName = controller.defaultType,
              let document = try? controller.makeUntitledDocument(ofType: typeName) as? BoardDocument
        else {
            FileHandle.standardError.write(Data("PERF-TEST FAIL: cannot create document\n".utf8))
            exit(1)
        }
        controller.addDocument(document)
        document.board = PerfTestDriver.makeSyntheticBoard()
        document.makeWindowControllers()
        document.showWindows()

        guard let canvasController = document.windowControllers.first?.contentViewController
                as? CanvasViewController else {
            FileHandle.standardError.write(Data("PERF-TEST FAIL: no canvas controller\n".utf8))
            exit(1)
        }
        let driver = PerfTestDriver(canvasView: canvasController.canvasView)
        perfTestDriver = driver
        // Give the window one runloop turn to lay out before measuring.
        DispatchQueue.main.async { driver.start() }
    }

    /// Headless end-to-end check of the real NSDocument pipeline: create an
    /// untitled document, mutate it, save it through NSDocument's own save
    /// machinery, read the package back, verify. Exits 0 on success.
    ///
    ///     Designer.app/Contents/MacOS/Designer --smoke-test /tmp/out.designerboard
    private func runSmokeTest(saveTo url: URL) {
        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("SMOKE-TEST FAIL: \(message)\n".utf8))
            exit(1)
        }

        let controller = NSDocumentController.shared
        guard let typeName = controller.defaultType else { fail("no default document type") }
        do {
            let document = try controller.makeUntitledDocument(ofType: typeName)
            guard let boardDocument = document as? BoardDocument else {
                fail("untitled document is \(type(of: document)), not BoardDocument")
            }
            controller.addDocument(boardDocument)
            boardDocument.makeWindowControllers()
            boardDocument.showWindows()
            boardDocument.addSampleNode()
            boardDocument.addSampleNode()

            boardDocument.save(to: url, ofType: typeName, for: .saveAsOperation) { error in
                if let error { fail("save: \(error.localizedDescription)") }
                do {
                    let reread = try BoardPackage.read(from: url)
                    let nodeCount = reread.elements.values.filter { $0.node != nil }.count
                    guard nodeCount == 2 else { fail("expected 2 nodes, found \(nodeCount)") }
                    guard reread.layers.count == 1 else { fail("expected 1 layer") }
                    print("SMOKE-TEST PASS: \(url.path)")
                    exit(0)
                } catch {
                    fail("re-read: \(error.localizedDescription)")
                }
            }
        } catch {
            fail("create: \(error.localizedDescription)")
        }
    }
}
