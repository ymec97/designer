import AppKit
import DesignerCanvas
import UniformTypeIdentifiers
import DesignerModel
import DesignerPersistence

final class BoardDocument: NSDocument, ObservableObject {
    @Published var board = Board(title: "Untitled")
    /// F3 — version history; lives in the package, edited via the Versions
    /// panel. Mutations mark the document dirty so autosave persists them.
    @Published var versions = VersionArchive()

    override class var autosavesInPlace: Bool { true }

    /// True while the document lives under its auto-generated "Untitled N"
    /// name in the managed Boards folder and the user never chose a name.
    /// The first explicit ⌘S then PROMPTS (name + location) instead of
    /// silently keeping "Untitled"; autosave is unaffected.
    var isAutoNamedDraft = false

    override func save(_ sender: Any?) {
        guard isAutoNamedDraft, let window = windowForSheet else {
            super.save(sender)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = displayName ?? "Board"
        panel.directoryURL = BoardCatalog.boardsFolder()
        if let type = UTType(filenameExtension: BoardPackage.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.message = "Name this board"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { return } // cancel keeps the draft
            let previousURL = self.fileURL
            self.isAutoNamedDraft = false
            self.perform(.setTitle(url.deletingPathExtension().lastPathComponent), actionName: "Rename Board")
            self.save(to: url, ofType: self.fileType ?? "", for: .saveAsOperation) { _ in
                // The draft file in the managed folder is superseded; drop it
                // so the catalog doesn't show a stale "Untitled" twin.
                if let previousURL, previousURL != url {
                    try? FileManager.default.trashItem(at: previousURL, resultingItemURL: nil)
                }
                CatalogWindowController.shared.refresh()
            }
        }
    }

    override func makeWindowControllers() {
        let window = NSWindow(contentViewController: CanvasViewController(document: self))
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.styleMask.insert([.resizable, .miniaturizable, .closable, .titled])
        // Small enough for split-screen, big enough that the toolbar and a
        // side panel never collide.
        window.contentMinSize = NSSize(width: 880, height: 560)
        window.center()
        addWindowController(NSWindowController(window: window))
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        var snapshot = board
        snapshot.modifiedAt = Date().millisecondRounded
        return try BoardPackage.fileWrapper(for: snapshot, versions: versions)
    }

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        var loaded = try BoardPackage.board(from: fileWrapper)
        // B2: boards that accumulated long z-order keys over many sessions
        // get renumbered here, before any undo history references the keys.
        loaded.normalizeSortKeysIfNeeded()
        let loadedVersions = BoardPackage.versions(from: fileWrapper)
        if Thread.isMainThread {
            board = loaded
            versions = loadedVersions
        } else {
            DispatchQueue.main.sync {
                board = loaded
                versions = loadedVersions
            }
        }
    }

    // MARK: Version history (F3)

    /// Automatic snapshots kept at most; manual versions never expire.
    private static let autoVersionLimit = 10

    /// Snapshots the CURRENT board into the archive. Not undoable — history
    /// is a safety net; undoing an edit shouldn't silently discard snapshots.
    @discardableResult
    func saveVersion(named name: String, kind: VersionArchive.VersionMeta.Kind) -> VersionArchive.VersionMeta? {
        let thumbnail = BoardSnapshot.pngThumbnail(of: board, pointSize: CGSize(width: 208, height: 132))
        do {
            let meta = try versions.add(board, name: name, kind: kind, thumbnail: thumbnail)
            if kind == .auto { versions.pruneAutoVersions(keeping: Self.autoVersionLimit) }
            updateChangeCount(.changeDone)
            return meta
        } catch {
            presentError(error)
            return nil
        }
    }

    /// Replaces the board's content with a stored version — one undo step.
    /// The pre-restore state is snapshotted first, so restore is always
    /// recoverable even after the undo stack is gone.
    func restoreVersion(_ id: UUID) {
        do {
            guard let stored = try versions.board(for: id) else { return }
            saveVersion(named: "Before restore", kind: .auto)
            perform(.replaceBoard(stored), actionName: "Restore Version")
        } catch {
            presentError(error)
        }
    }

    func renameVersion(_ id: UUID, to name: String) {
        versions.rename(id, to: name)
        updateChangeCount(.changeDone)
    }

    func deleteVersion(_ id: UUID) {
        versions.delete(id)
        updateChangeCount(.changeDone)
    }

    // MARK: Mutations

    /// All document changes flow through here: applies the operation and
    /// registers its inverse with the undo manager, which also drives
    /// NSDocument's change tracking and autosave.
    func perform(_ operation: BoardOperation, actionName: String) {
        DesignerCanvas.CanvasView.debugTrace?("document.perform \(actionName)")
        do {
            let inverse = try board.apply(operation)
            guard let undoManager else { return }
            // One operation = exactly one undo step. AppKit's default
            // per-event grouping would merge operations that happen to share
            // a runloop cycle (e.g. a label commit followed by a connect in
            // one event, or future agent batches) into a single undo.
            undoManager.groupsByEvent = false
            let needsGroup = !undoManager.isUndoing && !undoManager.isRedoing
            if needsGroup { undoManager.beginUndoGrouping() }
            undoManager.registerUndo(withTarget: self) { document in
                document.perform(inverse, actionName: actionName)
            }
            undoManager.setActionName(actionName)
            if needsGroup { undoManager.endUndoGrouping() }
        } catch {
            presentError(error)
        }
    }

    func addSampleNode() {
        let baseLayer = board.layers[0]
        let count = board.elements.count
        let node = Element(
            layerIDs: [baseLayer.id],
            sortKey: board.topSortKey,
            content: .node(Node(
                semantic: NodeSemantic(kind: .service, name: "service-\(count + 1)"),
                frame: Rect(
                    x: 80 + Double(count % 8) * 190,
                    y: 80 + Double(count / 8) * 120,
                    width: 160, height: 80
                )
            ))
        )
        perform(.insertElement(node), actionName: "Add Block")
    }
}
