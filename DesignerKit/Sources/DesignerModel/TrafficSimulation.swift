import Foundation

/// Data-flow simulation (F2): from a chosen source node, compute how traffic
/// propagates through the system as an ordered series of waves — the edges
/// traversed at each step and the nodes they reach. Pure and directed, so the
/// canvas can animate it and tests can pin it down.
public enum TrafficSimulation {
    /// One propagation step: edges lighting up this tick and the nodes they
    /// deliver to.
    public struct Step: Equatable, Sendable {
        public var edges: [ElementID]
        public var nodes: [ElementID]
        public init(edges: [ElementID], nodes: [ElementID]) {
            self.edges = edges
            self.nodes = nodes
        }
    }

    /// Directed BFS from `source`, following each edge only in its allowed
    /// direction; cycles terminate via a visited-set; dangling edges (a free
    /// endpoint) carry no flow. The source's initial pulse is implicit (step 0
    /// is the first wave of edges leaving it).
    public static func steps(from source: ElementID, in board: Board) -> [Step] {
        guard board.elements[source]?.node != nil else { return [] }

        // Adjacency: node → [(edge, targetNode)] it can send traffic along.
        var outgoing: [ElementID: [(edge: ElementID, target: ElementID)]] = [:]
        for element in board.elements.values {
            guard let edge = element.edge else { continue }
            guard let a = edge.from.elementID, let b = edge.to.elementID else { continue }
            switch edge.semantic.direction {
            case .forward:
                outgoing[a, default: []].append((element.id, b))
            case .backward:
                outgoing[b, default: []].append((element.id, a))
            case .both:
                outgoing[a, default: []].append((element.id, b))
                outgoing[b, default: []].append((element.id, a))
            default:
                break // .none and unknown: no flow
            }
        }

        var visited: Set<ElementID> = [source]
        var frontier: [ElementID] = [source]
        var steps: [Step] = []

        while !frontier.isEmpty {
            var stepEdges: [ElementID] = []
            var stepNodes: [ElementID] = []
            var seenThisStep: Set<ElementID> = []

            for node in frontier {
                for link in outgoing[node] ?? [] {
                    guard board.elements[link.target]?.node != nil else { continue }
                    guard !visited.contains(link.target) else { continue }
                    stepEdges.append(link.edge)
                    if seenThisStep.insert(link.target).inserted {
                        stepNodes.append(link.target)
                    }
                }
            }

            guard !stepNodes.isEmpty else { break }
            for node in stepNodes { visited.insert(node) }
            steps.append(Step(edges: stepEdges, nodes: stepNodes))
            frontier = stepNodes
        }

        return steps
    }

    /// Every node and edge the flow reaches from `source` (for a reachability
    /// summary / dimming the untouched rest).
    public static func reached(from source: ElementID, in board: Board) -> (nodes: Set<ElementID>, edges: Set<ElementID>) {
        var nodes: Set<ElementID> = [source]
        var edges: Set<ElementID> = []
        for step in steps(from: source, in: board) {
            nodes.formUnion(step.nodes)
            edges.formUnion(step.edges)
        }
        return (nodes, edges)
    }
}
