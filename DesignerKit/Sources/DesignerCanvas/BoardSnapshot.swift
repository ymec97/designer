import AppKit
import DesignerModel

/// Renders a board to an image off-screen — used for library thumbnails now
/// and PNG/SVG raster export later (M6). Fits all content with padding.
public enum BoardSnapshot {
    /// A bitmap of `board`, `pointSize` points at `scale`× (pixels =
    /// pointSize × scale). Transparent where there's no content.
    public static func image(
        of board: Board,
        pointSize: CGSize,
        scale: CGFloat = 2,
        padding: Double = 12
    ) -> NSImage? {
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }
        let pixelWidth = Int(pointSize.width * scale)
        let pixelHeight = Int(pointSize.height * scale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = pointSize

        guard let nsContext = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        let context = nsContext.cgContext

        // Flip to the canvas's top-left, y-down world.
        context.translateBy(x: 0, y: pointSize.height)
        context.scaleBy(x: 1, y: -1)

        var viewport = CanvasViewport()
        if let bounds = board.contentBounds() {
            viewport.fit(bounds, in: pointSize, padding: padding)
        }

        let renderer = BoardRenderer()
        let frames = board.frameProvider()
        let offsets = EdgeGeometry.parallelOffsets(in: board)
        let spread = EdgeGeometry.anchorSpread(in: board)
        for element in board.elementsInZOrder {
            if let edge = element.edge {
                if let route = EdgeGeometry.route(for: edge, frames: frames, parallelOffset: offsets[element.id] ?? 0, anchorOffsets: spread[element.id]) {
                    renderer.drawEdge(edge, route: route, in: context, viewport: viewport, isSelected: false)
                }
            } else {
                renderer.draw(element, in: context, viewport: viewport, isSelected: false)
            }
        }

        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: pointSize)
        image.addRepresentation(bitmap)
        return image
    }

    /// PNG data for a board thumbnail.
    public static func pngThumbnail(of board: Board, pointSize: CGSize = CGSize(width: 160, height: 100)) -> Data? {
        guard let image = image(of: board, pointSize: pointSize),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
