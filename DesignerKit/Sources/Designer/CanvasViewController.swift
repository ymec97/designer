import AppKit
import Combine
import SwiftUI
import DesignerCanvas
import DesignerModel
import DesignerPersistence
import DesignerRecognition

/// Binds a CanvasView to a BoardDocument: board changes flow down via
/// Combine, operations flow up into the document's undo-tracked perform.
final class CanvasViewController: NSViewController, CanvasViewDelegate {
    private static let liveRecognitionDefaultsKey = "LiveSketchRecognition"

    private unowned let document: BoardDocument
    private var boardSubscription: AnyCancellable?

    let canvasView = CanvasView()

    /// Live sketch→structure conversion on stroke end (D15). Default on;
    /// toggleable from the Board menu, persisted across launches.
    var liveRecognitionEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: Self.liveRecognitionDefaultsKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.liveRecognitionDefaultsKey)
        }
    }

    init(document: BoardDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("CanvasViewController is created in code")
    }

    override func loadView() {
        canvasView.delegate = self
        view = canvasView
    }

    private let toolbarState = ToolbarState()
    private let layersModel = LayersPanelModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        boardSubscription = document.$board.sink { [weak self] board in
            guard let self else { return }
            self.canvasView.board = board
            // Keep the active layer valid across undo/board changes.
            if let active = self.layersModel.activeLayerID,
               !board.layers.contains(where: { $0.id == active }) {
                self.setActiveLayer(board.layers.first?.id)
            } else if self.layersModel.activeLayerID == nil {
                self.setActiveLayer(board.layers.first?.id)
            }
        }
        canvasView.strokeFinished = { [weak self] id in
            self?.strokeFinished(id)
        }
        canvasView.toolChanged = { [weak self] tool in
            self?.toolbarState.tool = tool
        }
        installToolbar()
        installLayersPanel()
        installLibraryPanel()
    }

    // MARK: Layers

    private func setActiveLayer(_ id: LayerID?) {
        layersModel.activeLayerID = id
        canvasView.activeLayerID = id
    }

    @objc func toggleLayersPanel(_ sender: Any?) {
        layersModel.isVisible.toggle()
        toolbarState.layersPanelVisible = layersModel.isVisible
    }

    private func installLayersPanel() {
        let actions = LayersPanelActions(
            setVisible: { [weak self] id, visible in
                self?.updateLayer(id) { $0.isVisible = visible }
            },
            setLocked: { [weak self] id, locked in
                self?.updateLayer(id) { $0.isLocked = locked }
            },
            rename: { [weak self] id, name in
                self?.updateLayer(id) { $0.name = name }
            },
            setTint: { [weak self] id, tint in
                self?.updateLayer(id) { $0.colorTint = tint }
            },
            addLayer: { [weak self] in
                guard let self else { return }
                let layer = Layer(name: "Layer \(self.document.board.layers.count + 1)")
                self.document.perform(
                    .insertLayer(layer, at: self.document.board.layers.count),
                    actionName: "Add Layer"
                )
                self.setActiveLayer(layer.id)
            },
            duplicate: { [weak self] id in
                guard let self,
                      let operations = self.document.board.duplicateLayerOperations(id) else { return }
                self.document.perform(.batch(operations), actionName: "Duplicate Layer")
            },
            delete: { [weak self] id in
                guard let self,
                      let operations = self.document.board.deleteLayerOperations(id) else {
                    NSSound.beep()
                    return
                }
                self.document.perform(.batch(operations), actionName: "Delete Layer")
                if self.layersModel.activeLayerID == id {
                    self.setActiveLayer(self.document.board.layers.first?.id)
                }
            },
            move: { [weak self] source, destination in
                guard let self, let sourceIndex = source.first,
                      self.document.board.layers.indices.contains(sourceIndex) else { return }
                let id = self.document.board.layers[sourceIndex].id
                // List's destination is in "after removal" terms for downward moves.
                let target = destination > sourceIndex ? destination - 1 : destination
                guard target != sourceIndex else { return }
                self.document.perform(.moveLayer(id, to: target), actionName: "Reorder Layers")
            },
            setActive: { [weak self] id in
                self?.setActiveLayer(id)
            },
            setFocus: { [weak self] enabled in
                self?.layersModel.focusEnabled = enabled
                self?.canvasView.focusActiveLayer = enabled
            },
            assignSelection: { [weak self] id in
                guard let self else { return }
                let operations = self.document.board.assignOperations(self.canvasView.selection, toLayer: id)
                guard !operations.isEmpty else {
                    NSSound.beep()
                    return
                }
                self.document.perform(.batch(operations), actionName: "Assign to Layer")
            }
        )

        let panel = LayersPanelContainer(document: document, model: layersModel, actions: actions)
        let host = NSHostingView(rootView: panel)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            host.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
        ])
    }

    private func updateLayer(_ id: LayerID, _ mutate: (inout Layer) -> Void) {
        guard var layer = document.board.layers.first(where: { $0.id == id }) else { return }
        mutate(&layer)
        document.perform(.replaceLayer(layer), actionName: "Edit Layer")
    }

    private func installToolbar() {
        let toolbar = CanvasToolbar(
            state: toolbarState,
            onSelectTool: { [weak self] in self?.toolbarAction { $0.activateSelectTool(nil) } },
            onDrawTool: { [weak self] in self?.toolbarAction { $0.activateDrawTool(nil) } },
            onAddBlock: { [weak self] in self?.toolbarAction { $0.addBlock(nil) } },
            onStructurize: { [weak self] in
                guard let self else { return }
                self.structurize(nil)
                self.view.window?.makeFirstResponder(self.canvasView)
            },
            onLayers: { [weak self] in
                guard let self else { return }
                self.toggleLayersPanel(nil)
                self.view.window?.makeFirstResponder(self.canvasView)
            },
            onLibrary: { [weak self] in
                guard let self else { return }
                self.toggleLibraryPanel(nil)
                self.view.window?.makeFirstResponder(self.canvasView)
            }
        )
        let host = NSHostingView(rootView: toolbar)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
        ])
    }

    private func toolbarAction(_ body: (CanvasView) -> Void) {
        body(canvasView)
        // Clicking a toolbar button must not steal keyboard focus from the canvas.
        view.window?.makeFirstResponder(canvasView)
    }

    // MARK: Sketch → structure

    private func strokeFinished(_ id: ElementID) {
        guard liveRecognitionEnabled,
              let element = document.board.elements[id],
              let conversion = SketchConversion.conversion(for: element, in: document.board)
        else { return }
        document.perform(
            document.board.expandingWithReattachments(conversion.operation),
            actionName: conversion.actionName
        )
        canvasView.select([conversion.producedID])
    }

    /// ⌘R: convert selected ink into blocks/connectors (one undo step).
    @objc func structurize(_ sender: Any?) {
        guard let conversion = SketchConversion.structurize(canvasView.selection, in: document.board) else {
            NSSound.beep()
            return
        }
        document.perform(
            document.board.expandingWithReattachments(conversion.operation),
            actionName: conversion.actionName
        )
        canvasView.select([conversion.producedID])
    }

    @objc func toggleLiveRecognition(_ sender: Any?) {
        liveRecognitionEnabled.toggle()
    }

    // MARK: Library

    private let libraryModel = LibraryPanelModel()
    private lazy var libraryStore = LibraryStore(
        rootURL: (try? LibraryStore.defaultRootURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("DesignerLibrary")
    )

    @objc func toggleLibraryPanel(_ sender: Any?) {
        libraryModel.isVisible.toggle()
        toolbarState.libraryPanelVisible = libraryModel.isVisible
        if libraryModel.isVisible { reloadLibrary() }
    }

    @objc func saveSelectionToLibrary(_ sender: Any?) {
        let ids = canvasView.selection
        guard !ids.isEmpty else { NSSound.beep(); return }
        saveToLibrary(ids: ids, suggestedName: "Pattern")
    }

    @objc func saveBoardToLibrary(_ sender: Any?) {
        let ids = Set(document.board.elements.keys)
        guard !ids.isEmpty else { NSSound.beep(); return }
        saveToLibrary(ids: ids, suggestedName: document.displayName ?? "Board")
    }

    private func saveToLibrary(ids: Set<ElementID>, suggestedName: String) {
        guard let name = promptForText(
            title: "Save to Library",
            message: "Name this reusable pattern.",
            defaultvalue: suggestedName
        ), !name.isEmpty else { return }

        let clip = document.board.makeClip(of: ids, title: name)
        let entry = LibraryEntry(name: name, tags: parseTags(from: name))
        let thumbnail = BoardSnapshot.pngThumbnail(of: clip)
        do {
            try libraryStore.save(clip, as: entry, thumbnailPNG: thumbnail)
            reloadLibrary()
            if !libraryModel.isVisible { toggleLibraryPanel(nil) }
        } catch {
            showError(error)
        }
    }

    /// No tag parsing from the name for now; tags are added via rename later.
    private func parseTags(from name: String) -> [String] { [] }

    /// Headless save→list→load→insert round-trip through the real clip/store/
    /// instantiate path, into a throwaway library folder. Returns nil on
    /// success or a failure message (used by --ui-test, which can't drive the
    /// modal save prompt). Leaves the board unchanged (undoes its insert).
    func runLibrarySelfTest() -> String? {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibSelfTest-\(UUID().uuidString)")
        let store = LibraryStore(rootURL: tempRoot)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let ids = Set(document.board.elements.keys)
        guard !ids.isEmpty else { return "no elements to save" }
        let clip = document.board.makeClip(of: ids, title: "SelfTest")
        do {
            let entry = try store.save(clip, as: LibraryEntry(name: "SelfTest", tags: ["t"]))
            guard try store.list().contains(where: { $0.id == entry.id }) else { return "entry not listed" }
            guard try store.search("selftest").contains(where: { $0.id == entry.id }) else { return "search miss" }
            let loaded = try store.loadBoard(entry.id)
            let before = document.board.elements.count
            let layer = activeLayerID() ?? document.board.layers.first!.id
            let (operations, newIDs) = document.board.instantiateOperations(
                from: loaded, offsetBy: 800, 800, onto: layer
            )
            document.perform(.batch(operations), actionName: "Insert SelfTest")
            guard document.board.elements.count == before + loaded.elements.count else {
                return "insert count wrong (\(document.board.elements.count) vs \(before + loaded.elements.count))"
            }
            for id in newIDs {
                guard let edge = document.board.elements[id]?.edge else { continue }
                if let from = edge.from.elementID, !newIDs.contains(from) { return "edge 'from' not remapped" }
                if let to = edge.to.elementID, !newIDs.contains(to) { return "edge 'to' not remapped" }
            }
            document.undoManager?.undo()
            guard document.board.elements.count == before else { return "undo did not restore" }
            return nil
        } catch {
            return "\(error)"
        }
    }

    private func installLibraryPanel() {
        let actions = LibraryPanelActions(
            insert: { [weak self] entry in self?.insert(entry) },
            promptRename: { [weak self] entry in self?.renameLibraryEntry(entry) },
            delete: { [weak self] entry in self?.deleteLibraryEntry(entry) },
            saveSelection: { [weak self] in self?.saveSelectionToLibrary(nil) }
        )
        let panel = LibraryPanelContainer(model: libraryModel, actions: actions)
        let host = NSHostingView(rootView: panel)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            // Below the layers panel's top anchor so both can be open.
            host.topAnchor.constraint(equalTo: view.topAnchor, constant: 320),
        ])
    }

    private func reloadLibrary() {
        let entries = (try? libraryStore.list()) ?? []
        libraryModel.entries = entries
        var thumbnails: [UUID: Data] = [:]
        for entry in entries {
            if let data = libraryStore.loadThumbnail(entry.id) {
                thumbnails[entry.id] = data
            }
        }
        libraryModel.thumbnails = thumbnails
    }

    private func insert(_ entry: LibraryEntry) {
        do {
            let clip = try libraryStore.loadBoard(entry.id)
            let layerID = activeLayerID() ?? document.board.layers.first?.id
            guard let layerID else { return }

            // Center the clip on the visible canvas center.
            let center = canvasView.visibleCenterWorld
            var dx = 0.0, dy = 0.0
            if let bounds = clip.contentBounds() {
                dx = center.x - bounds.midX
                dy = center.y - bounds.midY
            }
            let (operations, newIDs) = document.board.instantiateOperations(
                from: clip, offsetBy: dx, dy, onto: layerID
            )
            guard !operations.isEmpty else { return }
            document.perform(.batch(operations), actionName: "Insert “\(entry.name)”")
            canvasView.select(newIDs)
            view.window?.makeFirstResponder(canvasView)
        } catch {
            showError(error)
        }
    }

    private func activeLayerID() -> LayerID? {
        if let id = layersModel.activeLayerID,
           let layer = document.board.layers.first(where: { $0.id == id }),
           layer.isVisible, !layer.isLocked {
            return id
        }
        return document.board.layers.first { $0.isVisible && !$0.isLocked }?.id
    }

    private func renameLibraryEntry(_ entry: LibraryEntry) {
        guard let name = promptForText(
            title: "Rename Pattern",
            message: "Enter a new name (comma-separated tags optional after “#”).",
            defaultvalue: entry.name
        ), !name.isEmpty else { return }
        // Support "Name #tag1, tag2" to set tags inline.
        var updated = entry
        if let hash = name.firstIndex(of: "#") {
            updated.name = String(name[..<hash]).trimmingCharacters(in: .whitespaces)
            updated.tags = name[name.index(after: hash)...]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else {
            updated.name = name
        }
        do {
            try libraryStore.update(updated)
            reloadLibrary()
        } catch {
            showError(error)
        }
    }

    private func deleteLibraryEntry(_ entry: LibraryEntry) {
        do {
            try libraryStore.delete(entry.id)
            reloadLibrary()
        } catch {
            showError(error)
        }
    }

    /// Modal text prompt (NSAlert with an input field).
    private func promptForText(title: String, message: String, defaultvalue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultvalue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespaces)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(canvasView)
    }

    // MARK: CanvasViewDelegate

    func canvasView(_ view: CanvasView, perform operation: BoardOperation, actionName: String) {
        // Any newly placed block also snaps nearby dangling connector
        // endpoints onto itself, inside the same undo step.
        document.perform(
            document.board.expandingWithReattachments(operation),
            actionName: actionName
        )
    }

    func canvasViewDidChangeSelection(_ view: CanvasView) {
        // Inspector panels subscribe here from M2 on.
    }
}

extension CanvasViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(structurize(_:)):
            return canvasView.selection.contains { id in
                if case .ink = document.board.elements[id]?.content { return true }
                return false
            }
        case #selector(toggleLiveRecognition(_:)):
            menuItem.state = liveRecognitionEnabled ? .on : .off
            return true
        case #selector(saveSelectionToLibrary(_:)):
            return !canvasView.selection.isEmpty
        case #selector(saveBoardToLibrary(_:)):
            return !document.board.elements.isEmpty
        case #selector(toggleLibraryPanel(_:)):
            menuItem.state = libraryModel.isVisible ? .on : .off
            return true
        default:
            return true
        }
    }
}
