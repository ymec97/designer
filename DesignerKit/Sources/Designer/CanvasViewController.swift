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

    override func viewDidLoad() {
        super.viewDidLoad()
        boardSubscription = document.$board.sink { [weak self] board in
            self?.canvasView.board = board
        }
        canvasView.strokeFinished = { [weak self] id in
            self?.strokeFinished(id)
        }
        canvasView.toolChanged = { [weak self] tool in
            self?.toolbarState.tool = tool
        }
        installToolbar()
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
