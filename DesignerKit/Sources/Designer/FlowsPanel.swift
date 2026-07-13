import SwiftUI
import DesignerModel
import DesignerCanvas

struct FlowRowInfo: Identifiable, Equatable {
    let id: FlowID
    var name: String
    var colorIndex: Int
    var hops: Int
    var stale: Bool
}

final class FlowsPanelModel: ObservableObject {
    @Published var flows: [FlowRowInfo] = []
    @Published var focusedFlowID: FlowID?
    @Published var playingFlowID: FlowID?
    @Published var visible = false
    /// Live recording state, mirrored into the panel so the in-progress flow
    /// is visible where flows live (not only in the bottom bar).
    @Published var recording = false
    @Published var recordingConnectors = 0
}

struct FlowsPanelActions {
    var record: () -> Void
    var play: (FlowID) -> Void
    var toggleFocus: (FlowID) -> Void
    var delete: (FlowID) -> Void
    var rename: (FlowID, String) -> Void
}

/// The Flows panel (F5): recorded traffic journeys — play one, isolate one
/// (dim everything it doesn't touch), record a new one.
struct FlowsPanel: View {
    @ObservedObject var model: FlowsPanelModel
    let actions: FlowsPanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Flows").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GraphiteStyle.ink)
                Text("⌘J").font(.system(size: 10)).foregroundStyle(GraphiteStyle.inkFaint)
                Spacer()
                Button(action: actions.record) {
                    Label("Record", systemImage: "record.circle")
                        .font(.system(size: 11, weight: .medium))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(GraphiteStyle.accent)
                .help("Record a flow: select a source block first, then click the connectors traffic takes")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if model.recording {
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(model.recordingConnectors == 0
                         ? "Recording — click a highlighted connector"
                         : "Recording · \(model.recordingConnectors) connector\(model.recordingConnectors == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(GraphiteStyle.ink)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(GraphiteStyle.accentSoft.opacity(0.35))
            }

            if model.flows.isEmpty {
                if !model.recording {
                    Text("Record how a request travels:\nselect its source block, press Record,\nthen click each connector it takes.")
                        .font(.system(size: 11))
                        .foregroundStyle(GraphiteStyle.inkDim)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
            } else {
                Divider()
                VStack(spacing: 0) {
                    ForEach(model.flows) { flow in
                        FlowRow(
                            flow: flow,
                            isFocused: model.focusedFlowID == flow.id,
                            isPlaying: model.playingFlowID == flow.id,
                            actions: actions
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(width: 252)
        .floatingPanel(radius: 12)
        .graphiteAccent()
    }
}

private struct FlowRow: View {
    let flow: FlowRowInfo
    let isFocused: Bool
    let isPlaying: Bool
    let actions: FlowsPanelActions
    @State private var editedName = ""
    @FocusState private var editing: Bool

    private var color: Color {
        Color(nsColor: Graphite.flowColors[flow.colorIndex % Graphite.flowColors.count])
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            TextField("Flow name", text: $editedName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(GraphiteStyle.ink)
                .focused($editing)
                .onSubmit { actions.rename(flow.id, editedName) }
                .onAppear { editedName = flow.name }
                .onChange(of: flow.name) { editedName = $0 }
            if flow.stale {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("Some recorded connectors were deleted; playback skips them")
            }
            Spacer(minLength: 4)
            Text("\(flow.hops)")
                .font(.system(size: 10))
                .foregroundStyle(GraphiteStyle.inkFaint)
                .help("\(flow.hops) connector\(flow.hops == 1 ? "" : "s")")
            rowButton(isFocused ? "eye.fill" : "eye",
                      help: "Isolate this flow (dim everything else)",
                      active: isFocused) { actions.toggleFocus(flow.id) }
            rowButton(isPlaying ? "stop.fill" : "play.fill",
                      help: isPlaying ? "Stop" : "Play this flow",
                      active: isPlaying) { actions.play(flow.id) }
            rowButton("trash", help: "Delete flow", active: false) { actions.delete(flow.id) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isFocused || isPlaying ? GraphiteStyle.accentSoft.opacity(0.5) : .clear)
        )
    }

    private func rowButton(_ icon: String, help: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 18, height: 18)
                .foregroundStyle(active ? GraphiteStyle.accent : GraphiteStyle.inkDim)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: Record bar

final class FlowRecordBarModel: ObservableObject {
    @Published var recording = false
    @Published var connectors = 0
}

struct FlowRecordBarActions {
    var undo: () -> Void
    var cancel: () -> Void
    var save: () -> Void
}

/// Bottom bar shown while walking a flow's path. Zero-size when inactive.
struct FlowRecordBar: View {
    @ObservedObject var model: FlowRecordBarModel
    let actions: FlowRecordBarActions

    var body: some View {
        if model.recording {
            HStack(spacing: 12) {
                Circle().fill(.red).frame(width: 7, height: 7)
                Text(model.connectors == 0
                     ? "Recording flow — click the first connector the traffic takes"
                     : "Recording flow · \(model.connectors) connector\(model.connectors == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(GraphiteStyle.ink)
                Divider().frame(height: 18)
                Button("Undo", action: actions.undo)
                    .buttonStyle(.plain).font(.system(size: 12))
                    .foregroundStyle(GraphiteStyle.inkDim)
                    .disabled(model.connectors == 0)
                Button("Cancel", action: actions.cancel)
                    .buttonStyle(.plain).font(.system(size: 12))
                    .foregroundStyle(GraphiteStyle.inkDim)
                Button("Save Flow…", action: actions.save)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(GraphiteStyle.accent)
                    .disabled(model.connectors == 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .floatingPanel(radius: 12)
            .graphiteAccent()
        }
    }
}
