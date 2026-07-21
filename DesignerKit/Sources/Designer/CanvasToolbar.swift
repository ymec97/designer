import SwiftUI
import DesignerCanvas
import DesignerModel

/// The app's one piece of persistent chrome (D17): a floating capsule with
/// the four core actions and their shortcuts, Excalidraw-style. Everything
/// else stays in menus and keys.
final class ToolbarState: ObservableObject {
    @Published var tool: CanvasView.Tool = .select
    @Published var layersPanelVisible = false
    @Published var libraryPanelVisible = false
    @Published var simulating = false
    @Published var recordingFlow = false
    @Published var chatVisible = false
    @Published var flowsPanelVisible = false
    @Published var shapePickerVisible = false

    var shapeToolActive: Bool {
        if case .shape = tool { return true }
        return false
    }
}

/// One entry in the shape picker: what the button shows and what tool it
/// activates. Square/Circle are the aspect-locked variants of their shapes.
struct ShapeChoice: Identifiable {
    let id: String
    let icon: String
    let shape: NodeShape
    let lockAspect: Bool

    static let all: [ShapeChoice] = [
        ShapeChoice(id: "Rectangle", icon: "rectangle", shape: .rectangle, lockAspect: false),
        ShapeChoice(id: "Square", icon: "square", shape: .rectangle, lockAspect: true),
        ShapeChoice(id: "Ellipse", icon: "oval", shape: .ellipse, lockAspect: false),
        ShapeChoice(id: "Circle", icon: "circle", shape: .ellipse, lockAspect: true),
        ShapeChoice(id: "Diamond", icon: "diamond", shape: .diamond, lockAspect: false),
        ShapeChoice(id: "Triangle", icon: "triangle", shape: .triangle, lockAspect: false),
    ]
}

struct CanvasToolbar: View {
    @ObservedObject var state: ToolbarState
    let onSelectTool: () -> Void
    let onDrawTool: () -> Void
    let onShapeChosen: (ShapeChoice) -> Void
    let onLayers: () -> Void
    let onFlows: () -> Void
    let onSimulate: () -> Void
    let onRecordFlow: () -> Void
    let onAssistant: () -> Void
    let onCommandPalette: () -> Void

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
            toolButton(
                icon: "square.on.circle", hint: "S", label: "Shapes",
                help: "Shapes (S) — pick a shape, then drag it out on the canvas",
                isActive: state.shapeToolActive,
                action: { state.shapePickerVisible.toggle() }
            )
            .popover(isPresented: $state.shapePickerVisible, arrowEdge: .bottom) {
                ShapePickerView { choice in
                    state.shapePickerVisible = false
                    onShapeChosen(choice)
                }
            }
            Divider().frame(height: 22).padding(.horizontal, 3)
            toolButton(
                icon: state.simulating ? "stop.fill" : "play.fill",
                hint: "⌘↩",
                label: state.simulating ? "Stop" : "Simulate",
                help: "Simulate traffic (⌘↩) — select a node, then watch data flow from it",
                isActive: state.simulating, action: onSimulate
            )
            toolButton(
                icon: state.recordingFlow ? "stop.circle" : "record.circle",
                hint: "⇧⌘↩",
                label: state.recordingFlow ? "Stop" : "Record",
                help: "Record a flow (⇧⌘↩) — select the source block, then click each block the traffic visits",
                isActive: state.recordingFlow, action: onRecordFlow
            )
            Divider().frame(height: 22).padding(.horizontal, 3)
            toolButton(
                icon: "square.3.layers.3d", hint: "⌘L", label: "Layers",
                help: "Layers (⌘L) — view the same board through different concerns",
                isActive: state.layersPanelVisible, action: onLayers
            )
            toolButton(
                icon: "point.topleft.down.curvedto.point.bottomright.up", hint: "⌘J", label: "Flows",
                help: "Flows (⌘J) — recorded traffic journeys: play, isolate, record",
                isActive: state.flowsPanelVisible, action: onFlows
            )
            Divider().frame(height: 22).padding(.horizontal, 3)
            toolButton(
                icon: "sparkles", hint: "⇧⌘A", label: "Assistant",
                help: "Assistant (⇧⌘A) — chat with an AI that reads the board and proposes edits you review",
                isActive: state.chatVisible, action: onAssistant
            )
            toolButton(
                icon: "command", hint: "⌘K", label: "Commands",
                help: "Command Palette (⌘K) — fuzzy-search every command",
                isActive: false, action: onCommandPalette
            )
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .floatingPanel(radius: 12)
    }

    private func toolButton(
        icon: String, hint: String, label: String,
        help: String? = nil,
        isActive: Bool, action: @escaping () -> Void
    ) -> some View {
        Self.toolButton(icon: icon, hint: hint, label: label, help: help,
                        isActive: isActive, action: action)
    }

    static func toolButton(
        icon: String, hint: String, label: String,
        help: String? = nil,
        isActive: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(height: 17)
                Text(hint)
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(isActive ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(GraphiteStyle.inkFaint))
            }
            .frame(width: 42, height: 37)
            .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(GraphiteStyle.ink))
            .background(
                isActive ? AnyShapeStyle(GraphiteStyle.accent) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(help ?? "\(label)  (\(hint))")
        .accessibilityLabel(label)
    }
}

/// The shape picker popover: a compact grid of the basic shapes. Choosing
/// one activates the shape tool — drag on the canvas to size it.
struct ShapePickerView: View {
    let choose: (ShapeChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drag on the canvas to size the shape")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(64)), count: 3), spacing: 6) {
                ForEach(ShapeChoice.all) { choice in
                    Button {
                        choose(choice)
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: choice.icon)
                                .font(.system(size: 17, weight: .medium))
                                .frame(height: 20)
                            Text(choice.id)
                                .font(.system(size: 9.5))
                        }
                        .frame(width: 60, height: 46)
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
        .padding(12)
        .graphiteAccent()
    }
}
