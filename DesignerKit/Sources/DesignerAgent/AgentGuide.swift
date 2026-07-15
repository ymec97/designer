import Foundation

/// The canonical "how to work with Designer" text handed to agents. Injected
/// three ways so it's hard to miss: the MCP `initialize` response's
/// `instructions` field, the `get_guide` tool, and the in-app chat's system
/// prompt. Keep it tight — every line costs context in the agent's window.
public enum AgentGuide {
    public static let text = """
    # Working with Designer

    Designer is a macOS canvas for software-architecture diagrams: blocks \
    (components), connectors (data flows between them), notes, and freehand ink. \
    You see and edit the open board through these tools; the user reviews every \
    change you propose.

    ## Editing the board (the only write path)
    1. Call get_board — the full board as JSON with stable, name-based ids.
    2. Edit that JSON. Send the COMPLETE board back via propose_board: anything \
    you omit is DELETED. Keep existing nodes' `at`/`size` untouched unless asked \
    to rearrange; omit `at`/`size` only for NEW nodes (they auto-arrange \
    left-to-right in data-flow order).
    3. The user sees your proposal as ghosts on the canvas plus a diff, and \
    Accepts or Rejects. Nothing applies until they accept. Call get_board \
    afterwards to see what they decided before proposing again.

    ## Authoring conventions (make boards read well)
    - EVERY node needs a human-readable `name` (e.g. "orders-svc", "Postgres") \
    and a `kind`: service | database | queue | cache | gateway | client | \
    external | generic. Kind drives the block's tint and badge.
    - Choose `shape` deliberately: "ellipse" for databases/data stores, \
    "diamond" for decision/routing points, "triangle" for alerts/warnings \
    (set `orientation` up|down|left|right), rectangle (default) for services \
    and everything else.
    - EVERY connector should carry a `label` (what happens, e.g. "create order") \
    and a `protocol` (HTTPS, gRPC, SQL, Kafka…). Use `data` for the payload \
    ("order JSON"), `condition` for when it fires ("only when gRPC in" — shown \
    during traffic playback). `direction`: forward (default, from→to), \
    backward, both, none.
    - Two nodes may have several parallel connectors (e.g. gRPC AND HTTP); \
    Designer spreads them along the node sides visually. Give each a distinct \
    label/protocol. (By hand, connecting an already-connected pair again \
    simply adds a parallel connector.)

    ## Layers (progressive disclosure — USE THEM on non-trivial boards)
    Layers are views over the SAME elements (multi-membership), toggled \
    visible/hidden — that is their power: a board that starts as a simple \
    overview and reveals depth layer by layer, perfect for walking someone \
    through a system.
    - Declare `layers: [{name, tint?, hidden?}]` at the top level; the FIRST \
    layer is the base. Give each element `layers: ["…"]` (names; omitted = \
    base layer only). An element may be on several layers.
    - Recommended structure: a base "Overview" layer with the core components \
    and happy-path connections everyone must understand; then one layer per \
    added concern or depth level — e.g. "Caching", "Security", "Failure \
    modes", "Infra detail". Keep the overview readable on its own; put \
    detail elements (and their connectors) on their concern layer.
    - Connectors should live on the layers where BOTH their meaning and \
    endpoints make sense (a cache-fill connector belongs on "Caching").
    - Tint layers (hex) so focus mode color-codes concerns.

    ## Flows (recorded journeys — add them when you explain traffic)
    A flow replays one request's exact path as an animated packet — including \
    WHICH of two parallel connectors it takes.
    - `flows: [{name, source, steps}]`; `source` is the starting node id; \
    `steps` is an ordered array; each step is an array of hops that fire \
    together (one hop normally, several = fan-out).
    - A hop is {from, to, via?} — node ids plus `via` matching the \
    connector's label or protocol, REQUIRED when parallels exist.
    - Example: [[{from:"client",to:"gw"}], [{from:"gw",to:"orders",\
    via:"gRPC"}], [{from:"orders",to:"db"},{from:"orders",to:"billing"}]]
    - Name flows after the scenario ("Checkout (gRPC)", "Login journey").

    ## App features you can explain to the user (you cannot drive these; they're in-app)
    - Draw tool (D): freehand sketches snap into blocks/connectors; ⌘R \
    structurizes a selection.
    - Layers (⌘L): the same board viewed through concerns (infra, security…); \
    elements can live on several layers; focus mode dims the rest.
    - Flows (⌘J): recorded traffic journeys. The user selects a source block, \
    clicks the blocks a request visits in order (picking the connector when \
    parallel ones exist), then plays it back as an animated packet — this \
    expresses correlation like "gRPC in means gRPC out". Flows can be isolated.
    - Simulate (⌘↩): flood playback of everything reachable from the selected \
    block, wave by wave.
    - Versions (⇧⌘H): named board snapshots. One is captured automatically \
    right before each of your proposals is accepted, so users can always \
    return to the pre-proposal board.
    - Library (⌘Y): save/reuse diagram patterns. Export: PNG/SVG. Everything \
    is undoable (⌘Z) — including accepting your proposals.

    When the user asks you to lay out a whole system, prefer one propose_board \
    with the complete design over many small proposals.
    """
}
