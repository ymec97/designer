import SwiftUI
import DesignerModel

final class InspectorModel: ObservableObject {
    @Published var visible = false
    /// The element being inspected (single selection only), or nil.
    @Published var element: Element?
    @Published var selectionCount = 0
}

struct InspectorActions {
    /// Commits an edited element to the document (one undo step).
    var apply: (Element) -> Void
}

/// The Inspector (feature 2): edit the selected element's structured
/// properties directly — the same metadata the LLM format carries.
struct InspectorPanel: View {
    @ObservedObject var model: InspectorModel
    let actions: InspectorActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Inspector").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GraphiteStyle.ink)
                Text("⌥⌘I").font(.system(size: 10)).foregroundStyle(GraphiteStyle.inkFaint)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()

            Group {
                if let element = model.element {
                    content(for: element)
                } else {
                    Text(model.selectionCount > 1
                         ? "\(model.selectionCount) elements selected.\nSelect a single one to edit its properties."
                         : "Select a block, connector, note,\nor boundary to edit its properties.")
                        .font(.system(size: 11))
                        .foregroundStyle(GraphiteStyle.inkDim)
                        .padding(12)
                }
            }
        }
        .frame(width: 236)
        .floatingPanel(radius: 12)
        .graphiteAccent()
    }

    @ViewBuilder
    private func content(for element: Element) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch element.content {
            case .node(let node):
                nodeFields(element, node)
            case .edge(let edge):
                edgeFields(element, edge)
            case .note(let note):
                textFields(element, title: "Note", text: note.text) { text in
                    var updated = element
                    var value = note; value.text = text
                    updated.content = .note(value)
                    return updated
                }
            case .boundary(let boundary):
                textFields(element, title: "Boundary", text: boundary.text) { text in
                    var updated = element
                    var value = boundary; value.text = text
                    updated.content = .boundary(value)
                    return updated
                }
            case .ink:
                Text("Freehand stroke — use ⌘R to structurize.")
                    .font(.system(size: 11)).foregroundStyle(GraphiteStyle.inkDim)
            }
        }
        .padding(12)
    }

    // MARK: Node

    @ViewBuilder
    private func nodeFields(_ element: Element, _ node: Node) -> some View {
        row("Name") {
            CommitTextField(text: node.semantic.name, placeholder: "Name") { text in
                var updated = element
                var value = node; value.semantic.name = text
                updated.content = .node(value)
                actions.apply(updated)
            }
        }
        row("Kind") {
            Picker("", selection: binding(node.semantic.kind) { kind in
                var updated = element
                var value = node; value.semantic.kind = kind
                updated.content = .node(value)
                actions.apply(updated)
            }) {
                ForEach(options(NodeKind.allBuiltIn, current: node.semantic.kind), id: \.self) { kind in
                    Text(kind.rawValue.capitalized).tag(kind)
                }
            }
            .labelsHidden()
        }
        row("Shape") {
            Picker("", selection: binding(node.shape) { shape in
                var updated = element
                var value = node; value.shape = shape
                updated.content = .node(value)
                actions.apply(updated)
            }) {
                ForEach(options(NodeShape.allBuiltIn, current: node.shape), id: \.self) { shape in
                    Text(shape.rawValue.capitalized).tag(shape)
                }
            }
            .labelsHidden()
        }
        if node.shape == .triangle {
            row("Points") {
                Picker("", selection: binding(node.orientation) { orientation in
                    var updated = element
                    var value = node; value.orientation = orientation
                    updated.content = .node(value)
                    actions.apply(updated)
                }) {
                    ForEach(ShapeOrientation.allBuiltIn, id: \.self) { orientation in
                        Text(orientation.rawValue.capitalized).tag(orientation)
                    }
                }
                .labelsHidden()
            }
        }
        Divider().padding(.vertical, 2)
        InspectorStyleSection(style: node.style, isInk: false) { style in
            var updated = element
            var value = node; value.style = style
            updated.content = .node(value)
            actions.apply(updated)
        }
    }

    // MARK: Edge

    @ViewBuilder
    private func edgeFields(_ element: Element, _ edge: DesignerModel.Edge) -> some View {
        row("Label") {
            CommitTextField(text: edge.semantic.label ?? "", placeholder: "What happens") { text in
                apply(element, edge) { $0.semantic.label = text.isEmpty ? nil : text }
            }
        }
        row("Direction") {
            Picker("", selection: binding(edge.semantic.direction) { direction in
                apply(element, edge) { $0.semantic.direction = direction }
            }) {
                ForEach(options(EdgeDirection.allBuiltIn, current: edge.semantic.direction), id: \.self) { direction in
                    Text(direction.rawValue.capitalized).tag(direction)
                }
            }
            .labelsHidden()
        }
        row("Protocol") {
            CommitTextField(text: edge.semantic.properties[WellKnownEdgeProperty.protocolKey] ?? "", placeholder: "gRPC, HTTPS…") { text in
                apply(element, edge) { $0.semantic.properties[WellKnownEdgeProperty.protocolKey] = text.isEmpty ? nil : text }
            }
        }
        row("Data") {
            CommitTextField(text: edge.semantic.properties[WellKnownEdgeProperty.data] ?? "", placeholder: "Payload") { text in
                apply(element, edge) { $0.semantic.properties[WellKnownEdgeProperty.data] = text.isEmpty ? nil : text }
            }
        }
        row("Condition") {
            CommitTextField(text: edge.semantic.properties[WellKnownEdgeProperty.condition] ?? "", placeholder: "Only when…") { text in
                apply(element, edge) { $0.semantic.properties[WellKnownEdgeProperty.condition] = text.isEmpty ? nil : text }
            }
        }
    }

    private func apply(_ element: Element, _ edge: DesignerModel.Edge, mutate: (inout DesignerModel.Edge) -> Void) {
        var updated = element
        var value = edge
        mutate(&value)
        updated.content = .edge(value)
        actions.apply(updated)
    }

    // MARK: Text (note / boundary)

    @ViewBuilder
    private func textFields(_ element: Element, title: String, text: String, build: @escaping (String) -> Element) -> some View {
        row(title) {
            CommitTextField(text: text, placeholder: title) { newText in
                actions.apply(build(newText))
            }
        }
    }

    // MARK: Helpers

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(GraphiteStyle.inkDim)
                .frame(width: 62, alignment: .trailing)
            content()
        }
    }

    /// Built-in options plus the current value when it's a custom string
    /// (open enums round-trip unknown values).
    private func options<T: Hashable>(_ builtIn: [T], current: T) -> [T] {
        builtIn.contains(current) ? builtIn : builtIn + [current]
    }

    private func binding<T: Hashable>(_ value: T, apply: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: { value }, set: { apply($0) })
    }
}

/// A text field that commits on Return or focus loss — not per keystroke —
/// so each edit is one undo step.
private struct CommitTextField: View {
    let text: String
    let placeholder: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.system(size: 11))
            .focused($focused)
            .onAppear { draft = text }
            .onChange(of: text) { draft = $0 }
            .onSubmit { if draft != text { commit(draft) } }
            .onChange(of: focused) { isFocused in
                if !isFocused, draft != text { commit(draft) }
            }
    }
}
