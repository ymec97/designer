import XCTest
import DesignerModel
import DesignerPersistence
@testable import DesignerCanvas

/// Utility check: renders any .designerboard given via BOARD_PATH to the
/// PNG at BOARD_PNG — for eyeballing real user boards in review sessions.
/// Always skipped unless both env vars are set.
final class BoardFileVisualCheck: XCTestCase {
    func testRenderBoardFile() throws {
        let env = ProcessInfo.processInfo.environment
        guard let boardPath = env["BOARD_PATH"], let outPath = env["BOARD_PNG"] else {
            throw XCTSkip("set BOARD_PATH and BOARD_PNG to render")
        }
        let board = try BoardPackage.read(from: URL(fileURLWithPath: boardPath))
        let image = try XCTUnwrap(BoardSnapshot.image(of: board, pointSize: CGSize(width: 1400, height: 900)))
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outPath))
    }
}
