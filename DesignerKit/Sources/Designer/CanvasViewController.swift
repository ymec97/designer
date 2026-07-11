import AppKit
import Combine
import DesignerCanvas
import DesignerModel

/// Binds a CanvasView to a BoardDocument: board changes flow down via
/// Combine, operations flow up into the document's undo-tracked perform.
final class CanvasViewController: NSViewController, CanvasViewDelegate {
    private unowned let document: BoardDocument
    private var boardSubscription: AnyCancellable?

    let canvasView = CanvasView()

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

    override func viewDidLoad() {
        super.viewDidLoad()
        boardSubscription = document.$board.sink { [weak self] board in
            self?.canvasView.board = board
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(canvasView)
    }

    // MARK: CanvasViewDelegate

    func canvasView(_ view: CanvasView, perform operation: BoardOperation, actionName: String) {
        document.perform(operation, actionName: actionName)
    }

    func canvasViewDidChangeSelection(_ view: CanvasView) {
        // Inspector panels subscribe here from M2 on.
    }
}
