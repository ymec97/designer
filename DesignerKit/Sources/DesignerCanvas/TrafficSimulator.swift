import Foundation
import DesignerModel

/// Drives the timeline of a running traffic simulation: which nodes are lit,
/// which edges are mid-transit, and how far along each packet is. Pure timing
/// state (no rendering, no display link) so it's testable and the view just
/// reads it each frame.
struct TrafficSimulator {
    /// Seconds a packet takes to cross one edge, and the pause on a node
    /// before it re-emits. Scaled by `speed`.
    static let edgeDuration: Double = 0.55
    static let nodeDwell: Double = 0.12

    let source: ElementID
    private let steps: [TrafficSimulation.Step]
    /// Absolute start time of each step (edge transit), in simulation seconds.
    private let stepStart: [Double]
    let totalDuration: Double

    /// 1 = normal; higher is faster.
    var speed: Double = 1

    /// Flood mode: BFS everything reachable from the source.
    init(source: ElementID, board: Board) {
        self.init(source: source, steps: TrafficSimulation.steps(from: source, in: board))
    }

    /// Scripted mode: play exactly these steps (a recorded flow).
    init(source: ElementID, steps: [TrafficSimulation.Step]) {
        self.source = source
        self.steps = steps
        var starts: [Double] = []
        var t = Self.nodeDwell // source pulses briefly before emitting
        for _ in steps {
            starts.append(t)
            t += Self.edgeDuration + Self.nodeDwell
        }
        self.stepStart = starts
        self.totalDuration = t
    }

    var isEmpty: Bool { steps.isEmpty }

    /// A snapshot of the simulation at simulation-time `t` (already speed-scaled
    /// by the caller, i.e. real elapsed × speed).
    struct Frame {
        /// Nodes fully lit (source + reached), keyed to their activation time
        /// so the view can pulse newly-arrived ones.
        var litNodes: Set<ElementID>
        /// Edges currently transiting, with packet progress 0…1.
        var activeEdges: [(id: ElementID, progress: Double)]
        /// Edges already delivered (drawn lit but without a moving packet).
        var doneEdges: Set<ElementID>
        var finished: Bool
    }

    func frame(at t: Double) -> Frame {
        var lit: Set<ElementID> = [source]
        var active: [(ElementID, Double)] = []
        var done: Set<ElementID> = []

        for (index, step) in steps.enumerated() {
            let start = stepStart[index]
            let end = start + Self.edgeDuration
            if t >= end {
                // Delivered: nodes lit, edges done.
                for node in step.nodes { lit.insert(node) }
                for edge in step.edges { done.insert(edge) }
            } else if t >= start {
                let progress = (t - start) / Self.edgeDuration
                for edge in step.edges { active.append((edge, progress)) }
            }
            // steps before this one whose nodes are lit gate later steps
            // implicitly via the timeline (later starts are larger).
        }

        return Frame(
            litNodes: lit,
            activeEdges: active.map { (id: $0.0, progress: $0.1) },
            doneEdges: done,
            finished: t >= totalDuration
        )
    }
}
