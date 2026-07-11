import Foundation
import DesignerModel

/// The on-disk document format (D14): a directory package
///
///     MyBoard.designerboard/
///     ├── board.json      canonical document JSON
///     └── assets/         embedded images etc. (used from M5 on)
///
/// Two APIs over the same layout: URL-based (tests, CLI, future importers)
/// and FileWrapper-based (NSDocument, which owns atomicity and autosave).
public enum BoardPackage {
    public static let fileExtension = "designerboard"
    public static let boardFileName = "board.json"
    public static let assetsDirectoryName = "assets"

    public enum PackageError: Error, LocalizedError {
        case missingBoardFile

        public var errorDescription: String? {
            "The package does not contain a '\(BoardPackage.boardFileName)' file."
        }
    }

    // MARK: URL-based

    /// Atomic directory write: builds the package beside the destination and
    /// swaps it in with `replaceItemAt`, so a crash mid-save never corrupts an
    /// existing document (NFR R1).
    public static func write(_ board: Board, to url: URL) throws {
        let data = try BoardSerialization.data(from: board)
        let fileManager = FileManager.default

        let stagingDirectory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: url.deletingLastPathComponent(),
            create: true
        )
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let staged = stagingDirectory.appendingPathComponent(url.lastPathComponent)
        try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
        try data.write(to: staged.appendingPathComponent(boardFileName))
        try fileManager.createDirectory(
            at: staged.appendingPathComponent(assetsDirectoryName),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: url)
        }
    }

    public static func read(from url: URL) throws -> Board {
        let boardURL = url.appendingPathComponent(boardFileName)
        guard FileManager.default.fileExists(atPath: boardURL.path) else {
            throw PackageError.missingBoardFile
        }
        return try BoardSerialization.board(from: try Data(contentsOf: boardURL))
    }

    // MARK: FileWrapper-based (NSDocument)

    public static func fileWrapper(for board: Board) throws -> FileWrapper {
        let data = try BoardSerialization.data(from: board)
        let boardFile = FileWrapper(regularFileWithContents: data)
        boardFile.preferredFilename = boardFileName
        let assets = FileWrapper(directoryWithFileWrappers: [:])
        assets.preferredFilename = assetsDirectoryName
        return FileWrapper(directoryWithFileWrappers: [
            boardFileName: boardFile,
            assetsDirectoryName: assets,
        ])
    }

    public static func board(from wrapper: FileWrapper) throws -> Board {
        guard
            let boardFile = wrapper.fileWrappers?[boardFileName],
            let data = boardFile.regularFileContents
        else {
            throw PackageError.missingBoardFile
        }
        return try BoardSerialization.board(from: data)
    }
}
