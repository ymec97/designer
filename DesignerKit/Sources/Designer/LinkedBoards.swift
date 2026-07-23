import AppKit
import SwiftUI
import DesignerCanvas
import DesignerModel
import DesignerPersistence

// MARK: - View state

/// Linked-board view state: how deep we are, what's on screen, and the exact
/// cameras to restore on the way back.
final class LinkedViewModel: ObservableObject {
    @Published var isActive = false
    @Published var title = ""
    @Published var depth = 0
}

/// One level of drill-down: everything needed to come back EXACTLY —
/// the board shown at that level, the camera before entering, and the
/// entered node's frame (for the reverse zoom-out animation).
struct LinkedBoardFrame {
    let board: Board
    let savedViewport: CanvasViewport
    let enteredNodeFrame: Rect
    let title: String
}

// MARK: - Banner

/// The top banner while inside a linked board: you're in a VIEW, not the
/// document — Back restores the exact camera; Open Editable is the real
/// document window.
struct LinkedViewBanner: View {
    @ObservedObject var model: LinkedViewModel
    let onBack: () -> Void
    let onOpenEditable: () -> Void

    var body: some View {
        if model.isActive {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.right.circle.fill")
                    .foregroundStyle(GraphiteStyle.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Linked board view — \(model.title)")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(model.depth > 1 ? "Read-only · depth \(model.depth)" : "Read-only")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Divider().frame(height: 20)
                Button {
                    onBack()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .keyboardShortcut(.escape, modifiers: [])
                .help("Return to the previous board at the exact camera you left")
                Button("Open Editable") { onOpenEditable() }
                    .font(.system(size: 10.5))
                    .help("Open this board as a real document window to edit it")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .floatingPanel(radius: 10)
            .graphiteAccent()
        }
    }
}

// MARK: - Picker

/// The "Link to Board…" sheet: the catalog's boards, searchable, one click
/// to pick. Boards without a readable id are shown disabled.
struct BoardLinkPicker: View {
    let entries: [CatalogEntry]
    let currentBoardID: BoardID?
    let pick: (CatalogEntry) -> Void
    let cancel: () -> Void

    @State private var query = ""

    private var filtered: [CatalogEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Link to Board")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(12)
            TextField("Search boards…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()
            List(filtered) { entry in
                let disabled = entry.boardID == nil || entry.boardID == currentBoardID
                Button {
                    pick(entry)
                } label: {
                    HStack {
                        Image(systemName: "square.on.square.dashed")
                            .foregroundStyle(GraphiteStyle.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title).font(.system(size: 12, weight: .medium))
                            Text(entry.modified, style: .date)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.boardID == currentBoardID {
                            Text("this board").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.4 : 1)
            }
            .listStyle(.plain)
        }
        .frame(width: 420, height: 440)
        .graphiteAccent()
    }
}

// MARK: - Navigation

extension CanvasViewController {
    /// Wires the linked-board surfaces; called once from viewDidLoad.
    func installLinkedBoards() {
        canvasView.linkActivated = { [weak self] nodeID in
            self?.enterLinkedBoard(from: nodeID)
        }
        canvasView.nodeContextMenu = { [weak self] nodeID in
            self?.buildNodeContextMenu(for: nodeID)
        }

        let banner = LinkedViewBanner(
            model: linkedViewModel,
            onBack: { [weak self] in self?.exitLinkedBoard() },
            onOpenEditable: { [weak self] in self?.openCurrentLinkedBoardEditable() }
        )
        let host = NSHostingView(rootView: banner)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor, constant: 62),
        ])
    }

    // MARK: Context menu

    private func buildNodeContextMenu(for nodeID: ElementID) -> NSMenu? {
        guard let node = canvasView.board.elements[nodeID]?.node else { return nil }
        let menu = NSMenu()
        func item(_ title: String, _ handler: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, handler: handler)
            menu.addItem(item)
        }
        if node.semantic.linkedBoardID != nil {
            item("Go to Board") { [weak self] in self?.enterLinkedBoard(from: nodeID) }
            item("Open Linked Board in New Window") { [weak self] in
                self?.openLinkedBoardEditable(nodeID: nodeID)
            }
            menu.addItem(.separator())
            item("Change Link…") { [weak self] in self?.presentLinkPicker(for: nodeID) }
            item("Unlink Board") { [weak self] in self?.setLink(nil, on: nodeID) }
        } else {
            item("Link to Board…") { [weak self] in self?.presentLinkPicker(for: nodeID) }
            item("Create Board with Link") { [weak self] in self?.createBoardWithLink(for: nodeID) }
        }
        return menu
    }

