import AppKit
import Combine
import SwiftUI
import DesignerCanvas
import DesignerModel
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
    }

    // MARK: Layers

    private func setActiveLayer(_ id: LayerID?) {
        layersModel.activeLayerID = id
        canvasView.activeLayerID = id
    }

    @objc func toggleLayersPanel(_ sender: Any?) {
        layersModel.isVisible.toggle()
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
        default:
            return true
        }
    }
}
