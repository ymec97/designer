import AppKit
import SwiftUI

/// Hosts the start-screen catalog in its own window. One shared instance,
/// reopened whenever there's no document window to show.
final class CatalogWindowController: NSWindowController {
    static let shared = CatalogWindowController()

    private let model = CatalogModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Designer"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        let view = CatalogView(
            model: model,
            onNew: { AppActions.newCanvas() },
            onOpen: { AppActions.open($0) },
            onOpenElsewhere: { AppActions.openPanel() },
            onExample: { AppActions.openExample() },
            onDelete: { [weak self] entry in self?.confirmDelete(entry) }
        )
        window.contentView = NSHostingView(rootView: view)
    }

    /// Right-click ▸ Move to Trash: confirm, close the board's window if it's
    /// open, trash the package (recoverable), refresh the grid.
    private func confirmDelete(_ entry: CatalogEntry) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(entry.title)” to the Trash?"
        alert.informativeText = "The board is moved to the Trash, not deleted — you can put it back from there."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let target = entry.url.resolvingSymlinksInPath().standardizedFileURL
            for document in NSDocumentController.shared.documents
            where document.fileURL?.resolvingSymlinksInPath().standardizedFileURL == target {
                document.close()
            }
            do {
                try BoardCatalog.trash(entry.url)
                self.model.thumbnails[entry.url] = nil
                self.model.reload()
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        model.reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() { model.reload() }
}

/// Small indirection so the SwiftUI catalog can invoke app-level document
/// actions without holding an app reference.
enum AppActions {
    static var newCanvas: () -> Void = {}
    static var open: (URL) -> Void = { _ in }
    static var openPanel: () -> Void = {}
    static var openExample: () -> Void = {}
}
