import AppKit
import DesignerModel
import DesignerPersistence

final class AppDelegate: NSObject, NSApplicationDelegate {
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
        if let index = CommandLine.arguments.firstIndex(of: "--screenshot-catalog"),
           CommandLine.arguments.indices.contains(index + 1) {
            runCatalogScreenshot(saveTo: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--screenshot-sim"),
           CommandLine.arguments.indices.contains(index + 1) {
            runSimulationScreenshot(saveTo: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--screenshot"),
           CommandLine.arguments.indices.contains(index + 1) {
            ScreenshotDriver.run(saveTo: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
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
