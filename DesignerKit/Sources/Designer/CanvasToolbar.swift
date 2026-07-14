import SwiftUI
import DesignerCanvas
import DesignerModel

/// The app's one piece of persistent chrome (D17): a floating capsule with
/// the four core actions and their shortcuts, Excalidraw-style. Everything
/// else stays in menus and keys.
/// The typed-block palette (feature 3): the kinds and symbolic shapes a user
/// can insert directly, with sensible shape defaults per kind.
struct BlockPaletteEntry: Identifiable {
    let title: String
    let icon: String
    let kind: NodeKind
    let shape: NodeShape
    var orientation: ShapeOrientation = .up
    var id: String { title }

    static let all: [BlockPaletteEntry] = [
        .init(title: "Service", icon: "square", kind: .service, shape: .rectangle),
        .init(title: "Database", icon: "cylinder", kind: .database, shape: .ellipse),
        .init(title: "Queue", icon: "text.line.first.and.arrowtriangle.forward", kind: .queue, shape: .rectangle),
        .init(title: "Cache", icon: "bolt.square", kind: .cache, shape: .rectangle),
        .init(title: "Gateway", icon: "point.3.connected.trianglepath.dotted", kind: .gateway, shape: .rectangle),
        .init(title: "Client", icon: "person.crop.square", kind: .client, shape: .rectangle),
        .init(title: "External", icon: "arrow.up.right.square", kind: .external, shape: .rectangle),
        .init(title: "Decision", icon: "diamond", kind: .generic, shape: .diamond),
        .init(title: "Alert", icon: "exclamationmark.triangle", kind: .generic, shape: .triangle),
    ]
}

final class ToolbarState: ObservableObject {
    @Published var tool: CanvasView.Tool = .select
    @Published var layersPanelVisible = false
    @Published var libraryPanelVisible = false
    @Published var simulating = false
    @Published var recordingFlow = false
}

struct CanvasToolbar: View {
    @ObservedObject var state: ToolbarState
    let onSelectTool: () -> Void
    let onDrawTool: () -> Void
    let onAddBlock: () -> Void
    let onStructurize: () -> Void
    let onLayers: () -> Void
    let onLibrary: () -> Void
    let onSimulate: () -> Void
    let onRecordFlow: () -> Void
    let onAddTypedBlock: (BlockPaletteEntry) -> Void

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
            Menu {
                ForEach(BlockPaletteEntry.all) { entry in
                    Button {
                        onAddTypedBlock(entry)
                    } label: {
                        Label(entry.title, systemImage: entry.icon)
                    }
                }
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: "plus.square")
                        .font(.system(size: 15, weight: .medium))
                        .frame(height: 20)
                    Text("⌘B").font(.system(size: 8)).foregroundStyle(GraphiteStyle.inkFaint)
                }
                .frame(width: 40, height: 36)
            } primaryAction: {
                onAddBlock()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(GraphiteStyle.inkDim)
            .help("Add Block (⌘B) — click for a plain block, or open the menu for a typed one")
            toolButton(
                icon: "wand.and.stars", hint: "⌘R", label: "Structurize",
                help: "Structurize (⌘R) — turn selected freehand sketches into clean blocks & connectors",
                isActive: false, action: onStructurize
            )
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
                help: "Record a flow (⇧⌘↩) — select the source block, then click the connectors the traffic takes",
                isActive: state.recordingFlow, action: onRecordFlow
            )
            Divider().frame(height: 22).padding(.horizontal, 3)
            toolButton(
                icon: "square.3.layers.3d", hint: "⌘L", label: "Layers",
                help: "Layers (⌘L) — view the same board through different concerns",
                isActive: state.layersPanelVisible, action: onLayers
            )
            toolButton(
                icon: "books.vertical", hint: "⌘Y", label: "Library",
                help: "Library (⌘Y) — save & reuse patterns; ⌥⌘S saves the selection",
                isActive: state.libraryPanelVisible, action: onLibrary
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
