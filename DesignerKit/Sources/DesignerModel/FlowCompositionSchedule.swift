import Foundation

/// Flattens a `FlowComposition` tree into a set of timed playback tracks — one
/// per referenced flow — that a player animates against a single clock. Pure
/// and duration-parametric (the caller passes the simulator's `edgeDuration` /
/// `nodeDwell`), so it lives in the model and is fully testable without the
/// canvas.
///
/// - **serial** group: children play back-to-back (child k starts after the
///   sum of the durations of children 0..<k).
/// - **parallel** group: children all start together; the group lasts as long
///   as its longest child (shorter children simply finish early).
public struct FlowCompositionSchedule: Equatable, Sendable {
    public struct Track: Equatable, Sendable {
        public var flowID: FlowID
        public var colorIndex: Int
        public var source: ElementID
        public var steps: [TrafficSimulation.Step]
        /// Seconds from the composition's t=0 that this flow begins.
        public var start: Double
        /// Seconds this flow's own animation lasts.
        public var duration: Double
    }

    public var tracks: [Track]
    /// The whole composition's length (max track end).
    public var totalDuration: Double
    /// Flows referenced but not playable (missing, source deleted, or no live
    /// steps) — surfaced so the UI can warn.
    public var skippedFlowIDs: [FlowID]

    public static func compile(
        _ composition: FlowComposition,
        in board: Board,
        edgeDuration: Double,
        nodeDwell: Double
    ) -> FlowCompositionSchedule {
        let byID = Dictionary(board.flows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var tracks: [Track] = []
        var skipped: [FlowID] = []

        // Returns the duration consumed starting at `t0`.
        func emit(_ children: [FlowComposition.Child], mode: FlowComposition.Mode, at t0: Double) -> Double {
            switch mode {
            case .serial:
                var cursor = t0
                for child in children {
                    cursor += emit(child, at: cursor)
                }
                return cursor - t0
            case .parallel:
                var longest = 0.0
                for child in children {
                    longest = max(longest, emit(child, at: t0))
                }
                return longest
            }
        }

        func emit(_ child: FlowComposition.Child, at t0: Double) -> Double {
            switch child {
            case .flow(let id):
                guard let flow = byID[id] else { skipped.append(id); return 0 }
                let steps = flow.liveSteps(in: board)
                guard !steps.isEmpty, board.elements[flow.source]?.node != nil else {
                    skipped.append(id); return 0
                }
                let simSteps = steps.map { TrafficSimulation.Step(edges: $0.edges, nodes: $0.nodes) }
                // Mirrors TrafficSimulator's scripted timeline: a source pulse,
                // then one (edge + dwell) window per step.
                let duration = nodeDwell + Double(simSteps.count) * (edgeDuration + nodeDwell)
                tracks.append(Track(
                    flowID: id, colorIndex: flow.colorIndex, source: flow.source,
                    steps: simSteps, start: t0, duration: duration
                ))
                return duration
            case .group(let mode, let children):
                return emit(children, mode: mode, at: t0)
            }
        }

        let total = emit(composition.children, mode: composition.mode, at: 0)
        return FlowCompositionSchedule(tracks: tracks, totalDuration: total, skippedFlowIDs: skipped)
    }
}
