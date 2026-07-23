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
/// - The CURSOR is the node the walk currently stands on (the last clicked
///   one). When several reached nodes could deliver to the clicked block,
///   the hop departing from the cursor wins: click B, A, C records B→A
///   then A→C — never a surprise second departure from B. Clicking an
///   already-reached node moves the cursor there (that's how you fan out).
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
    /// Where the walk stands right now: the last recorded arrival (or a
    /// reached node the user clicked to fan out from). Hops departing from
    /// here win over other reached origins when a click is ambiguous.
    public private(set) var cursor: ElementID
    /// Recorded connectors in click order; steps are derived from this, so
    /// undo is simply dropping the last entry.
    private var journal: [Candidate] = []

    public init(source: ElementID) {
        self.source = source
        self.cursor = source
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
        // Which (edge, direction) pairs have already fired — a double-sided
        // connector is tracked per-direction so it can be walked once each way.
        let recordedDirected = Set(journal.map { DirectedKey(edge: $0.edge, from: $0.from, to: $0.to) })
        func directedFree(_ edge: ElementID, _ from: ElementID, _ to: ElementID) -> Bool {
            !recordedDirected.contains(DirectedKey(edge: edge, from: from, to: to))
        }
        var result: [Candidate] = []
        for element in board.elementsInZOrder {
            guard let edge = element.edge,
                  let a = edge.from.elementID, let b = edge.to.elementID,
                  board.elements[a]?.node != nil, board.elements[b]?.node != nil else { continue }
            switch edge.semantic.direction {
            case .forward:
                if !recorded.contains(element.id), origins.contains(a) {
                    result.append(.init(edge: element.id, from: a, to: b))
                }
            case .backward:
                if !recorded.contains(element.id), origins.contains(b) {
                    result.append(.init(edge: element.id, from: b, to: a))
                }
            case .both:
                // A double-sided connector can be walked once in EACH direction,
                // so recording a back-and-forth (A→B→A over the same connector)
                // works (F12) — but never the same direction twice, which would
                // loop forever.
                if origins.contains(a), directedFree(element.id, a, b) {
                    result.append(.init(edge: element.id, from: a, to: b))
                }
                if origins.contains(b), directedFree(element.id, b, a) {
                    result.append(.init(edge: element.id, from: b, to: a))
                }
            default:
                break // .none and unknown carry no flow
            }
        }
        return result
    }

    private struct DirectedKey: Hashable {
        let edge: ElementID
        let from: ElementID
        let to: ElementID
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

    /// Candidates to a target, preferring hops that depart from the cursor:
    /// the walk continues from where the user last clicked. Only when the
    /// cursor can't reach the target do other reached origins qualify.
    public func preferredCandidates(to target: ElementID, in board: Board) -> [Candidate] {
        let all = candidates(to: target, in: board)
        let fromCursor = all.filter { $0.from == cursor }
        return fromCursor.isEmpty ? all : fromCursor
    }

    /// Puts the walk back on an already-reached node so the next hop departs
    /// from there (fan-out). Returns false for unreached nodes.
    @discardableResult
    public mutating func moveCursor(to node: ElementID) -> Bool {
        guard reachedNodes.contains(node) else { return false }
        cursor = node
        return true
    }

    /// Records a candidate. Returns false if it isn't currently recordable.
    @discardableResult
    public mutating func record(_ candidate: Candidate, in board: Board) -> Bool {
        guard candidates(in: board).contains(candidate) else { return false }
        journal.append(candidate)
        cursor = candidate.to
        return true
    }

    /// Removes the most recently recorded connector.
    public mutating func undoLast() {
        _ = journal.popLast()
        cursor = journal.last?.to ?? source
    }

    /// Finalizes the recording into a Flow (caller supplies name and color).
    public func finish(name: String, colorIndex: Int) -> Flow {
        Flow(name: name, source: source, steps: steps, colorIndex: colorIndex)
    }
}
