import XCTest
import DesignerModel
import DesignerPersistence
@testable import DesignerInterop
@testable import DesignerCanvas

/// Utility check: imports a foreign diagram (IMPORT_PATH: .drawio/.excalidraw)
/// and renders the result to IMPORT_PNG — the "what does this file look like
/// after import" review tool. IMPORT_OUT saves the board as a package.
final class ImportVisualCheck: XCTestCase {
    func testImportForeignFile() throws {
        let env = ProcessInfo.processInfo.environment
        guard let importPath = env["IMPORT_PATH"], let outPath = env["IMPORT_PNG"] else {
            throw XCTSkip("set IMPORT_PATH and IMPORT_PNG to render")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: importPath))
        let title = URL(fileURLWithPath: importPath).deletingPathExtension().lastPathComponent
        let result = try DrawioFormat.board(from: data, title: title)
        print("IMPORT warnings: \(result.warnings)")
        let board = result.board
        print("IMPORT elements: \(board.elements.count)")

        let image = try XCTUnwrap(BoardSnapshot.image(of: board, pointSize: CGSize(width: 1500, height: 950)))
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outPath))

        if let savePath = env["IMPORT_OUT"] {
            try BoardPackage.write(board, to: URL(fileURLWithPath: savePath))
        }
    }
}
