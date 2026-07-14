import Foundation

/// The walk-the-path state machine behind flow recording (F5). Pure graph
/// logic — the canvas layer supplies clicks and draws highlights; this decides
/// which connectors are recordable next and how clicks become steps.
///
/// Rules:
/// - A connector is a candidate when it departs from any node the flow has
///   already reached (honoring edge direction; `both` edges are traversable
///   either way; `none` edges never carry flow). Any recipient may emit later
///   — after a fan-out to A and B, you can record A's hop and then B's.
/// - Each connector fires at most once per flow.
/// - Recording a connector appends a step delivering to its far endpoint;
///   consecutive recordings departing from the *same node* merge into one
///   step (they fire together — fan-out).
public struct FlowRecorder {
    /// One recordable connector: the edge and the direction it would be
    /// traversed (from → to in traversal order, not storage order).
    public struct Candidate: Equatable, Sendable {
        public let edge: ElementID
        public let from: ElementID
        public let to: ElementID

        public init(edge: ElementID, from: ElementID, to: ElementID) {
            self.edge = edge
            self.from = from
            self.to = to
        }
    }

    public private(set) var source: ElementID
    /// Recorded connectors in click order; steps are derived from this, so
    /// undo is simply dropping the last entry.
    private var journal: [Candidate] = []

    public init(source: ElementID) {
        self.source = source
    }

    /// Steps derived from the journal: consecutive same-departure recordings
    /// collapse into one simultaneous step.
    public var steps: [Flow.Step] {
        var steps: [Flow.Step] = []
        var lastFrom: ElementID?
        for entry in journal {
            if entry.from == lastFrom, !steps.isEmpty {
                steps[steps.count - 1].edges.append(entry.edge)
                if !steps[steps.count - 1].nodes.contains(entry.to) {
                    steps[steps.count - 1].nodes.append(entry.to)
                }
            } else {
                steps.append(Flow.Step(edges: [entry.edge], nodes: [entry.to]))
                lastFrom = entry.from
            }
        }
        return steps
    }

    /// Every node the flow has reached so far (candidates depart from here).
    public var reachedNodes: Set<ElementID> {
        var reached: Set<ElementID> = [source]
        for entry in journal { reached.insert(entry.to) }
        return reached
    }

    public var isEmpty: Bool { journal.isEmpty }
    public var recordedEdges: Set<ElementID> { Set(journal.map(\.edge)) }

    /// Connectors traffic could take next, in z-order.
    public func candidates(in board: Board) -> [Candidate] {
        let origins = reachedNodes
        let recorded = recordedEdges
        var result: [Candidate] = []
        for element in board.elementsInZOrder {
            guard let edge = element.edge, !recorded.contains(element.id),
                  let a = edge.from.elementID, let b = edge.to.elementID,
                  board.elements[a]?.node != nil, board.elements[b]?.node != nil else { continue }
            switch edge.semantic.direction {
            case .forward:
                if origins.contains(a) { result.append(.init(edge: element.id, from: a, to: b)) }
            case .backward:
                if origins.contains(b) { result.append(.init(edge: element.id, from: b, to: a)) }
            case .both:
                if origins.contains(a) { result.append(.init(edge: element.id, from: a, to: b)) }
                else if origins.contains(b) { result.append(.init(edge: element.id, from: b, to: a)) }
            default:
                break // .none and unknown carry no flow
            }
        }
        return result
    }

    /// The blocks that can be clicked next: targets of the current
    /// candidates. (The primary recording gesture is choosing the next NODE;
    /// connectors only need choosing when several lead to the same node.)
    public func candidateTargets(in board: Board) -> Set<ElementID> {
        Set(candidates(in: board).map(\.to))
    }

    /// Candidates that deliver to a specific block — one means record it
    /// directly, several (parallel connectors) means the user picks.
    public func candidates(to target: ElementID, in board: Board) -> [Candidate] {
        candidates(in: board).filter { $0.to == target }
    }

    /// Records a candidate. Returns false if it isn't currently recordable.
    @discardableResult
    public mutating func record(_ candidate: Candidate, in board: Board) -> Bool {
        guard candidates(in: board).contains(candidate) else { return false }
        journal.append(candidate)
        return true
    }

    /// Removes the most recently recorded connector.
    public mutating func undoLast() {
        _ = journal.popLast()
    }

    /// Finalizes the recording into a Flow (caller supplies name and color).
    public func finish(name: String, colorIndex: Int) -> Flow {
        Flow(name: name, source: source, steps: steps, colorIndex: colorIndex)
    }
}
