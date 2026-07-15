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
        mainMenu.addItem(helpMenuItem())
        return mainMenu
    }

    private static func helpMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Help")
        menu.addItem(withTitle: "Open Example Board",
                     action: #selector(AppDelegate.openExampleBoard(_:)),
                     keyEquivalent: "")
        return wrapped(menu)
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
        menu.addItem(withTitle: "Group",
                     action: Selector(("groupSelection:")),
                     keyEquivalent: "g")
        let ungroup = menu.addItem(withTitle: "Ungroup",
                                   action: Selector(("ungroupSelection:")),
                                   keyEquivalent: "g")
        ungroup.keyEquivalentModifierMask = [.command, .shift]
        let boundary = menu.addItem(withTitle: "Add Boundary around Selection",
                                    action: Selector(("addBoundaryAroundSelection:")),
                                    keyEquivalent: "b")
        boundary.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Structurize Sketch into Shapes",
                     action: Selector(("structurize:")),
                     keyEquivalent: "r")
        menu.addItem(.separator())
        let simulate = menu.addItem(withTitle: "Simulate Traffic from Selection",
                                    action: Selector(("simulateTraffic:")),
                                    keyEquivalent: "\r")
        simulate.keyEquivalentModifierMask = [.command]
        let recordFlow = menu.addItem(withTitle: "Record Flow from Selection",
                                      action: Selector(("recordFlow:")),
                                      keyEquivalent: "\r")
        recordFlow.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Flows",
                     action: Selector(("toggleFlowsPanel:")),
                     keyEquivalent: "j")
        let inspector = menu.addItem(withTitle: "Inspector",
                                     action: Selector(("toggleInspector:")),
                                     keyEquivalent: "i")
        inspector.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        let saveVersion = menu.addItem(withTitle: "Save Version",
                                       action: Selector(("saveVersionNow:")),
                                       keyEquivalent: "s")
        saveVersion.keyEquivalentModifierMask = [.command, .control]
        let versions = menu.addItem(withTitle: "Version History",
                                    action: Selector(("toggleVersionsPanel:")),
                                    keyEquivalent: "h")
        versions.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        let assistant = menu.addItem(withTitle: "Assistant",
                                     action: Selector(("toggleChatPanel:")),
                                     keyEquivalent: "a")
        assistant.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Enable Agent Access",
                     action: Selector(("toggleAgentAccess:")),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Convert Sketches Automatically",
                     action: Selector(("toggleLiveRecognition:")),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Hand-drawn Style",
                     action: Selector(("toggleSketchyStyle:")),
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
        menu.addItem(.separator())
        menu.addItem(withTitle: "Command Palette",
                     action: Selector(("toggleCommandPalette:")),
                     keyEquivalent: "k")
        menu.addItem(withTitle: "Show Library",
                     action: Selector(("toggleLibraryPanel:")),
                     keyEquivalent: "y")
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
        menu.addItem(withTitle: "New Canvas",
                     action: Selector(("newCanvasMenu:")),
                     keyEquivalent: "n")
        menu.addItem(withTitle: "Open…",
                     action: #selector(NSDocumentController.openDocument(_:)),
                     keyEquivalent: "o")
        let catalog = menu.addItem(withTitle: "All Boards…",
                                   action: Selector(("showCatalog:")),
                                   keyEquivalent: "o")
        catalog.keyEquivalentModifierMask = [.command, .shift]
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
        menu.addItem(withTitle: "Export as PNG…",
                     action: Selector(("exportAsPNG:")),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Export as SVG…",
                     action: Selector(("exportAsSVG:")),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Export as draw.io…",
                     action: Selector(("exportAsDrawio:")),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Export as Excalidraw…",
                     action: Selector(("exportAsExcalidraw:")),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Import draw.io / Excalidraw…",
                     action: Selector(("importDiagramFile:")),
                     keyEquivalent: "")
        menu.addItem(.separator())
        let saveSelection = menu.addItem(withTitle: "Save Selection to Library",
                                         action: Selector(("saveSelectionToLibrary:")),
                                         keyEquivalent: "s")
        saveSelection.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Save Board to Library",
                     action: Selector(("saveBoardToLibrary:")),
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
        menu.addItem(withTitle: "Duplicate",
                     action: Selector(("duplicateSelection:")),
                     keyEquivalent: "d")
        // No key equivalent on Delete — the canvas handles the delete key in
        // keyDown, so a menu key equivalent would hijack backspace while
        // editing a label.
        menu.addItem(withTitle: "Delete",
                     action: Selector(("deleteSelection:")),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Select All",
                     action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        menu.addItem(.separator())
        let copyForLLM = menu.addItem(withTitle: "Copy for LLM",
                                      action: Selector(("copyForLLM:")),
                                      keyEquivalent: "c")
        copyForLLM.keyEquivalentModifierMask = [.command, .shift]
        let importLLM = menu.addItem(withTitle: "Import Board from Clipboard",
                                     action: Selector(("importBoardFromClipboard:")),
                                     keyEquivalent: "v")
        importLLM.keyEquivalentModifierMask = [.command, .shift]
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
