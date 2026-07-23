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

/// A composition, projected for the panel: its header fields plus the tree
/// flattened into indented rows (the controller builds `rows`).
struct CompositionRowInfo: Identifiable, Equatable {
    let id: FlowCompositionID
    var name: String
    var mode: FlowComposition.Mode
    var stale: Bool
    var rows: [CompositionChildRow]
}

struct CompositionChildRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case flow(name: String, colorIndex: Int, stale: Bool)
        case group(mode: FlowComposition.Mode)
    }
    /// Stable synthetic id, e.g. "comp/0/2" — path within the tree.
    let id: String
    var path: [Int]
    var depth: Int
    var kind: Kind
}

final class FlowsPanelModel: ObservableObject {
    @Published var flows: [FlowRowInfo] = []
    @Published var focusedFlowID: FlowID?
    @Published var playingFlowID: FlowID?
    /// Per-flow playback speed multiplier (1 = default pace).
    @Published var speeds: [FlowID: Double] = [:]
    @Published var visible = false
    /// Live recording state, mirrored into the panel so the in-progress flow
    /// is visible where flows live (not only in the bottom bar).
    @Published var recording = false
    @Published var recordingConnectors = 0

    // Compositions (serial/parallel hierarchies over flows).
    @Published var compositions: [CompositionRowInfo] = []
    @Published var playingCompositionID: FlowCompositionID?
    @Published var compositionSpeeds: [FlowCompositionID: Double] = [:]
    /// View-only: which composition trees are expanded.
    @Published var expandedCompositions: Set<FlowCompositionID> = []
}

struct FlowsPanelActions {
    var record: () -> Void
    var play: (FlowID) -> Void
    var toggleFocus: (FlowID) -> Void
    var delete: (FlowID) -> Void
    var rename: (FlowID, String) -> Void
    var cycleSpeed: (FlowID) -> Void

    // Compositions
    var createComposition: (FlowComposition.Mode) -> Void = { _ in }
    var playComposition: (FlowCompositionID) -> Void = { _ in }
    var deleteComposition: (FlowCompositionID) -> Void = { _ in }
    var renameComposition: (FlowCompositionID, String) -> Void = { _, _ in }
    var cycleCompositionSpeed: (FlowCompositionID) -> Void = { _ in }
    /// Toggle serial↔parallel for the group at `path` (empty = the whole comp).
    var toggleGroupMode: (FlowCompositionID, [Int]) -> Void = { _, _ in }
    var addFlowToGroup: (FlowCompositionID, [Int], FlowID) -> Void = { _, _, _ in }
    var addNestedGroup: (FlowCompositionID, [Int], FlowComposition.Mode) -> Void = { _, _, _ in }
    var removeChild: (FlowCompositionID, [Int]) -> Void = { _, _ in }
    var moveChild: (FlowCompositionID, [Int], Bool) -> Void = { _, _, _ in }
    /// Flows offered in the "add flow" menus.
    var availableFlows: () -> [FlowRowInfo] = { [] }
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
                .help("Record a flow: select a source block first, then click each block the traffic visits")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if model.recording {
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(model.recordingConnectors == 0
                         ? "Recording — click the next highlighted block"
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
                    Text("Record how a request travels:\nselect its source block, press Record,\nthen click each block it visits next.")
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
                            speed: model.speeds[flow.id] ?? 1,
                            actions: actions
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 6)
            }

