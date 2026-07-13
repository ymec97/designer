import SwiftUI
import DesignerCanvas

/// Studio Graphite tokens for the SwiftUI chrome, bridged from the same
/// NSColor palette the canvas uses so the app reads as one system.
enum GraphiteStyle {
    static let accent = Color(nsColor: Graphite.accent)
    static let accentSoft = Color(nsColor: Graphite.accentSoft)
    static let ink = Color(nsColor: Graphite.ink)
    static let inkDim = Color(nsColor: Graphite.inkDim)
    static let inkFaint = Color(nsColor: Graphite.inkFaint)
    static let panel = Color(nsColor: Graphite.panel)
    static let hairline = Color(nsColor: Graphite.hairline)
    static let hairlineStrong = Color(nsColor: Graphite.hairlineStrong)

    static let panelRadius: CGFloat = 12
    static let panelShadow = Color.black.opacity(0.14)
}

/// The shared look for the app's floating panels (toolbar, layers, library):
/// material background, hairline border, soft shadow, consistent radius.
struct FloatingPanel: ViewModifier {
    var radius: CGFloat = GraphiteStyle.panelRadius
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(GraphiteStyle.hairline, lineWidth: 0.75)
            )
            .shadow(color: GraphiteStyle.panelShadow, radius: 14, y: 5)
    }
}

extension View {
    func floatingPanel(radius: CGFloat = GraphiteStyle.panelRadius) -> some View {
        modifier(FloatingPanel(radius: radius))
    }

    /// Tints controls to the app accent so the whole UI shares one accent
    /// regardless of the user's system accent colour.
    func graphiteAccent() -> some View { tint(GraphiteStyle.accent) }
}
