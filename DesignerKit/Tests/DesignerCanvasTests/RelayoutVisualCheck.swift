import XCTest
import DesignerModel
import DesignerPersistence
@testable import DesignerInterop
@testable import DesignerCanvas

/// Utility check: strips positions from a real .designerboard (RELAYOUT_BOARD)
/// and renders the narrative auto-layout result to RELAYOUT_PNG — the
/// "what would the agent's first draft look like NOW" review tool.
final class RelayoutVisualCheck: XCTestCase {
    func testRelayoutBoardFile() throws {
        let env = ProcessInfo.processInfo.environment
        guard let boardPath = env["RELAYOUT_BOARD"], let outPath = env["RELAYOUT_PNG"] else {
            throw XCTSkip("set RELAYOUT_BOARD and RELAYOUT_PNG to render")
        }
        let original = try BoardPackage.read(from: URL(fileURLWithPath: boardPath))
        let wireText = LLMInterchange.export(original)

        // Strip at/size so the narrative layout does everything.
        guard let jsonString = LLMInterchange.extractJSONObject(from: wireText),
              var json = try JSONSerialization.jsonObject(with: Data(jsonString.utf8)) as? [String: Any],
              var nodes = json["nodes"] as? [[String: Any]] else {
            XCTFail("couldn't round-trip wire JSON"); return
        }
        for index in nodes.indices {
            nodes[index].removeValue(forKey: "at")
            nodes[index].removeValue(forKey: "size")
        }
        json["nodes"] = nodes
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let relaid = try LLMInterchange.parse(String(data: stripped, encoding: .utf8)!).board

        let frames = relaid.elements.values.compactMap(\.node?.frame)
        let width = (frames.map(\.maxX).max() ?? 0) - (frames.map(\.x).min() ?? 0)
        let height = (frames.map(\.maxY).max() ?? 0) - (frames.map(\.y).min() ?? 0)
        print("RELAYOUT extent: \(Int(width)) x \(Int(height)) pt for \(frames.count) blocks")

        let image = try XCTUnwrap(BoardSnapshot.image(of: relaid, pointSize: CGSize(width: 1500, height: 950)))
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outPath))
    }
}
