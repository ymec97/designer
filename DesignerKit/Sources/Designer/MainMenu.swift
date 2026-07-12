import AppKit
import DesignerCanvas

/// The app runs without a storyboard, so the main menu is built in code.
/// NSDocument's standard machinery (save, autosave, undo, window titles)
/// is driven by these first-responder selectors.
enum MainMenu {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(boardMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(windowMenuItem())
        return mainMenu
    }

    private static func boardMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Board")
        let select = menu.addItem(withTitle: "Select Tool",
                                  action: #selector(CanvasView.activateSelectTool(_:)),
                                  keyEquivalent: "v")
        select.keyEquivalentModifierMask = []
        let draw = menu.addItem(withTitle: "Draw Tool",
                                action: #selector(CanvasView.activateDrawTool(_:)),
                                keyEquivalent: "d")
        draw.keyEquivalentModifierMask = []
        menu.addItem(.separator())
        menu.addItem(withTitle: "Add Block",
                     action: #selector(CanvasView.addBlock(_:)),
                     keyEquivalent: "b")
        menu.addItem(withTitle: "Structurize",
                     action: Selector(("structurize:")),
                     keyEquivalent: "r")
        menu.addItem(withTitle: "Convert Sketches Automatically",
                     action: Selector(("toggleLiveRecognition:")),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete",
                     action: #selector(CanvasView.deleteSelection(_:)),
                     keyEquivalent: "")
        return wrapped(menu)
    }

    private static func viewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "View")
        menu.addItem(withTitle: "Show Layers",
                     action: Selector(("toggleLayersPanel:")),
                     keyEquivalent: "l")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Zoom In",
                     action: #selector(CanvasView.zoomIn(_:)),
                     keyEquivalent: "+")
        // Hidden alternate so plain ⌘= also zooms in (no shift needed).
        let zoomInAlternate = menu.addItem(withTitle: "Zoom In",
                                           action: #selector(CanvasView.zoomIn(_:)),
                                           keyEquivalent: "=")
        zoomInAlternate.isAlternate = true
        zoomInAlternate.isHidden = true
        menu.addItem(withTitle: "Zoom Out",
                     action: #selector(CanvasView.zoomOut(_:)),
                     keyEquivalent: "-")
        menu.addItem(withTitle: "Actual Size",
                     action: #selector(CanvasView.zoomActualSize(_:)),
                     keyEquivalent: "0")
        menu.addItem(withTitle: "Zoom to Fit",
                     action: #selector(CanvasView.zoomToFit(_:)),
                     keyEquivalent: "9")
        return wrapped(menu)
    }

    private static func appMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Designer")
        menu.addItem(withTitle: "About Designer",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        let hide = menu.addItem(withTitle: "Hide Designer",
                                action: #selector(NSApplication.hide(_:)),
                                keyEquivalent: "h")
        hide.keyEquivalentModifierMask = .command
        let hideOthers = menu.addItem(withTitle: "Hide Others",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Designer",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        return wrapped(menu)
    }

    private static func fileMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "New Board",
                     action: #selector(NSDocumentController.newDocument(_:)),
                     keyEquivalent: "n")
        menu.addItem(withTitle: "Open…",
                     action: #selector(NSDocumentController.openDocument(_:)),
                     keyEquivalent: "o")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close",
                     action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        menu.addItem(withTitle: "Save…",
                     action: #selector(NSDocument.save(_:)),
                     keyEquivalent: "s")
        let duplicate = menu.addItem(withTitle: "Duplicate",
                                     action: #selector(NSDocument.duplicate(_:)),
                                     keyEquivalent: "s")
        duplicate.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Rename…",
                     action: #selector(NSDocument.rename(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Move To…",
                     action: #selector(NSDocument.move(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Revert to Saved",
                     action: #selector(NSDocument.revertToSaved(_:)),
                     keyEquivalent: "")
        return wrapped(menu)
    }

    private static func editMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All",
                     action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        return wrapped(menu)
    }

    private static func windowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom",
                     action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")
        NSApp.windowsMenu = menu
        return wrapped(menu)
    }

    private static func wrapped(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}
