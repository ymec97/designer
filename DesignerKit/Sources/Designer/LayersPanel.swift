import SwiftUI
import DesignerModel

/// View state for the layers panel (view concerns only — layer data itself
/// lives in the board).
final class LayersPanelModel: ObservableObject {
    @Published var isVisible = false
    @Published var activeLayerID: LayerID?
    @Published var focusEnabled = false
}

struct LayersPanelActions {
    var setVisible: (LayerID, Bool) -> Void
    var setLocked: (LayerID, Bool) -> Void
    var rename: (LayerID, String) -> Void
    var setTint: (LayerID, String?) -> Void
    var addLayer: () -> Void
    var duplicate: (LayerID) -> Void
    var delete: (LayerID) -> Void
    var move: (IndexSet, Int) -> Void
    var setActive: (LayerID) -> Void
    var setFocus: (Bool) -> Void
    var assignSelection: (LayerID) -> Void
}

/// Wrapper that renders nothing while the panel is hidden.
struct LayersPanelContainer: View {
    @ObservedObject var document: BoardDocument
    @ObservedObject var model: LayersPanelModel
    let actions: LayersPanelActions

    var body: some View {
        if model.isVisible {
            LayersPanel(document: document, model: model, actions: actions)
        }
    }
}

/// Floating layers card (⌘L). Layers are views over the same elements (D9):
/// the active layer receives new elements; focus dims everything else.
struct LayersPanel: View {
    @ObservedObject var document: BoardDocument
    @ObservedObject var model: LayersPanelModel
    let actions: LayersPanelActions

    private static let tintChoices: [(name: String, hex: String?)] = [
        ("None", nil),
        ("Blue", "#4A90D9"), ("Green", "#5FA55A"), ("Orange", "#E8943A"),
        ("Purple", "#9B6BD3"), ("Red", "#D95757"), ("Teal", "#3AAFA9"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            List {
                ForEach(document.board.layers) { layer in
                    row(for: layer)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                }
                .onMove { source, destination in
                    actions.move(source, destination)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: min(CGFloat(document.board.layers.count) * 34 + 12, 300))
        }
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("Layers")
                    .font(.system(size: 12, weight: .semibold))
                Text("⌘L")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    actions.addLayer()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Add layer")
            }
            if model.focusEnabled, let name = activeLayerName {
                Label("Focusing “\(name)” — other layers dimmed", systemImage: "scope")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            } else {
                Text("Click a row to make it active — new items land there")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var activeLayerName: String? {
        document.board.layers.first { $0.id == model.activeLayerID }?.name
    }

    private func row(for layer: Layer) -> some View {
        let isActive = model.activeLayerID == layer.id
        return HStack(spacing: 6) {
            Button {
                actions.setVisible(layer.id, !layer.isVisible)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(layer.isVisible ? .secondary : .tertiary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(layer.isVisible ? "Hide layer" : "Show layer")

            Circle()
                .fill(tintColor(layer.colorTint))
                .frame(width: 8, height: 8)

            EditableLayerName(
                name: layer.name,
                isActive: isActive,
                commit: { actions.rename(layer.id, $0) }
            )

            Spacer(minLength: 4)

            // Focus lives on the ACTIVE row so it is obvious what it dims.
            if isActive {
                Button {
                    actions.setFocus(!model.focusEnabled)
                } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 10, weight: model.focusEnabled ? .bold : .regular))
                        .foregroundStyle(model.focusEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                        .frame(width: 15)
                }
                .buttonStyle(.plain)
                .help("Focus this layer — dim everything else")
            }

            Text("\(document.board.elementCount(onLayer: layer.id))")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            let index = document.board.layers.firstIndex { $0.id == layer.id } ?? 0
            VStack(spacing: 0) {
                Button {
                    actions.move(IndexSet(integer: index), index - 1)
                } label: {
                    Image(systemName: "chevron.up").font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .help("Move layer up")
                Button {
                    actions.move(IndexSet(integer: index), index + 2)
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
                .disabled(index >= document.board.layers.count - 1)
                .help("Move layer down")
            }
            .foregroundStyle(.secondary)
            .frame(width: 12)

            Button {
                actions.setLocked(layer.id, !layer.isLocked)
            } label: {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 9))
                    .foregroundStyle(layer.isLocked ? .primary : .tertiary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(layer.isLocked ? "Unlock layer" : "Lock layer")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            isActive ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .onTapGesture { actions.setActive(layer.id) }
        .contextMenu {
            Button("Assign Selection to Layer") { actions.assignSelection(layer.id) }
            Button("Duplicate Layer") { actions.duplicate(layer.id) }
            Menu("Tint") {
                ForEach(Self.tintChoices, id: \.name) { choice in
                    Button(choice.name) { actions.setTint(layer.id, choice.hex) }
                }
            }
            Divider()
            let index = document.board.layers.firstIndex { $0.id == layer.id } ?? 0
            Button("Move Up") { actions.move(IndexSet(integer: index), index - 1) }
                .disabled(index == 0)
            Button("Move Down") { actions.move(IndexSet(integer: index), index + 2) }
                .disabled(index >= document.board.layers.count - 1)
            Divider()
            Button("Delete Layer", role: .destructive) { actions.delete(layer.id) }
                .disabled(document.board.layers.count <= 1)
        }
    }

    private func tintColor(_ hex: String?) -> Color {
        guard let hex, let color = NSColor(hexString: hex) else {
            return Color.secondary.opacity(0.35)
        }
        return Color(nsColor: color)
    }
}

/// Layer name: displays as text, double-click to edit in place.
private struct EditableLayerName: View {
    let name: String
    let isActive: Bool
    let commit: (String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($focused)
                .onSubmit { finish() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { finish() }
                }
                .onAppear { focused = true }
        } else {
            Text(name)
                .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .onTapGesture(count: 2) {
                    draft = name
                    editing = true
                }
        }
    }

    private func finish() {
        editing = false
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != name {
            commit(trimmed)
        }
    }
}
