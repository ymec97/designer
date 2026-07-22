import AppKit
import DesignerModel
import DesignerPersistence

/// One entry in the start-screen catalog.
struct CatalogEntry: Identifiable, Hashable {
    let url: URL
    let title: String
    let modified: Date
    /// The board's stable identity (from board.json) — how node→board links
    /// survive file moves/renames.
    let boardID: BoardID?
    var id: URL { url }
}

/// Indexes the boards a user can jump back into (F1). Two sources, deduped:
/// a managed "Boards" folder that new canvases save into, and the system's
/// recent-documents list (boards saved elsewhere). Sorted newest-first.
enum BoardCatalog {
    /// The managed folder new canvases default into. Created on demand.
    static func boardsFolder() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("Designer/Boards", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func entries(in folder: URL? = nil, includeRecents: Bool = true) -> [CatalogEntry] {
        var byPath: [String: CatalogEntry] = [:]

        func consider(_ url: URL) {
            guard url.pathExtension == BoardPackage.fileExtension else { return }
            let key = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard byPath[key] == nil else { return }
            guard let entry = readEntry(url) else { return }
            byPath[key] = entry
        }

        let root = folder ?? boardsFolder()
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            contents.forEach(consider)
        }
        if includeRecents {
            NSDocumentController.shared.recentDocumentURLs.forEach(consider)
        }

        return byPath.values.sorted { $0.modified > $1.modified }
    }

    /// Reads a board package's title + modified date without loading the whole
    /// board into a document.
    private static func readEntry(_ url: URL) -> CatalogEntry? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let boardURL = url.appendingPathComponent(BoardPackage.boardFileName)
        var title = url.deletingPathExtension().lastPathComponent
        var modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            ?? Date.distantPast
        var boardID: BoardID?
        if let board = try? BoardSerialization.board(from: try Data(contentsOf: boardURL)) {
            if !board.title.isEmpty { title = board.title }
            modified = board.modifiedAt
            boardID = board.id
        }
        return CatalogEntry(url: url, title: title, modified: modified, boardID: boardID)
    }

    /// Resolves a linked board's stable id to its current file URL by
    /// scanning the catalog (folder + recents). Nil when the board is gone.
    static func url(forBoardID id: BoardID) -> URL? {
        entries().first { $0.boardID == id }?.url
    }

    /// Moves a board package to the Trash (recoverable — never a hard
    /// delete). The catalog and recents self-heal: entries whose files are
    /// gone are skipped on the next reload.
    static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// A fresh, unused board file URL in the managed folder ("Untitled",
    /// "Untitled 2", …), so a new canvas is tracked and appears in the catalog.
    static func newBoardURL(in folder: URL? = nil, baseName: String = "Untitled") -> URL {
        let folder = folder ?? boardsFolder()
        func candidate(_ suffix: String) -> URL {
            folder.appendingPathComponent("\(baseName)\(suffix).\(BoardPackage.fileExtension)")
        }
        if !FileManager.default.fileExists(atPath: candidate("").path) { return candidate("") }
        var index = 2
        while FileManager.default.fileExists(atPath: candidate(" \(index)").path) { index += 1 }
        return candidate(" \(index)")
    }
}
