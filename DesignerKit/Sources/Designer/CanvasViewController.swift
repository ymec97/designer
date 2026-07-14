import AppKit
import Combine
import SwiftUI
import DesignerAgent
import DesignerCanvas
import DesignerInterop
import DesignerModel
import DesignerPersistence
import DesignerRecognition
import UniformTypeIdentifiers

/// Binds a CanvasView to a BoardDocument: board changes flow down via
/// Combine, operations flow up into the document's undo-tracked perform.
final class CanvasViewController: NSViewController, CanvasViewDelegate {
    private static let liveRecognitionDefaultsKey = "LiveSketchRecognition"

    private unowned let document: BoardDocument
    private var boardSubscription: AnyCancellable?

    let canvasView = CanvasView()

    /// Live sketch→structure conversion on stroke end (D15). Default on;
    /// toggleable from the Board menu, persisted across launches.
    var liveRecognitionEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: Self.liveRecognitionDefaultsKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.liveRecognitionDefaultsKey)
        }
    }

    init(document: BoardDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("CanvasViewController is created in code")
    }

    override func loadView() {
        canvasView.delegate = self
        view = canvasView
    }

    private let toolbarState = ToolbarState()
    private let layersModel = LayersPanelModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        boardSubscription = document.$board.sink { [weak self] board in
            guard let self else { return }
            self.canvasView.board = board
            // Keep the active layer valid across undo/board changes.
            if let active = self.layersModel.activeLayerID,
               !board.layers.contains(where: { $0.id == active }) {
                self.setActiveLayer(board.layers.first?.id)
            } else if self.layersModel.activeLayerID == nil {
                self.setActiveLayer(board.layers.first?.id)
            }
            self.refreshFlowsPanel(board)
            self.refreshInspector()
        }
        canvasView.strokeFinished = { [weak self] id in
            self?.strokeFinished(id)
        }
        canvasView.toolChanged = { [weak self] tool in
            self?.toolbarState.tool = tool
        }
        installToolbar()
        installLayersPanel()
        installLibraryPanel()
        installCommandPalette()
        installSimulationTransport()
        installAgentProposalPanel()
        installFlowsPanel()
        installChatPanel()
        installInspectorPanel()
    }

    // MARK: Inspector (feature 2)

    private let inspectorModel = InspectorModel()
    private var inspectorHost: NSView?

    @objc func toggleInspector(_ sender: Any?) {
        inspectorModel.visible.toggle()
        inspectorHost?.isHidden = !inspectorModel.visible
        refreshInspector()
        view.window?.makeFirstResponder(canvasView)
    }

    private func refreshInspector() {
        inspectorModel.selectionCount = canvasView.selection.count
        if canvasView.selection.count == 1, let id = canvasView.selection.first {
            inspectorModel.element = document.board.elements[id]
        } else {
            inspectorModel.element = nil
        }
    }

    /// Commits an inspector edit as one undo step (also the self-test hook).
    func applyInspectorEdit(_ element: Element) {
        guard document.board.elements[element.id] != nil else { return }
        document.perform(.replaceElement(element), actionName: "Edit Properties")
    }

    private func installInspectorPanel() {
        let panel = InspectorPanel(
            model: inspectorModel,
            actions: InspectorActions(apply: { [weak self] element in
                self?.applyInspectorEdit(element)
            })
        )
        let host = NSHostingView(rootView: panel)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.isHidden = true
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            host.topAnchor.constraint(equalTo: view.topAnchor, constant: 78),
        ])
        inspectorHost = host
    }

    // MARK: In-app assistant (F6)

    private let chatModel = ChatPanelModel()
    private let chatEngine = ChatEngine()
    private var chatPanelHost: NSView?

    @objc func toggleChatPanel(_ sender: Any?) {
        chatModel.visible.toggle()
        chatPanelHost?.isHidden = !chatModel.visible
        if chatModel.visible {
            refreshChatSetupState()
            // Warm up the local MCP server so the first message is fast.
            AgentController.shared.ensureEnabled { _ in }
        }
    }

    private func refreshChatSetupState() {
        switch chatEngine.setupState {
        case .ready:
            chatModel.setupHint = nil
        case .notInstalled:
            chatModel.setupHint = """
            The assistant uses the Claude Code CLI so it's billed to your Claude \
            subscription (no API key). Install it, sign in once, then reopen this panel:

            1.  npm install -g @anthropic-ai/claude-code   (or: brew install claude-code)
            2.  Run `claude` in Terminal and log in
            """
        }
    }

    private func sendChatMessage(_ text: String) {
        chatModel.messages.append(ChatMessage(role: .user, text: text))
        chatModel.isThinking = true
        chatEngine.modelChoice = chatModel.modelChoice
        chatEngine.effortChoice = chatModel.effortChoice
        AgentController.shared.ensureEnabled { [weak self] endpoint in
            self?.chatEngine.send(text, mcpEndpoint: endpoint)
        }
    }

    private func handleChatEvent(_ event: ChatStreamEvent) {
        switch event {
        case .assistantText(let text):
            chatModel.messages.append(ChatMessage(role: .assistant, text: text))
        case .toolUse(let name):
            chatModel.messages.append(ChatMessage(
                role: .activity, text: ChatStreamParser.activityLabel(forTool: name)))
        case .finished(let success, let summary):
            chatModel.isThinking = false
            if !success {
                chatModel.messages.append(ChatMessage(
                    role: .error, text: summary ?? "The assistant stopped unexpectedly."))
            }
        case .sessionStarted, .ignored:
            break
        }
    }

    private func installChatPanel() {
        chatEngine.onEvent = { [weak self] event in self?.handleChatEvent(event) }
        let panel = ChatPanel(
            model: chatModel,
            actions: ChatPanelActions(
                send: { [weak self] text in self?.sendChatMessage(text) },
                stop: { [weak self] in
                    self?.chatEngine.stop()
                    self?.chatModel.isThinking = false
                },
                newConversation: { [weak self] in
                    self?.chatEngine.resetConversation()
                    self?.chatModel.messages = []
                    self?.chatModel.isThinking = false
                },
                close: { [weak self] in self?.toggleChatPanel(nil) }
            )
        )
        let host = NSHostingView(rootView: panel)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.isHidden = true
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            host.topAnchor.constraint(equalTo: view.topAnchor, constant: 78),
        ])
        chatPanelHost = host
    }

    // MARK: Flows (F5)

    private let flowsModel = FlowsPanelModel()
    private let recordBarModel = FlowRecordBarModel()
    private var flowsPanelHost: NSView?

    private func refreshFlowsPanel(_ board: Board) {
        flowsModel.flows = board.flows.map {
            FlowRowInfo(id: $0.id, name: $0.name, colorIndex: $0.colorIndex,
                        hops: $0.steps.reduce(0) { $0 + $1.edges.count },
                        stale: $0.isStale(in: board))
        }
        // Clear focus/playing state for flows that no longer exist.
        if let focused = flowsModel.focusedFlowID, !board.flows.contains(where: { $0.id == focused }) {
            flowsModel.focusedFlowID = nil
            canvasView.emphasizedElements = nil
        }
    }

    @objc func toggleFlowsPanel(_ sender: Any?) {
        flowsModel.visible.toggle()
        flowsPanelHost?.isHidden = !flowsModel.visible
        view.window?.makeFirstResponder(canvasView)
    }

    @objc func recordFlow(_ sender: Any?) {
        guard canvasView.selection.count == 1, let source = canvasView.selection.first,
              document.board.elements[source]?.node != nil else {
            let alert = NSAlert()
            alert.messageText = "Select a source block first"
            alert.informativeText = "Click the block the traffic starts from, then Record Flow: you'll walk the journey by clicking each connector it takes."
            alert.runModal()
            return
        }
        if !flowsModel.visible { toggleFlowsPanel(nil) }
        canvasView.startFlowRecording(from: source)
        view.window?.makeFirstResponder(canvasView)
    }

    private func saveRecordedFlow() {
        guard let recorder = canvasView.finishFlowRecording() else { return }
        let alert = NSAlert()
        alert.messageText = "Name this flow"
        alert.informativeText = "e.g. “Checkout (gRPC)” or “Login journey”"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "Flow \(document.board.flows.count + 1)"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        let flow = recorder.finish(
            name: name.isEmpty ? "Untitled flow" : name,
            colorIndex: document.board.flows.count % Graphite.flowColors.count
        )
        document.perform(.insertFlow(flow, at: document.board.flows.count), actionName: "Record Flow")
    }

    private func playFlow(_ id: FlowID) {
        if flowsModel.playingFlowID == id {
            canvasView.stopSimulation()
            return
        }
        guard let flow = document.board.flows.first(where: { $0.id == id }) else { return }
        canvasView.startFlowPlayback(flow)
        view.window?.makeFirstResponder(canvasView)
    }

    private func toggleFlowFocus(_ id: FlowID) {
        if flowsModel.focusedFlowID == id {
            flowsModel.focusedFlowID = nil
            canvasView.emphasizedElements = nil
        } else if let flow = document.board.flows.first(where: { $0.id == id }) {
            flowsModel.focusedFlowID = id
            canvasView.emphasizedElements = flow.memberElements
        }
    }

    /// Headless inspector check for --ui-test (feature 2): edit a node's
    /// name/kind/shape and an edge's protocol via the inspector apply path,
    /// verifying commits and single-step undo.
    func runInspectorSelfTest() -> String? {
        let layer = document.board.layers[0].id
        let node = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                           content: .node(Node(semantic: NodeSemantic(name: "insp-a"),
                                               frame: Rect(x: 0, y: 2100, width: 100, height: 50))))
        document.perform(.insertElement(node), actionName: "Inspector Test Node")

        canvasView.select([node.id])
        refreshInspector()
        guard inspectorModel.element?.id == node.id else { return "inspector didn't track selection" }

        // Edit name + kind + shape through the apply path.
        var edited = document.board.elements[node.id]!
        guard var n = edited.node else { return "node missing" }
        n.semantic.name = "orders-db"
        n.semantic.kind = .database
        n.shape = .ellipse
        edited.content = .node(n)
        applyInspectorEdit(edited)

        guard let after = document.board.elements[node.id]?.node,
              after.semantic.name == "orders-db", after.semantic.kind == .database,
              after.shape == .ellipse else {
            return "inspector edit not applied"
        }
        document.undoManager?.undo()
        guard document.board.elements[node.id]?.node?.semantic.name == "insp-a" else {
            return "inspector edit wasn't one undo step"
        }
        document.undoManager?.undo() // remove test node
        return nil
    }

    /// Headless groups+boundaries check for --ui-test (feature 4): group two
    /// blocks, verify whole-group selection and single-batch undo; drop a
    /// boundary around them, verify z-order (behind), frame, and undo.
    func runGroupsAndBoundariesSelfTest() -> String? {
        let layer = document.board.layers[0].id
        func node(_ name: String, _ x: Double) -> Element {
            Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                    content: .node(Node(semantic: NodeSemantic(name: name),
                                        frame: Rect(x: x, y: 1800, width: 100, height: 50))))
        }
        let a = node("grp-a", 0), b = node("grp-b", 200)
        document.perform(.batch([.insertElement(a), .insertElement(b)]), actionName: "Group Test Graph")

        // Group and verify expansion.
        canvasView.select([a.id, b.id])
        guard canvasView.canGroupSelection else { return "canGroupSelection false" }
        canvasView.groupSelection(nil)
        guard let groupID = document.board.elements[a.id]?.groupID,
              document.board.elements[b.id]?.groupID == groupID else {
            return "grouping didn't assign groupIDs"
        }
        guard document.board.expandSelectionToGroups([a.id]) == [a.id, b.id] else {
            return "selection expansion broken"
        }

        // Boundary around the group.
        canvasView.select([a.id, b.id])
        canvasView.addBoundaryAroundSelection(nil)
        canvasView.commitLabelEditor() // close the auto-opened label editor
        guard let boundaryElement = document.board.elements.values.first(where: { $0.boundary != nil }) else {
            return "boundary not inserted"
        }
        guard let frame = boundaryElement.boundary?.frame,
              frame.x < 0, frame.width > 300 else {
            return "boundary frame doesn't wrap the selection"
        }
        let minKey = document.board.elements.values.map(\.sortKey).min()
        guard boundaryElement.sortKey == minKey else {
            return "boundary is not at the bottom of the z-order"
        }

        // Ungroup works and undo unwinds each step.
        canvasView.select([a.id])
        guard canvasView.canUngroupSelection else { return "canUngroup false" }
        canvasView.ungroupSelection(nil)
        guard document.board.elements[a.id]?.groupID == nil else { return "ungroup failed" }

        document.undoManager?.undo() // regroup (undo ungroup)
        guard document.board.elements[a.id]?.groupID != nil else { return "undo(ungroup) failed" }
        document.undoManager?.undo() // remove boundary
        document.undoManager?.undo() // remove group
        document.undoManager?.undo() // remove test graph
        guard document.board.elements[a.id] == nil else { return "cleanup undo failed" }
        return nil
    }

    /// Headless flows check for --ui-test: builds the correlated-traffic
    /// scenario (parallel gRPC+HTTP connectors A→B and B→C), records the gRPC
    /// journey, saves it, plays it, and verifies only the recorded connectors
    /// participate — the thing flood simulation can't express.
    func runFlowSelfTest() -> String? {
        let layer = document.board.layers[0].id
        func node(_ name: String, _ x: Double) -> Element {
            Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                    content: .node(Node(semantic: NodeSemantic(name: name),
                                        frame: Rect(x: x, y: 1400, width: 100, height: 50))))
        }
        func edge(_ from: Element, _ to: Element, _ proto: String) -> Element {
            Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                    content: .edge(Edge(
                        semantic: EdgeSemantic(properties: [WellKnownEdgeProperty.protocolKey: proto]),
                        from: .element(from.id, side: nil, offset: nil),
                        to: .element(to.id, side: nil, offset: nil))))
        }
        let a = node("flow-a", 0), b = node("flow-b", 250), c = node("flow-c", 500)
        let abGRPC = edge(a, b, "gRPC"), abHTTP = edge(a, b, "HTTP")
        let bcGRPC = edge(b, c, "gRPC"), bcHTTP = edge(b, c, "HTTP")
        document.perform(.batch([
            .insertElement(a), .insertElement(b), .insertElement(c),
            .insertElement(abGRPC), .insertElement(abHTTP),
            .insertElement(bcGRPC), .insertElement(bcHTTP),
        ]), actionName: "Flow Test Graph")

        // Record the gRPC journey: both parallel edges must be offered, and
        // the recorder must let us take exactly the gRPC one at each hop.
        var recorder = FlowRecorder(source: a.id)
        let first = recorder.candidates(in: document.board)
        guard first.count == 2 else { return "expected 2 parallel candidates at A, got \(first.count)" }
        guard let firstGRPC = first.first(where: { $0.edge == abGRPC.id }),
              recorder.record(firstGRPC, in: document.board) else { return "couldn't record A→B gRPC" }
        guard let secondGRPC = recorder.candidates(in: document.board).first(where: { $0.edge == bcGRPC.id }),
              recorder.record(secondGRPC, in: document.board) else { return "couldn't record B→C gRPC" }

        let flow = recorder.finish(name: "gRPC journey", colorIndex: 1)
        document.perform(.insertFlow(flow, at: document.board.flows.count), actionName: "Record Flow")
        guard document.board.flows.contains(where: { $0.id == flow.id }) else { return "flow not saved" }

        // The recorded flow touches only the gRPC edges.
        let members = flow.memberElements
        guard members.contains(abGRPC.id), members.contains(bcGRPC.id),
              !members.contains(abHTTP.id), !members.contains(bcHTTP.id) else {
            return "flow members include HTTP edges (correlation broken)"
        }

        // Playback runs and is attributed to the flow.
        canvasView.startFlowPlayback(flow)
        guard canvasView.isSimulating, canvasView.playingFlowID == flow.id else {
            return "flow playback did not start"
        }
        canvasView.stopSimulation()

        // Focus isolates the journey.
        toggleFlowFocus(flow.id)
        guard canvasView.emphasizedElements == members else { return "flow focus wrong" }
        toggleFlowFocus(flow.id)
        guard canvasView.emphasizedElements == nil else { return "flow focus didn't clear" }

        // Reverse traversal (Yarden's bug): a bidirectional edge recorded
        // to→from must play the packet in traversal order, not storage order.
        let biEdge = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                             content: .edge(Edge(
                                 semantic: EdgeSemantic(direction: .both),
                                 from: .element(a.id, side: nil, offset: nil),
                                 to: .element(b.id, side: nil, offset: nil))))
        document.perform(.insertElement(biEdge), actionName: "Bi Edge")
        var reverseRecorder = FlowRecorder(source: b.id)
        guard let backCandidate = reverseRecorder.candidates(in: document.board)
                .first(where: { $0.edge == biEdge.id && $0.from == b.id && $0.to == a.id }) else {
            return "bidirectional edge not offered from its 'to' side"
        }
        reverseRecorder.record(backCandidate, in: document.board)
        let reverseFlow = reverseRecorder.finish(name: "reverse", colorIndex: 2)
        document.perform(.insertFlow(reverseFlow, at: document.board.flows.count), actionName: "Record Flow")
        canvasView.startFlowPlayback(reverseFlow)
        guard canvasView.reversedSimulationEdges.contains(biEdge.id) else {
            canvasView.stopSimulation()
            return "reverse traversal not detected — packet would fly storage direction"
        }
        canvasView.stopSimulation()

        document.undoManager?.undo() // remove reverse flow
        document.undoManager?.undo() // remove bi edge
        document.undoManager?.undo() // remove first flow
        document.undoManager?.undo() // remove test graph
        guard document.board.flows.isEmpty || !document.board.flows.contains(where: { $0.id == flow.id }) else {
            return "undo did not remove the flow"
        }
        return nil
    }

    private func installFlowsPanel() {
        let panel = FlowsPanel(
            model: flowsModel,
            actions: FlowsPanelActions(
                record: { [weak self] in self?.recordFlow(nil) },
                play: { [weak self] id in self?.playFlow(id) },
                toggleFocus: { [weak self] id in self?.toggleFlowFocus(id) },
                delete: { [weak self] id in
                    guard let self else { return }
                    if self.flowsModel.focusedFlowID == id { self.toggleFlowFocus(id) }
                    self.document.perform(.removeFlow(id), actionName: "Delete Flow")
                },
                rename: { [weak self] id, name in
                    guard let self, var flow = self.document.board.flows.first(where: { $0.id == id }),
                          !name.trimmingCharacters(in: .whitespaces).isEmpty, flow.name != name else { return }
                    flow.name = name
                    self.document.perform(.replaceFlow(flow), actionName: "Rename Flow")
                }
            )
        )
        let host = NSHostingView(rootView: panel)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.isHidden = true
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
        ])
        flowsPanelHost = host

        let bar = FlowRecordBar(
            model: recordBarModel,
            actions: FlowRecordBarActions(
                undo: { [weak self] in self?.canvasView.undoLastFlowConnector() },
                cancel: { [weak self] in self?.canvasView.cancelFlowRecording() },
                save: { [weak self] in self?.saveRecordedFlow() }
            )
        )
        let barHost = NSHostingView(rootView: bar)
        barHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(barHost)
        NSLayoutConstraint.activate([
            barHost.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            barHost.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
        ])

        canvasView.flowRecordingChanged = { [weak self] active, connectors in
            self?.recordBarModel.recording = active
            self?.recordBarModel.connectors = connectors
            self?.flowsModel.recording = active
            self?.flowsModel.recordingConnectors = connectors
            self?.toolbarState.recordingFlow = active
        }
        // Track play state for the panel's play/stop buttons.
        let existingHandler = canvasView.simulationStateChanged
        canvasView.simulationStateChanged = { [weak self] active, paused in
            existingHandler?(active, paused)
            self?.flowsModel.playingFlowID = active ? self?.canvasView.playingFlowID : nil
        }
    }

    // MARK: Traffic simulation (F2)

    private let simulationModel = SimulationTransportModel()

    @objc func simulateTraffic(_ sender: Any?) {
        // ⌘↩ / the toolbar button toggle: a running simulation stops.
        if canvasView.isSimulating {
            canvasView.stopSimulation()
            return
        }
        guard canvasView.selection.count == 1, let source = canvasView.selection.first,
              document.board.elements[source]?.node != nil else {
            NSSound.beep(); return
        }
        guard canvasView.canSimulate(from: source) else {
            // Nothing flows out of this node — tell the user why, gently.
            let alert = NSAlert()
            alert.messageText = "No outgoing connections"
            alert.informativeText = "Connect this block to others (with the arrow pointing away) to simulate traffic flowing from it."
            alert.runModal()
            return
        }
        canvasView.startSimulation(from: source)
        view.window?.makeFirstResponder(canvasView)
    }

    /// Headless copy → paste → duplicate check for --ui-test.
    func runClipboardSelfTest() -> String? {
        let layer = document.board.layers[0].id
        let a = Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                        content: .node(Node(semantic: NodeSemantic(name: "clip-src"),
                                            frame: Rect(x: 1200, y: 1200, width: 100, height: 50))))
        document.perform(.insertElement(a), actionName: "Clip Test Node")
        let baseCount = document.board.elements.count

        canvasView.select([a.id])
        canvasView.copy(nil)
        guard NSPasteboard.general.data(forType: CanvasView.clipPasteboardType) != nil else {
            return "copy did not write the clip pasteboard type"
        }

        canvasView.paste(nil)
        guard document.board.elements.count == baseCount + 1 else {
            return "paste did not add one element (\(document.board.elements.count) vs \(baseCount + 1))"
        }
        // The pasted element is selected and is a distinct copy.
        guard canvasView.selection.count == 1, let pastedID = canvasView.selection.first,
              pastedID != a.id else {
            return "pasted element not selected as a fresh copy"
        }
        guard document.board.elements[pastedID]?.node?.semantic.name == "clip-src" else {
            return "pasted node lost its content"
        }

        canvasView.duplicateSelection(nil)
        guard document.board.elements.count == baseCount + 2 else {
            return "duplicate did not add one element"
        }

        // Undo the whole test (duplicate, paste, insert).
        document.undoManager?.undo()
        document.undoManager?.undo()
        document.undoManager?.undo()
        return nil
    }

    /// Headless simulate check for --ui-test: builds a small A→B→C graph,
    /// runs and stops a simulation, verifies activation + model reachability.
    func runSimulationSelfTest() -> String? {
        let layer = document.board.layers[0].id
        func node(_ name: String, _ x: Double) -> Element {
            Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                    content: .node(Node(semantic: NodeSemantic(name: name),
                                        frame: Rect(x: x, y: 900, width: 100, height: 50))))
        }
        let a = node("sim-a", 0), b = node("sim-b", 200), c = node("sim-c", 400)
        func edge(_ from: Element, _ to: Element) -> Element {
            Element(layerIDs: [layer], sortKey: document.board.topSortKey,
                    content: .edge(Edge(from: .element(from.id, side: nil, offset: nil),
                                        to: .element(to.id, side: nil, offset: nil))))
        }
        document.perform(.batch([
            .insertElement(a), .insertElement(b), .insertElement(c),
            .insertElement(edge(a, b)), .insertElement(edge(b, c)),
        ]), actionName: "Sim Test Graph")

        let steps = TrafficSimulation.steps(from: a.id, in: document.board)
        guard steps.count == 2 else { return "expected 2 waves, got \(steps.count)" }

        canvasView.select([a.id])
        canvasView.startSimulation(from: a.id)
        guard canvasView.isSimulating else { return "startSimulation did not activate" }

        let reached = TrafficSimulation.reached(from: a.id, in: document.board)
        guard reached.nodes.isSuperset(of: [a.id, b.id, c.id]) else { return "did not reach a→b→c" }

        canvasView.stopSimulation()
        guard !canvasView.isSimulating else { return "stopSimulation did not deactivate" }

        document.undoManager?.undo() // remove the test graph
        return nil
    }

    // MARK: Agent proposals (F4)

    private let proposalModel = AgentProposalModel()
    private var pendingProposal: Board?

    /// Stage a proposed board for review. Computes the diff, shows the banner,
    /// and returns the diff (echoed to the agent). Nothing is applied yet.
    @discardableResult
    func presentAgentProposal(_ proposed: Board, note: String?) -> BoardDiff {
        let diff = LLMInterchange.diff(current: document.board, proposed: proposed)
        if diff.isEmpty {
            clearAgentProposal()
            return diff
        }
        pendingProposal = proposed
        proposalModel.pending = AgentProposalPending(
            summary: diff.summaryLine, detail: diff.detail, note: note
        )
        // Show the change on the canvas, not just in the banner: additions as
        // accent ghosts, removals marked red — and bring them into view.
        canvasView.proposalGhost = CanvasView.ProposalGhost(
            proposedBoard: proposed,
            addedElements: diff.addedElementIDs,
            removedElements: diff.removedElementIDs
        )
        if let ghostBounds = canvasView.proposalGhostBounds() {
            canvasView.reveal(worldRect: ghostBounds)
        }
        view.window?.makeKeyAndOrderFront(nil)
        return diff
    }

    @objc func acceptAgentProposal(_ sender: Any?) {
        guard let proposed = pendingProposal else { return }
        let layer = document.board.layers.first?.id ?? proposed.layers[0].id
        let operation = ProposalApply.replaceOperation(
            current: document.board, proposed: proposed, targetLayer: layer)
        document.perform(operation, actionName: "Accept Claude’s Proposal")
        canvasView.select([])
        clearAgentProposal()
    }

    @objc func rejectAgentProposal(_ sender: Any?) {
        clearAgentProposal()
    }

    private func clearAgentProposal() {
        pendingProposal = nil
        proposalModel.pending = nil
        canvasView.proposalGhost = nil
    }

    /// Whether a proposal is awaiting review (for the self-test and menus).
    var hasPendingProposal: Bool { pendingProposal != nil }

    /// The board the agent bridge reads (keeps `document` private to the class).
    func agentCurrentBoard() -> Board { document.board }

    /// Headless check for --ui-test: stage a proposal that adds a block, verify
    /// it's pending (not applied), accept it, verify it applied as one undo step.
    func runAgentProposalSelfTest() -> String? {
        let baseCount = document.board.elements.count
        let currentText = LLMInterchange.export(document.board)
        guard var parsed = try? LLMInterchange.parse(currentText).board else {
            return "couldn't round-trip current board"
        }
        // Add one node to the parsed copy, then re-serialize as the proposal.
        let layer = parsed.layers[0].id
        try? parsed.apply(.insertElement(Element(
            layerIDs: [layer], sortKey: parsed.topSortKey,
            content: .node(Node(semantic: NodeSemantic(name: "agent-added"),
                                frame: Rect(x: 40, y: 40, width: 120, height: 60))))))
        let proposedText = LLMInterchange.export(parsed)
        guard let proposed = try? LLMInterchange.parse(proposedText).board else {
            return "couldn't parse proposal"
        }

        let diff = presentAgentProposal(proposed, note: "test")
        guard !diff.isEmpty, hasPendingProposal else { return "proposal not staged" }
        guard document.board.elements.count == baseCount else {
            return "proposal was applied before approval"
        }
        // The addition must be ghost-visible on the canvas with real bounds.
        guard let ghost = canvasView.proposalGhost, ghost.addedElements.count == 1 else {
            return "proposal ghost not staged on canvas"
        }
        guard canvasView.proposalGhostBounds() != nil else {
            return "ghost bounds missing (reveal would not know where to go)"
        }

        acceptAgentProposal(nil)
        guard !hasPendingProposal else { return "proposal not cleared after accept" }
        guard canvasView.proposalGhost == nil else { return "ghost not cleared after accept" }
        guard document.board.elements.count == baseCount + 1 else {
            return "accept did not add the block (\(document.board.elements.count) vs \(baseCount + 1))"
        }
        document.undoManager?.undo()
        guard document.board.elements.count == baseCount else {
            return "accept was not a single undo step"
        }
        return nil
    }

    private func installAgentProposalPanel() {
        let panel = AgentProposalPanel(
            model: proposalModel,
            actions: AgentProposalActions(
                accept: { [weak self] in self?.acceptAgentProposal(nil) },
                reject: { [weak self] in self?.rejectAgentProposal(nil) }
            )
        )
        let host = NSHostingView(rootView: panel)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            // Below the floating toolbar (which sits at the top center).
            host.topAnchor.constraint(equalTo: view.topAnchor, constant: 78),
        ])
    }

    private func installSimulationTransport() {
        canvasView.simulationStateChanged = { [weak self] active, paused in
            self?.simulationModel.active = active
            self?.simulationModel.paused = paused
            self?.toolbarState.simulating = active
        }
        let actions = SimulationTransportActions(
            togglePause: { [weak self] in
                guard let self else { return }
                if self.simulationModel.paused { self.canvasView.resumeSimulation() }
                else { self.canvasView.pauseSimulation() }
            },
            restart: { [weak self] in self?.canvasView.restartSimulation() },
            setSpeed: { [weak self] speed in
                self?.canvasView.simulationSpeed = speed
                self?.simulationModel.speed = speed
            },
            exit: { [weak self] in self?.canvasView.stopSimulation() }
        )
        let transport = SimulationTransport(model: simulationModel, actions: actions)
        let host = NSHostingView(rootView: transport)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
        ])
    }

    // MARK: Command palette (⌘K)

    private let paletteModel = CommandPaletteModel()
    private weak var paletteHost: NSView?

    @objc func toggleCommandPalette(_ sender: Any?) {
        if paletteModel.isVisible {
            paletteModel.isVisible = false
            paletteHost?.isHidden = true
            view.window?.makeFirstResponder(canvasView)
        } else {
            paletteModel.query = ""
            paletteModel.commands = buildCommands()
            paletteModel.isVisible = true
            paletteHost?.isHidden = false
        }
    }

    private func installCommandPalette() {
        let container = CommandPaletteContainer(model: paletteModel) { [weak self] in
            self?.paletteModel.isVisible = false
            self?.view.window?.makeFirstResponder(self?.canvasView)
        }
        // Frame-based autoresizing (not Auto Layout) so this full-size overlay
        // never entangles the canvas's own sizing.
        let host = PalettePassthroughHostingView(rootView: container)
        host.isActive = { [weak self] in self?.paletteModel.isVisible ?? false }
        host.isHidden = true // hidden views don't hit-test; shown only with the palette
        host.frame = view.bounds
        host.autoresizingMask = [.width, .height]
        view.addSubview(host)
        paletteHost = host
    }

    private func buildCommands() -> [PaletteCommand] {
        [
            PaletteCommand(title: "Add Block", shortcut: "⌘B", systemImage: "plus.square") { [weak self] in
                self?.canvasView.addBlock(nil)
            },
        ] + BlockPaletteEntry.all.map { entry in
            PaletteCommand(title: "Add \(entry.title) Block", shortcut: nil, systemImage: entry.icon) { [weak self] in
                self?.canvasView.addBlock(kind: entry.kind, shape: entry.shape, orientation: entry.orientation)
            }
        } + [
            PaletteCommand(title: "Draw Tool", shortcut: "D", systemImage: "pencil.line") { [weak self] in
                self?.canvasView.activateDrawTool(nil)
            },
            PaletteCommand(title: "Select Tool", shortcut: "V", systemImage: "cursorarrow") { [weak self] in
                self?.canvasView.activateSelectTool(nil)
            },
            PaletteCommand(title: "Structurize Sketch into Shapes", shortcut: "⌘R", systemImage: "wand.and.stars") { [weak self] in
                self?.structurize(nil)
            },
            PaletteCommand(title: "Simulate Traffic from Selection", shortcut: "⌘↩", systemImage: "play.circle") { [weak self] in
                self?.simulateTraffic(nil)
            },
            PaletteCommand(title: "Record Flow from Selection", shortcut: "⇧⌘↩", systemImage: "record.circle") { [weak self] in
                self?.recordFlow(nil)
            },
            PaletteCommand(title: "Show Flows Panel", shortcut: "⌘J", systemImage: "point.topleft.down.curvedto.point.bottomright.up") { [weak self] in
                self?.toggleFlowsPanel(nil)
            },
            PaletteCommand(title: "Assistant (Chat with Claude)", shortcut: "⇧⌘A", systemImage: "sparkles") { [weak self] in
                self?.toggleChatPanel(nil)
            },
            PaletteCommand(title: "Group Selection", shortcut: "⌘G", systemImage: "square.on.square.squareshape.controlhandles") { [weak self] in
                self?.canvasView.groupSelection(nil)
            },
            PaletteCommand(title: "Ungroup Selection", shortcut: "⇧⌘G", systemImage: "square.slash") { [weak self] in
                self?.canvasView.ungroupSelection(nil)
            },
            PaletteCommand(title: "Add Boundary around Selection", shortcut: "⌥⌘B", systemImage: "rectangle.dashed") { [weak self] in
                self?.canvasView.addBoundaryAroundSelection(nil)
            },
            PaletteCommand(title: "Inspector", shortcut: "⌥⌘I", systemImage: "slider.horizontal.3") { [weak self] in
                self?.toggleInspector(nil)
            },
            PaletteCommand(title: "Toggle Layers Panel", shortcut: "⌘L", systemImage: "square.3.layers.3d") { [weak self] in
                self?.toggleLayersPanel(nil)
            },
            PaletteCommand(title: "Toggle Library", shortcut: "⌘Y", systemImage: "books.vertical") { [weak self] in
                self?.toggleLibraryPanel(nil)
            },
            PaletteCommand(title: "Save Selection to Library", shortcut: "⌥⌘S", systemImage: "square.and.arrow.down") { [weak self] in
                self?.saveSelectionToLibrary(nil)
            },
            PaletteCommand(title: "Copy for LLM", shortcut: "⇧⌘C", systemImage: "text.bubble") { [weak self] in
                self?.copyForLLM(nil)
            },
            PaletteCommand(title: "Import Board from Clipboard", shortcut: "⇧⌘V", systemImage: "square.and.arrow.down.on.square") { [weak self] in
                self?.importBoardFromClipboard(nil)
            },
            PaletteCommand(title: "Export as PNG…", shortcut: nil, systemImage: "photo") { [weak self] in
                self?.exportAsPNG(nil)
            },
            PaletteCommand(title: "Export as SVG…", shortcut: nil, systemImage: "square.on.circle") { [weak self] in
                self?.exportAsSVG(nil)
            },
            PaletteCommand(title: "Zoom to Fit", shortcut: "⌘9", systemImage: "arrow.up.left.and.arrow.down.right") { [weak self] in
                self?.canvasView.zoomToFit(nil)
            },
            PaletteCommand(title: "Actual Size", shortcut: "⌘0", systemImage: "1.magnifyingglass") { [weak self] in
                self?.canvasView.zoomActualSize(nil)
            },
        ]
    }

    // MARK: Layers

    private func setActiveLayer(_ id: LayerID?) {
        layersModel.activeLayerID = id
        canvasView.activeLayerID = id
    }

    @objc func toggleLayersPanel(_ sender: Any?) {
        layersModel.isVisible.toggle()
        toolbarState.layersPanelVisible = layersModel.isVisible
    }

    private func installLayersPanel() {
        let actions = LayersPanelActions(
            setVisible: { [weak self] id, visible in
                self?.updateLayer(id) { $0.isVisible = visible }
            },
            setLocked: { [weak self] id, locked in
                self?.updateLayer(id) { $0.isLocked = locked }
            },
            rename: { [weak self] id, name in
                self?.updateLayer(id) { $0.name = name }
            },
            setTint: { [weak self] id, tint in
                self?.updateLayer(id) { $0.colorTint = tint }
            },
            addLayer: { [weak self] in
                guard let self else { return }
                let layer = Layer(name: "Layer \(self.document.board.layers.count + 1)")
                self.document.perform(
                    .insertLayer(layer, at: self.document.board.layers.count),
                    actionName: "Add Layer"
                )
                self.setActiveLayer(layer.id)
            },
            duplicate: { [weak self] id in
                guard let self,
                      let operations = self.document.board.duplicateLayerOperations(id) else { return }
                self.document.perform(.batch(operations), actionName: "Duplicate Layer")
            },
            delete: { [weak self] id in
                guard let self,
                      let operations = self.document.board.deleteLayerOperations(id) else {
                    NSSound.beep()
                    return
                }
                self.document.perform(.batch(operations), actionName: "Delete Layer")
                if self.layersModel.activeLayerID == id {
                    self.setActiveLayer(self.document.board.layers.first?.id)
                }
            },
            move: { [weak self] source, destination in
                guard let self, let sourceIndex = source.first,
                      self.document.board.layers.indices.contains(sourceIndex) else { return }
                let id = self.document.board.layers[sourceIndex].id
                // List's destination is in "after removal" terms for downward moves.
                let target = destination > sourceIndex ? destination - 1 : destination
                guard target != sourceIndex else { return }
                self.document.perform(.moveLayer(id, to: target), actionName: "Reorder Layers")
            },
            setActive: { [weak self] id in
                self?.setActiveLayer(id)
            },
            setFocus: { [weak self] enabled in
                self?.layersModel.focusEnabled = enabled
                self?.canvasView.focusActiveLayer = enabled
            },
            assignSelection: { [weak self] id in
                guard let self else { return }
                let operations = self.document.board.assignOperations(self.canvasView.selection, toLayer: id)
                guard !operations.isEmpty else {
                    NSSound.beep()
                    return
                }
                self.document.perform(.batch(operations), actionName: "Assign to Layer")
            }
        )

        let panel = LayersPanelContainer(document: document, model: layersModel, actions: actions)
        let host = NSHostingView(rootView: panel)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            host.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
        ])
    }

    private func updateLayer(_ id: LayerID, _ mutate: (inout Layer) -> Void) {
        guard var layer = document.board.layers.first(where: { $0.id == id }) else { return }
        mutate(&layer)
        document.perform(.replaceLayer(layer), actionName: "Edit Layer")
    }

    private func installToolbar() {
        let toolbar = CanvasToolbar(
            state: toolbarState,
            onSelectTool: { [weak self] in self?.toolbarAction { $0.activateSelectTool(nil) } },
            onDrawTool: { [weak self] in self?.toolbarAction { $0.activateDrawTool(nil) } },
            onAddBlock: { [weak self] in self?.toolbarAction { $0.addBlock(nil) } },
            onStructurize: { [weak self] in
                guard let self else { return }
                self.structurize(nil)
                self.view.window?.makeFirstResponder(self.canvasView)
            },
            onLayers: { [weak self] in
                guard let self else { return }
                self.toggleLayersPanel(nil)
                self.view.window?.makeFirstResponder(self.canvasView)
            },
            onLibrary: { [weak self] in
                guard let self else { return }
                self.toggleLibraryPanel(nil)
                self.view.window?.makeFirstResponder(self.canvasView)
            },
            onSimulate: { [weak self] in
                guard let self else { return }
                self.simulateTraffic(nil)
                self.view.window?.makeFirstResponder(self.canvasView)
            },
            onRecordFlow: { [weak self] in
                guard let self else { return }
                if self.canvasView.isRecordingFlow {
                    self.canvasView.cancelFlowRecording()
                } else {
                    self.recordFlow(nil)
                }
                self.view.window?.makeFirstResponder(self.canvasView)
            },
            onAddTypedBlock: { [weak self] entry in
                // No focus hand-back: addBlock opens the label editor.
                self?.canvasView.addBlock(kind: entry.kind, shape: entry.shape, orientation: entry.orientation)
            }
        )
        let host = NSHostingView(rootView: toolbar)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
        ])
    }

    private func toolbarAction(_ body: (CanvasView) -> Void) {
        body(canvasView)
        // Clicking a toolbar button must not steal keyboard focus from the canvas.
        view.window?.makeFirstResponder(canvasView)
    }

    // MARK: Sketch → structure

    private func strokeFinished(_ id: ElementID) {
        guard liveRecognitionEnabled,
              let element = document.board.elements[id],
              let conversion = SketchConversion.conversion(for: element, in: document.board)
        else { return }
        document.perform(
            document.board.expandingWithReattachments(conversion.operation),
            actionName: conversion.actionName
        )
        canvasView.select([conversion.producedID])
        nameProducedNodeIfPossible(conversion.producedID)
    }

    /// B3 (name-on-snap): when a sketch becomes a block, open its label
    /// editor immediately so it can be named without a second action.
    /// Connectors are skipped — they get the edge editor elsewhere.
    private func nameProducedNodeIfPossible(_ id: ElementID) {
        guard let produced = document.board.elements[id], produced.node != nil else { return }
        canvasView.beginLabelEdit(for: produced)
    }

    /// ⌘R: convert selected ink into blocks/connectors (one undo step).
    @objc func structurize(_ sender: Any?) {
        // With a selection: convert those sketches. Without one: convert every
        // freehand stroke on the board — the common "clean it all up" intent.
        var targets = canvasView.selection
        if SketchConversion.structurize(targets, in: document.board) == nil {
            targets = Set(document.board.elements.values.filter {
                if case .ink = $0.content { return true }
                return false
            }.map(\.id))
        }
        guard let conversion = SketchConversion.structurize(targets, in: document.board) else {
            // Nothing recognizable — explain instead of beeping.
            let alert = NSAlert()
            alert.messageText = "Nothing to structurize"
            alert.informativeText = """
            Structurize (⌘R) turns freehand sketches into clean blocks and connectors.

            Draw with the Draw tool (D) — a rough box, circle, diamond, or an arrow \
            between blocks — then press ⌘R. With nothing selected it converts every \
            sketch on the board; select strokes to convert just those.
            """
            alert.runModal()
            return
        }
        document.perform(
            document.board.expandingWithReattachments(conversion.operation),
            actionName: conversion.actionName
        )
        canvasView.select([conversion.producedID])
        nameProducedNodeIfPossible(conversion.producedID)
    }

    @objc func toggleLiveRecognition(_ sender: Any?) {
        liveRecognitionEnabled.toggle()
    }

    // MARK: Library

    private let libraryModel = LibraryPanelModel()
    private lazy var libraryStore = LibraryStore(
        rootURL: (try? LibraryStore.defaultRootURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("DesignerLibrary")
    )

    @objc func toggleLibraryPanel(_ sender: Any?) {
        libraryModel.isVisible.toggle()
        toolbarState.libraryPanelVisible = libraryModel.isVisible
        if libraryModel.isVisible { reloadLibrary() }
    }

    @objc func saveSelectionToLibrary(_ sender: Any?) {
        let ids = canvasView.selection
        guard !ids.isEmpty else { NSSound.beep(); return }
        saveToLibrary(ids: ids, suggestedName: "Pattern")
    }

    @objc func saveBoardToLibrary(_ sender: Any?) {
        let ids = Set(document.board.elements.keys)
        guard !ids.isEmpty else { NSSound.beep(); return }
        saveToLibrary(ids: ids, suggestedName: document.displayName ?? "Board")
    }

    private func saveToLibrary(ids: Set<ElementID>, suggestedName: String) {
        guard let name = promptForText(
            title: "Save to Library",
            message: "Name this reusable pattern.",
            defaultvalue: suggestedName
        ), !name.isEmpty else { return }

        let clip = document.board.makeClip(of: ids, title: name)
        let entry = LibraryEntry(name: name, tags: parseTags(from: name))
        let thumbnail = BoardSnapshot.pngThumbnail(of: clip)
        do {
            try libraryStore.save(clip, as: entry, thumbnailPNG: thumbnail)
            reloadLibrary()
            if !libraryModel.isVisible { toggleLibraryPanel(nil) }
        } catch {
            showError(error)
        }
    }

    /// No tag parsing from the name for now; tags are added via rename later.
    private func parseTags(from name: String) -> [String] { [] }

    /// Headless save→list→load→insert round-trip through the real clip/store/
    /// instantiate path, into a throwaway library folder. Returns nil on
    /// success or a failure message (used by --ui-test, which can't drive the
    /// modal save prompt). Leaves the board unchanged (undoes its insert).
    func runLibrarySelfTest() -> String? {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibSelfTest-\(UUID().uuidString)")
        let store = LibraryStore(rootURL: tempRoot)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let ids = Set(document.board.elements.keys)
        guard !ids.isEmpty else { return "no elements to save" }
        let clip = document.board.makeClip(of: ids, title: "SelfTest")
        do {
            let entry = try store.save(clip, as: LibraryEntry(name: "SelfTest", tags: ["t"]))
            guard try store.list().contains(where: { $0.id == entry.id }) else { return "entry not listed" }
            guard try store.search("selftest").contains(where: { $0.id == entry.id }) else { return "search miss" }
            let loaded = try store.loadBoard(entry.id)
            let before = document.board.elements.count
            let layer = activeLayerID() ?? document.board.layers.first!.id
            let (operations, newIDs) = document.board.instantiateOperations(
                from: loaded, offsetBy: 800, 800, onto: layer
            )
            document.perform(.batch(operations), actionName: "Insert SelfTest")
            guard document.board.elements.count == before + loaded.elements.count else {
                return "insert count wrong (\(document.board.elements.count) vs \(before + loaded.elements.count))"
            }
            for id in newIDs {
                guard let edge = document.board.elements[id]?.edge else { continue }
                if let from = edge.from.elementID, !newIDs.contains(from) { return "edge 'from' not remapped" }
                if let to = edge.to.elementID, !newIDs.contains(to) { return "edge 'to' not remapped" }
            }
            document.undoManager?.undo()
            guard document.board.elements.count == before else { return "undo did not restore" }
            return nil
        } catch {
            return "\(error)"
        }
    }

    private func installLibraryPanel() {
        let actions = LibraryPanelActions(
            insert: { [weak self] entry in self?.insert(entry) },
            promptRename: { [weak self] entry in self?.renameLibraryEntry(entry) },
            delete: { [weak self] entry in self?.deleteLibraryEntry(entry) },
            saveSelection: { [weak self] in self?.saveSelectionToLibrary(nil) }
        )
        let panel = LibraryPanelContainer(model: libraryModel, actions: actions)
        let host = NSHostingView(rootView: panel)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            // Below the layers panel's top anchor so both can be open.
            host.topAnchor.constraint(equalTo: view.topAnchor, constant: 320),
        ])
    }

    private func reloadLibrary() {
        let entries = (try? libraryStore.list()) ?? []
        libraryModel.entries = entries
        var thumbnails: [UUID: Data] = [:]
        for entry in entries {
            if let data = libraryStore.loadThumbnail(entry.id) {
                thumbnails[entry.id] = data
            }
        }
        libraryModel.thumbnails = thumbnails
    }

    private func insert(_ entry: LibraryEntry) {
        do {
            let clip = try libraryStore.loadBoard(entry.id)
            let layerID = activeLayerID() ?? document.board.layers.first?.id
            guard let layerID else { return }

            // Center the clip on the visible canvas center.
            let center = canvasView.visibleCenterWorld
            var dx = 0.0, dy = 0.0
            if let bounds = clip.contentBounds() {
                dx = center.x - bounds.midX
                dy = center.y - bounds.midY
            }
            let (operations, newIDs) = document.board.instantiateOperations(
                from: clip, offsetBy: dx, dy, onto: layerID
            )
            guard !operations.isEmpty else { return }
            document.perform(.batch(operations), actionName: "Insert “\(entry.name)”")
            canvasView.select(newIDs)
            view.window?.makeFirstResponder(canvasView)
        } catch {
            showError(error)
        }
    }

    private func activeLayerID() -> LayerID? {
        if let id = layersModel.activeLayerID,
           let layer = document.board.layers.first(where: { $0.id == id }),
           layer.isVisible, !layer.isLocked {
            return id
        }
        return document.board.layers.first { $0.isVisible && !$0.isLocked }?.id
    }

    private func renameLibraryEntry(_ entry: LibraryEntry) {
        guard let name = promptForText(
            title: "Rename Pattern",
            message: "Enter a new name (comma-separated tags optional after “#”).",
            defaultvalue: entry.name
        ), !name.isEmpty else { return }
        // Support "Name #tag1, tag2" to set tags inline.
        var updated = entry
        if let hash = name.firstIndex(of: "#") {
            updated.name = String(name[..<hash]).trimmingCharacters(in: .whitespaces)
            updated.tags = name[name.index(after: hash)...]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else {
            updated.name = name
        }
        do {
            try libraryStore.update(updated)
            reloadLibrary()
        } catch {
            showError(error)
        }
    }

    private func deleteLibraryEntry(_ entry: LibraryEntry) {
        do {
            try libraryStore.delete(entry.id)
            reloadLibrary()
        } catch {
            showError(error)
        }
    }

    /// Modal text prompt (NSAlert with an input field).
    private func promptForText(title: String, message: String, defaultvalue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultvalue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespaces)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    // MARK: LLM interchange (D16)

    /// Copies the board (or selection) as canonical, LLM-legible text.
    @objc func copyForLLM(_ sender: Any?) {
        let selection = canvasView.selection.isEmpty ? nil : canvasView.selection
        let text = LLMInterchange.export(document.board, selection: selection)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Imports board text from the clipboard into a NEW document (so it never
    /// clobbers the current board unexpectedly).
    @objc func importBoardFromClipboard(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            NSSound.beep(); return
        }
        do {
            let result = try LLMInterchange.parse(text)
            openImportedBoard(result.board)
            if !result.warnings.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Imported with \(result.warnings.count) note\(result.warnings.count == 1 ? "" : "s")"
                alert.informativeText = result.warnings.prefix(8).joined(separator: "\n")
                alert.runModal()
            }
        } catch {
            showError(error)
        }
    }

    private func openImportedBoard(_ board: Board) {
        let controller = NSDocumentController.shared
        guard let typeName = controller.defaultType,
              let document = try? controller.makeUntitledDocument(ofType: typeName) as? BoardDocument else {
            return
        }
        document.board = board
        controller.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
    }

    // MARK: Export

    @objc func exportAsPNG(_ sender: Any?) {
        runExportPanel(defaultName: exportBaseName(), extension: "png") { [weak self] url in
            guard let self else { return }
            let board = self.exportSource()
            guard let png = BoardSnapshot.pngThumbnail(
                of: board, pointSize: self.exportPixelSize(for: board)
            ) else {
                self.showError(ExportError.renderFailed); return
            }
            try png.write(to: url)
        }
    }

    @objc func exportAsSVG(_ sender: Any?) {
        runExportPanel(defaultName: exportBaseName(), extension: "svg") { [weak self] url in
            guard let self else { return }
            let selection = self.canvasView.selection.isEmpty ? nil : self.canvasView.selection
            let svg = SVGExporter.export(self.document.board, selection: selection)
            try svg.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private enum ExportError: Error, LocalizedError {
        case renderFailed
        var errorDescription: String? { "Couldn't render the board for export." }
    }

    private func exportSource() -> Board {
        let selection = canvasView.selection
        return selection.isEmpty ? document.board : document.board.makeClip(of: selection)
    }

    private func exportBaseName() -> String {
        let name = document.displayName ?? "Board"
        return canvasView.selection.isEmpty ? name : "\(name) selection"
    }

    private func exportPixelSize(for board: Board) -> CGSize {
        let bounds = board.contentBounds() ?? Rect(x: 0, y: 0, width: 800, height: 600)
        // 2× the content size, capped so huge boards don't blow up memory.
        let scale = 2.0
        return CGSize(
            width: min((bounds.width + 48) * scale, 6000),
            height: min((bounds.height + 48) * scale, 6000)
        )
    }

    private func runExportPanel(defaultName: String, extension ext: String, write: @escaping (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(defaultName).\(ext)"
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        let window = view.window
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try write(url) } catch { self?.showError(error) }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }

    /// Headless copy→import round-trip for --ui-test.
    func runLLMInterchangeSelfTest() -> String? {
        let text = LLMInterchange.export(document.board)
        do {
            let result = try LLMInterchange.parse(text)
            let originalNodes = document.board.elements.values.filter { $0.node != nil }.count
            let importedNodes = result.board.elements.values.filter { $0.node != nil }.count
            guard originalNodes == importedNodes else {
                return "node count changed on round-trip (\(originalNodes) → \(importedNodes))"
            }
            guard !result.board.elements.isEmpty else { return "imported board is empty" }
            // SVG must be well-formed.
            let svg = SVGExporter.export(document.board)
            guard XMLParser(data: Data(svg.utf8)).parse() else { return "SVG not well-formed" }
            return nil
        } catch {
            return "\(error)"
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(canvasView)
    }

    // MARK: CanvasViewDelegate

    func canvasView(_ view: CanvasView, perform operation: BoardOperation, actionName: String) {
        // Any newly placed block also snaps nearby dangling connector
        // endpoints onto itself, inside the same undo step.
        document.perform(
            document.board.expandingWithReattachments(operation),
            actionName: actionName
        )
    }

    func canvasViewDidChangeSelection(_ view: CanvasView) {
        refreshInspector()
    }
}

extension CanvasViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(structurize(_:)):
            return canvasView.selection.contains { id in
                if case .ink = document.board.elements[id]?.content { return true }
                return false
            }
        case #selector(toggleLiveRecognition(_:)):
            menuItem.state = liveRecognitionEnabled ? .on : .off
            return true
        case #selector(saveSelectionToLibrary(_:)):
            return !canvasView.selection.isEmpty
        case #selector(simulateTraffic(_:)):
            if canvasView.isSimulating { return true } // ⌘↩ again stops
            return canvasView.selection.count == 1
                && canvasView.selection.first.map { document.board.elements[$0]?.node != nil } == true
        case #selector(saveBoardToLibrary(_:)),
             #selector(exportAsPNG(_:)), #selector(exportAsSVG(_:)),
             #selector(copyForLLM(_:)):
            return !document.board.elements.isEmpty
        case #selector(toggleLibraryPanel(_:)):
            menuItem.state = libraryModel.isVisible ? .on : .off
            return true
        default:
            return true
        }
    }
}
