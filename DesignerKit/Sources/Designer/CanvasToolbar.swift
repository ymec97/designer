import SwiftUI
import DesignerCanvas

/// The app's one piece of persistent chrome (D17): a floating capsule with
/// the four core actions and their shortcuts, Excalidraw-style. Everything
/// else stays in menus and keys.
final class ToolbarState: ObservableObject {
    @Published var tool: CanvasView.Tool = .select
    @Published var layersPanelVisible = false
}

struct CanvasToolbar: View {
    @ObservedObject var state: ToolbarState
    let onSelectTool: () -> Void
    let onDrawTool: () -> Void
    let onAddBlock: () -> Void
    let onStructurize: () -> Void
    let onLayers: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            toolButton(
                icon: "cursorarrow", hint: "V", label: "Select",
                isActive: state.tool == .select, action: onSelectTool
            )
            toolButton(
                icon: "pencil.line", hint: "D", label: "Draw",
                isActive: state.tool == .draw, action: onDrawTool
            )
            Divider().frame(height: 22).padding(.horizontal, 3)
            toolButton(
                icon: "plus.square", hint: "⌘B", label: "Add Block",
                isActive: false, action: onAddBlock
            )
            toolButton(
                icon: "wand.and.stars", hint: "⌘R", label: "Structurize",
                isActive: false, action: onStructurize
            )
            Divider().frame(height: 22).padding(.horizontal, 3)
            toolButton(
                icon: "square.3.layers.3d", hint: "⌘L", label: "Layers",
                isActive: state.layersPanelVisible, action: onLayers
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private func toolButton(
        icon: String, hint: String, label: String,
        isActive: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(height: 17)
                Text(hint)
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(isActive ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
            }
            .frame(width: 42, height: 36)
            .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(
                isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("\(label)  (\(hint))")
        .accessibilityLabel(label)
    }
}