            compositionsSection
        }
        .frame(width: 318)
        .floatingPanel(radius: 12)
        .graphiteAccent()
    }

    @ViewBuilder private var compositionsSection: some View {
        Divider()
        HStack {
            Text("Compositions").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GraphiteStyle.ink)
            Spacer()
            Menu {
                Button("New Serial Composition") { actions.createComposition(.serial) }
                Button("New Parallel Composition") { actions.createComposition(.parallel) }
            } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .foregroundStyle(GraphiteStyle.accent)
            .help("Chain recorded flows to play in sequence or together")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

        if model.compositions.isEmpty {
            Text("Group flows to play them in sequence\nor at the same time.")
                .font(.system(size: 11))
                .foregroundStyle(GraphiteStyle.inkDim)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        } else {
            VStack(spacing: 0) {
                ForEach(model.compositions) { comp in
                    CompositionView(
                        comp: comp,
                        isPlaying: model.playingCompositionID == comp.id,
                        isExpanded: model.expandedCompositions.contains(comp.id),
                        speed: model.compositionSpeeds[comp.id] ?? 1,
                        toggleExpanded: {
                            if model.expandedCompositions.contains(comp.id) {
                                model.expandedCompositions.remove(comp.id)
                            } else {
                                model.expandedCompositions.insert(comp.id)
                            }
                        },
                        actions: actions
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

/// One composition: a header row plus, when expanded, its flattened tree.
private struct CompositionView: View {
    let comp: CompositionRowInfo
    let isPlaying: Bool
    let isExpanded: Bool
    let speed: Double
    let toggleExpanded: () -> Void
    let actions: FlowsPanelActions
    @State private var editedName = ""

    private func modeBadge(_ mode: FlowComposition.Mode, path: [Int]) -> some View {
        Button { actions.toggleGroupMode(comp.id, path) } label: {
            Text(mode == .serial ? "series" : "parallel")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .padding(.horizontal, 6).frame(height: 16)
                .background(GraphiteStyle.accentSoft.opacity(0.7), in: Capsule())
                .foregroundStyle(GraphiteStyle.accent)
        }
        .buttonStyle(.plain)
        .help("Play these \(mode == .serial ? "one after another" : "at the same time") — click to switch")
    }

    private func addMenu(path: [Int]) -> some View {
        Menu {
            let flows = actions.availableFlows()
            if flows.isEmpty {
                Text("Record a flow first")
            } else {
                ForEach(flows) { f in
                    Button(f.name) { actions.addFlowToGroup(comp.id, path, f.id) }
                }
            }
            Divider()
            Button("Add Serial Group") { actions.addNestedGroup(comp.id, path, .serial) }
            Button("Add Parallel Group") { actions.addNestedGroup(comp.id, path, .parallel) }
        } label: {
            Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .foregroundStyle(GraphiteStyle.inkDim)
        .help("Add a flow or a nested group here")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: toggleExpanded) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(GraphiteStyle.inkDim).frame(width: 12)
                }.buttonStyle(.plain)
                TextField("Composition", text: $editedName)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .foregroundStyle(GraphiteStyle.ink)
                    .onSubmit { actions.renameComposition(comp.id, editedName) }
                    .onAppear { editedName = comp.name }
                    .onChange(of: comp.name) { editedName = $0 }
                modeBadge(comp.mode, path: [])
                if comp.stale {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help("Some referenced flows are missing or stale; playback skips them")
                }
                Spacer(minLength: 2)
                Button { actions.cycleCompositionSpeed(comp.id) } label: {
                    Text(speed == 1.5 ? "1.5x" : speed == 0.5 ? "½x" : "\(Int(speed))x")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .frame(width: 26, height: 18)
                        .background(GraphiteStyle.accentSoft.opacity(speed == 1 ? 0.35 : 0.9), in: Capsule())
                        .foregroundStyle(speed == 1 ? GraphiteStyle.inkDim : GraphiteStyle.accent)
                }.buttonStyle(.plain).help("Playback speed")
                addMenu(path: [])
                iconButton(isPlaying ? "stop.fill" : "play.fill", active: isPlaying,
                           help: isPlaying ? "Stop" : "Play composition") { actions.playComposition(comp.id) }
                iconButton("trash", active: false, help: "Delete composition") { actions.deleteComposition(comp.id) }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(isPlaying ? GraphiteStyle.accentSoft.opacity(0.5) : .clear))

            if isExpanded {
                ForEach(comp.rows) { row in
                    childRow(row)
                }
                if comp.rows.isEmpty {
                    Text("Empty — use ＋ to add flows")
                        .font(.system(size: 10)).foregroundStyle(GraphiteStyle.inkFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 22).padding(.vertical, 3)
                }
            }
        }
    }

    @ViewBuilder private func childRow(_ row: CompositionChildRow) -> some View {
        HStack(spacing: 6) {
            switch row.kind {
            case .flow(let name, let colorIndex, let stale):
                Circle().fill(Color(nsColor: Graphite.flowColors[colorIndex % Graphite.flowColors.count]))
                    .frame(width: 7, height: 7)
                Text(name).font(.system(size: 11)).foregroundStyle(GraphiteStyle.ink).lineLimit(1)
                if stale {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 9)).foregroundStyle(.orange)
                }
            case .group(let mode):
                modeBadge(mode, path: row.path)
                addMenu(path: row.path)
            }
            Spacer(minLength: 2)
            iconButton("chevron.up", active: false, help: "Move up") { actions.moveChild(comp.id, row.path, true) }
            iconButton("chevron.down", active: false, help: "Move down") { actions.moveChild(comp.id, row.path, false) }
            iconButton("xmark", active: false, help: "Remove") { actions.removeChild(comp.id, row.path) }
        }
        .padding(.vertical, 3)
        .padding(.leading, CGFloat(14 + row.depth * 14))
        .padding(.trailing, 6)
    }

    private func iconButton(_ icon: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10))
                .frame(width: 16, height: 16)
                .foregroundStyle(active ? GraphiteStyle.accent : GraphiteStyle.inkDim)
        }.buttonStyle(.plain).help(help)
    }
}

private struct FlowRow: View {
    let flow: FlowRowInfo
    let isFocused: Bool
    let isPlaying: Bool
    let speed: Double
    let actions: FlowsPanelActions
    @State private var editedName = ""
    @FocusState private var editing: Bool

    private var color: Color {
        Color(nsColor: Graphite.flowColors[flow.colorIndex % Graphite.flowColors.count])
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            TextField("Flow name", text: $editedName, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
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
            Button { actions.cycleSpeed(flow.id) } label: {
                Text(speed == 1.5 ? "1.5x" : speed == 0.5 ? "½x" : "\(Int(speed))x")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .frame(width: 26, height: 18)
                    .background(GraphiteStyle.accentSoft.opacity(speed == 1 ? 0.35 : 0.9), in: Capsule())
                    .foregroundStyle(speed == 1 ? GraphiteStyle.inkDim : GraphiteStyle.accent)
            }
            .buttonStyle(.plain)
            .help("Playback speed — click to cycle 1x → 1.5x → 2x → ½x")
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
                     ? "Recording flow — click the first block the traffic reaches"
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
