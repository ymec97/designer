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
            onExample: { AppActions.openExample() }
        )
        window.contentView = NSHostingView(rootView: view)
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
