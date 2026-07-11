import CoreGraphics
import DesignerModel

/// World ↔ view coordinate mapping. The viewport is the whole navigation
/// state: `origin` is the world point visible at the view's top-left, `scale`
/// is pixels-per-world-unit. Pure math — unit-testable without AppKit.
public struct CanvasViewport: Equatable {
    public static let minScale: Double = 0.05
    public static let maxScale: Double = 16

    /// World coordinate at view (0, 0).
    public var origin: Point
    public var scale: Double

    public init(origin: Point = .zero, scale: Double = 1) {
        self.origin = origin
        self.scale = scale.clamped(to: Self.minScale...Self.maxScale)
    }

    // MARK: Conversions (view coordinates are top-left origin, y-down)

    public func toView(_ world: Point) -> CGPoint {
        CGPoint(x: (world.x - origin.x) * scale, y: (world.y - origin.y) * scale)
    }

    public func toWorld(_ view: CGPoint) -> Point {
        Point(x: origin.x + view.x / scale, y: origin.y + view.y / scale)
    }

    public func toView(_ world: Rect) -> CGRect {
        CGRect(
            x: (world.x - origin.x) * scale,
            y: (world.y - origin.y) * scale,
            width: world.width * scale,
            height: world.height * scale
        )
    }

    public func visibleWorldRect(viewSize: CGSize) -> Rect {
        Rect(
            x: origin.x,
            y: origin.y,
            width: viewSize.width / scale,
            height: viewSize.height / scale
        )
    }

    // MARK: Navigation

    /// Pan by a delta given in view pixels.
    public mutating func pan(viewDeltaX dx: CGFloat, viewDeltaY dy: CGFloat) {
        origin.x -= Double(dx) / scale
        origin.y -= Double(dy) / scale
    }

    /// Multiply the scale, keeping the world point under `viewAnchor` fixed
    /// on screen (zoom toward the cursor).
    public mutating func zoom(by factor: Double, at viewAnchor: CGPoint) {
        let anchorWorld = toWorld(viewAnchor)
        scale = (scale * factor).clamped(to: Self.minScale...Self.maxScale)
        origin.x = anchorWorld.x - Double(viewAnchor.x) / scale
        origin.y = anchorWorld.y - Double(viewAnchor.y) / scale
    }

    public mutating func setScale(_ newScale: Double, at viewAnchor: CGPoint) {
        let clamped = newScale.clamped(to: Self.minScale...Self.maxScale)
        zoom(by: clamped / scale, at: viewAnchor)
    }

    /// Fit `worldRect` into `viewSize` with padding, centered.
    public mutating func fit(_ worldRect: Rect, in viewSize: CGSize, padding: Double = 40) {
        guard worldRect.width > 0, worldRect.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return }
        let paddedWidth = worldRect.width + padding * 2
        let paddedHeight = worldRect.height + padding * 2
        scale = min(
            Double(viewSize.width) / paddedWidth,
            Double(viewSize.height) / paddedHeight
        ).clamped(to: Self.minScale...Self.maxScale)
        origin = Point(
            x: worldRect.midX - Double(viewSize.width) / (2 * scale),
            y: worldRect.midY - Double(viewSize.height) / (2 * scale)
        )
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
