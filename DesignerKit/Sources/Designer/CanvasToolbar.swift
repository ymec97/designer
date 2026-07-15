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
}

struct CanvasToolbar: View {
    @ObservedObject var state: ToolbarState
    let onSelectTool: () -> Void
    let onDrawTool: () -> Void
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
