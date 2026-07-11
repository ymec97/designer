import AppKit
import DesignerPersistence

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
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

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
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
