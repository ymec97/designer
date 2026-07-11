import SwiftUI
import DesignerModel

/// Popover editor for a connector: label, the well-known data-transmission
/// keys (D8), direction, and routing. Deliberately small — full property
/// editing arrives with the inspector.
struct EdgeEditorView: View {
    struct Values: Equatable {
        var label: String
        var protocolValue: String
        var data: String
        var condition: String
        var direction: EdgeDirection
        var routing: RoutingMode

        init(edge: DesignerModel.Edge) {
            label = edge.semantic.label ?? ""
            protocolValue = edge.semantic.properties[WellKnownEdgeProperty.protocolKey] ?? ""
            data = edge.semantic.properties[WellKnownEdgeProperty.data] ?? ""
            condition = edge.semantic.properties[WellKnownEdgeProperty.condition] ?? ""
            direction = edge.semantic.direction
            routing = edge.routing
        }

        /// A copy of `edge` with these values applied.
        func applied(to edge: DesignerModel.Edge) -> DesignerModel.Edge {
            var edge = edge
            edge.semantic.label = label.isEmpty ? nil : label
            edge.semantic.direction = direction
            edge.routing = routing
            var properties = edge.semantic.properties
            properties[WellKnownEdgeProperty.protocolKey] = protocolValue.isEmpty ? nil : protocolValue
            properties[WellKnownEdgeProperty.data] = data.isEmpty ? nil : data
            properties[WellKnownEdgeProperty.condition] = condition.isEmpty ? nil : condition
            edge.semantic.properties = properties
            return edge
        }
    }

    @State var values: Values
    let onChange: (Values) -> Void

    var body: some View {
        Form {
            TextField("Label", text: $values.label, prompt: Text("e.g. order created"))
            TextField("Protocol", text: $values.protocolValue, prompt: Text("e.g. gRPC, HTTPS, SQS"))
            TextField("Data", text: $values.data, prompt: Text("e.g. OrderEvent"))
            TextField("Condition", text: $values.condition, prompt: Text("e.g. on checkout"))
            Picker("Direction", selection: $values.direction) {
                Text("→").tag(EdgeDirection.forward)
                Text("←").tag(EdgeDirection.backward)
                Text("↔").tag(EdgeDirection.both)
                Text("—").tag(EdgeDirection.none)
            }
            .pickerStyle(.segmented)
            Picker("Routing", selection: $values.routing) {
                Text("Straight").tag(RoutingMode.straight)
                Text("Orthogonal").tag(RoutingMode.orthogonal)
            }
            .pickerStyle(.segmented)
        }
        .padding(14)
        .frame(width: 300)
        .onChange(of: values) { _, newValues in
            onChange(newValues)
        }
    }
}