    // MARK: Linking

    private func setLink(_ boardID: BoardID?, on nodeID: ElementID) {
        guard var element = document.board.elements[nodeID], var node = element.node else { return }
        node.semantic.linkedBoardID = boardID
        element.content = .node(node)
        document.perform(.replaceElement(element),
                         actionName: boardID == nil ? "Unlink Board" : "Link to Board")
    }

    func presentLinkPicker(for nodeID: ElementID) {
        let entries = BoardCatalog.entries()
        let sheetWindow = NSWindow(contentViewController: NSHostingController(rootView:
            BoardLinkPicker(
                entries: entries,
                currentBoardID: document.board.id,
                pick: { [weak self] entry in
                    guard let self else { return }
                    if let id = entry.boardID { self.setLink(id, on: nodeID) }
                    self.dismissLinkPicker()
                },
                cancel: { [weak self] in self?.dismissLinkPicker() }
            )
        ))
        linkPickerWindow = sheetWindow
        view.window?.beginSheet(sheetWindow)
    }

    private func dismissLinkPicker() {
        if let sheet = linkPickerWindow {
            view.window?.endSheet(sheet)
        }
        linkPickerWindow = nil
        view.window?.makeFirstResponder(canvasView)
    }

    /// Creates a fresh board in the managed folder, links the node to it,
    /// and opens it EDITABLE in its own window — the quick "drill in and
    /// start detailing" flow.
    func createBoardWithLink(for nodeID: ElementID) {
        guard let node = document.board.elements[nodeID]?.node else { return }
        let base = node.semantic.name.isEmpty ? "Linked Board" : node.semantic.name
        let newBoard = Board(title: base)

        // Unique file name in the managed Boards folder.
        let folder = BoardCatalog.boardsFolder()
        let safe = base.replacingOccurrences(of: "/", with: "-")
        var url = folder.appendingPathComponent("\(safe).\(BoardPackage.fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(safe) \(counter).\(BoardPackage.fileExtension)")
            counter += 1
        }
        do {
            try BoardPackage.write(newBoard, to: url)
        } catch {
            NSSound.beep()
            return
        }
        setLink(newBoard.id, on: nodeID)
        AppActions.open(url)
    }

    private func openLinkedBoardEditable(nodeID: ElementID) {
        guard let node = canvasView.board.elements[nodeID]?.node,
              let linkID = node.semantic.linkedBoardID,
              let url = BoardCatalog.url(forBoardID: linkID) else {
            NSSound.beep()
            return
        }
        AppActions.open(url)
    }

    func openCurrentLinkedBoardEditable() {
        // The nested board being viewed — find its file by id and open it.
        guard linkedViewModel.isActive,
              let url = BoardCatalog.url(forBoardID: canvasView.board.id) else {
            NSSound.beep()
            return
        }
        AppActions.open(url)
    }

    // MARK: Enter / exit

    func enterLinkedBoard(from nodeID: ElementID) {
        guard let node = canvasView.board.elements[nodeID]?.node,
              let linkID = node.semantic.linkedBoardID else { return }
        guard linkID != canvasView.board.id else {
            NSSound.beep() // a board can't nest into itself
            return
        }
        guard let url = BoardCatalog.url(forBoardID: linkID),
              let target = try? BoardPackage.read(from: url) else {
            let alert = NSAlert()
            alert.messageText = "Linked board not found"
            alert.informativeText = "The board this block links to isn't in the catalog anymore. Re-link it via right-click → Change Link."
            alert.runModal()
            return
        }

        linkedBoardStack.append(LinkedBoardFrame(
            board: canvasView.board,
            savedViewport: canvasView.viewport,
            enteredNodeFrame: node.frame,
            title: linkedViewModel.isActive ? linkedViewModel.title : document.board.title
        ))

        playSwoosh()
        // Zoom INTO the node — the camera dives until the block fills the
        // screen — then the linked board fades in at a fitted camera.
        let dive = viewportDivingInto(node.frame)
        canvasView.animateViewport(to: dive, duration: 0.34) { [weak self] in
            guard let self else { return }
            self.canvasView.board = target
            self.canvasView.isReadOnly = true
            var fitted = self.canvasView.viewport
            let content = target.contentBounds() ?? Rect(x: 0, y: 0, width: 800, height: 500)
            fitted.fit(content, in: self.canvasView.bounds.size)
            // Arrive slightly zoomed-out from the fit, then settle — reads
            // as "landing inside".
            var from = fitted
            from.setScale(fitted.scale * 1.35,
                          at: CGPoint(x: self.canvasView.bounds.midX, y: self.canvasView.bounds.midY))
            self.canvasView.viewport = from
            self.canvasView.animateViewport(to: fitted, duration: 0.22)
            self.linkedViewModel.title = target.title
            self.linkedViewModel.depth = self.linkedBoardStack.count
            self.linkedViewModel.isActive = true
            self.refreshStylePanel()
        }
    }

    func exitLinkedBoard() {
        guard let frame = linkedBoardStack.popLast() else { return }
        playSwoosh()
        let poppingToRoot = linkedBoardStack.isEmpty
        // Swap back, START from the dived-into-node camera, then glide to
        // the EXACT camera saved on entry.
        canvasView.board = poppingToRoot ? document.board : frame.board
        canvasView.isReadOnly = !poppingToRoot
        canvasView.viewport = viewportDivingInto(frame.enteredNodeFrame)
        canvasView.animateViewport(to: frame.savedViewport, duration: 0.34)
        if poppingToRoot {
            linkedViewModel.isActive = false
            linkedViewModel.depth = 0
        } else {
            linkedViewModel.title = frame.title
            linkedViewModel.depth = linkedBoardStack.count
        }
        refreshStylePanel()
        view.window?.makeFirstResponder(canvasView)
    }

    /// The camera "inside" a node: the node's frame blown up well past the
    /// viewport so the dive reads as entering it.
    private func viewportDivingInto(_ nodeFrame: Rect) -> CanvasViewport {
        var target = canvasView.viewport
        let magnified = Rect(
            x: nodeFrame.midX - nodeFrame.width * 0.18,
            y: nodeFrame.midY - nodeFrame.height * 0.18,
            width: nodeFrame.width * 0.36,
            height: nodeFrame.height * 0.36
        )
        target.fit(magnified, in: canvasView.bounds.size, padding: 0)
        return target
    }

    private func playSwoosh() {
        if linkedBoardSwoosh == nil,
           let url = Bundle.module.url(forResource: "swoosh", withExtension: "wav") {
            linkedBoardSwoosh = NSSound(contentsOf: url, byReference: true)
        }
        // The drill-in swoosh was way too loud; keep it as a soft, unobtrusive
        // cue rather than a startling one.
        linkedBoardSwoosh?.volume = 0.35
        linkedBoardSwoosh?.stop()
        linkedBoardSwoosh?.play()
    }
}

/// NSMenuItem carrying a closure — the canvas context menu needs per-item
/// actions without a shared selector registry.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        handler = {}
        super.init(coder: coder)
    }

    @objc private func run() { handler() }
}
