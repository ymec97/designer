import XCTest
import DesignerModel
@testable import DesignerCanvas

/// Utility check: renders the styled-shapes surface (no-fill grouping
/// rectangle, opacity, colored fills/strokes) to STYLE_PNG for eyeball
/// review, and pixel-verifies the no-fill contract.
final class StyleVisualCheck: XCTestCase {
    func testStyledShapesRender() throws {
        let env = ProcessInfo.processInfo.environment
        guard let outPath = env["STYLE_PNG"] else {
            throw XCTSkip("set STYLE_PNG to render")
        }

        var board = Board(title: "Styles")
        let layer = board.layers[0].id
        func insert(_ content: Element.Content, bottom: Bool = false) {
            let key = bottom
                ? SortKey.between(nil, board.elements.values.map(\.sortKey).min())
                : board.topSortKey
            try! board.apply(.insertElement(Element(layerIDs: [layer], sortKey: key, content: content)))
        }
        insert(.node(Node(semantic: NodeSemantic(name: "api"),
                          frame: Rect(x: 120, y: 120, width: 160, height: 80))))
        insert(.node(Node(semantic: NodeSemantic(name: "db"),
                          frame: Rect(x: 340, y: 120, width: 160, height: 80))))
        // The feature's poster child: a no-fill, half-transparent grouping
        // rectangle AROUND the two blocks, tucked to the back.
        insert(.node(Node(semantic: NodeSemantic(name: ""),
                          frame: Rect(x: 80, y: 80, width: 460, height: 160),
                          style: Style(fill: Style.noFill, stroke: "#D95757",
                                       strokeWidth: 2.5, opacity: 0.5))),
               bottom: true)
        // A filled colored shape with opacity for the blend check.
        insert(.node(Node(semantic: NodeSemantic(name: "cache"),
                          frame: Rect(x: 120, y: 320, width: 160, height: 80),
                          shape: .ellipse,
                          style: Style(fill: "#4A90D9", opacity: 0.4))))

        let image = try XCTUnwrap(BoardSnapshot.image(of: board, pointSize: CGSize(width: 700, height: 500)))
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outPath))

        // Pixel contract: inside the grouping rect but OUTSIDE the blocks
        // (e.g. the gap between api and db) the background must show — a
        // fill there means the "none" sentinel leaked into a paint.
        let scaleX = CGFloat(bitmap.pixelsWide) / 700
        let scaleY = CGFloat(bitmap.pixelsHigh) / 500
        func pixel(_ x: Double, _ y: Double) -> NSColor? {
            bitmap.colorAt(x: Int(CGFloat(x) * scaleX), y: Int(CGFloat(y) * scaleY))
        }
        let corner = try XCTUnwrap(pixel(5, 5), "canvas background sample")
        let gap = try XCTUnwrap(pixel(310, 160), "gap inside the grouping rect")
        func channels(_ c: NSColor) -> (Double, Double, Double) {
            let rgb = c.usingColorSpace(.sRGB)!
            return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        }
        let (br, bg, bb) = channels(corner)
        let (gr, gg, gb) = channels(gap)
        XCTAssertLessThan(abs(br - gr) + abs(bg - gg) + abs(bb - gb), 0.06,
                          "no-fill shape must not paint its interior")
        print("STYLE-VISUAL: background \(corner) vs grouping-rect interior \(gap) — no fill leak")
    }
}
