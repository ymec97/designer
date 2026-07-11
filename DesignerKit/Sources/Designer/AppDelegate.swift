import AppKit
import DesignerPersistence

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--smoke-test"),
           CommandLine.arguments.indices.contains(index + 1) {
            runSmokeTest(saveTo: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
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
                    let nodeCount = reread.elements.filter { $0.node != nil }.count
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
