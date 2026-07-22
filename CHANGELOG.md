# Changelog

## v0.8.0 — 2026-07-22

Shapes + a universal Style panel, two agent-review fixes, two bug fixes,
and the two agent-proposal fixes that landed since v0.7.0.

Shapes & styling
- NEW: Shapes tool (S) + a toolbar picker (rectangle, square, ellipse,
  circle, diamond, triangle) — the same node shapes sketch-recognition
  produces. Drag on the canvas to size; ⇧ / the square·circle entries
  lock aspect. New canvases' shapes default to no background, for
  grouping outlines.
- NEW: a context-sensitive Style panel on the left — Pencil mode (Draw
  tool: ink color/width/opacity), Shape mode (the next drawn shape),
  and Style mode (restyle the selection). Fill palette + "None"
  (transparent background), stroke palette, S/M/L width, opacity slider
  with quick 100%/30%, and Send to Back / Bring to Front. The Inspector
  gains the same Style section.
- Style model gains element `opacity` and a `fill: "none"` sentinel;
  no-fill shapes skip fill, shadow, and the kind-dot; whole-element
  opacity fades fill+stroke+label together.

Agent review fidelity
- The proposal review ghost now renders MODIFIED elements in place
  (recolor, relabel, restyle, kind/shape change) with an amber "changed"
  ring + badge — previously an in-place edit was invisible until you
  accepted it.
- Agents can now set a block's color directly: `fill`, `stroke`, and
  `opacity` are in the agent JSON format (both directions). "Change the
  color" recolors the block instead of hijacking `kind` (which also drew
  the kind-dot). Matched blocks still inherit the current style for
  fields the agent leaves unset.

Fixes
- FIX: connectors into a wide, short node (e.g. "Postgres") no longer
  arrive on the wrong side with the arrowhead poking into the top edge —
  a detour can't re-anchor an endpoint to a side that faces away from
  the connector's source.
- FIX: the right-side panels (Layers, Assistant) stopped opening after a
  long session of zooming and creating shapes — the auto-opened label
  editor, sized from the zoomed rect, ballooned over the toolbar and ate
  the clicks. The editor is clamped and kept clear of the toolbar; the
  right panels use one consistent show/hide mechanism; Assistant
  restores focus like the other tools.
- (from v0.7.1) A position-only proposal now reports "N blocks
  repositioned" instead of "identical — nothing to review".
- (from v0.7.2) Dangling connectors survive an accepted agent proposal
  instead of being silently dropped.

Tests
- New real-mouse UI-test coverage: dragging a shape moves it, a drag
  snaps into edge alignment, and dragging shapes together overlaps.

## v0.7.0 — 2026-07-20

Agent proposals now REUSE the existing graph instead of rebuilding it
somewhere far away.

- propose_board parses anchored to the current board: proposed blocks
  matching an existing block (by wire id or name) that omit `at`/`size`
  inherit the block's CURRENT position, so the review ghost reads as an
  overlay on the diagram you already know — green new blocks/arrows, red
  deletions, unchanged blocks exactly where they were. Only genuinely
  new blocks are auto-placed, and they land beside the blocks they
  connect to rather than at the layout origin.
- An explicit `at` from the agent still wins (that's a deliberate move);
  plain imports (paste/LLM text) still lay out from scratch.
- Agent guide teaches the contract: keep ids/names exactly as get_board
  returned them — renaming a block breaks the match and reviews as
  delete + add.

## v0.6.1 — 2026-07-20

- FIX: the database cylinder drew a dark hole over the top of its label
  (the lid rim was part of the FILL path, and its winding punched through
  the drum — visible on the imported RDS Postgres block). The rim is
  stroke-only now, and cylinder labels center in the drum below the lid.

## v0.6.0 — 2026-07-17

- NEW: multi-joint connectors. A connector can carry any number of bend
  joints, each with its own grip: grab a segment of a selected connector
  to grow a new joint there, drag any joint to move just that joint, and
  drop a joint back onto the line between its neighbors to remove it
  (dropping the last one straightens the connector, as before). Imported
  draw.io routes — which arrive with several waypoints — are now fully
  editable joint by joint.

## v0.5.2 — 2026-07-17

- NEW: connector endpoints are draggable. A lone selected connector shows
  grips at both ends (plus the midpoint bend dot); drag a grip onto a
  block to reattach the connector there, drop it on empty canvas to
  detach it. This is also how you re-home an imported orange (dangling)
  connector. While a connector is selected its grips own the spot they
  sit on — click empty canvas first if you want to drag a NEW connection
  from that exact border point.
- Import: unbound endpoints now snap to the NEAREST block within 10pt
  (was: only points inside a slightly expanded frame), so more draw.io
  edges arrive connected.
- Import: a draw.io text cell with connectors attached now imports as a
  block (keeping its colors) instead of a note — its connectors stay
  attached instead of dangling orange.

## v0.5.1 — 2026-07-16

- FIX: flow recording now follows your clicks. With B→C, B→A, A→C,
  clicking B, A, C records B→A then A→C — the walk continues from the
  block you last clicked (the "cursor", shown with the strongest glow)
  instead of firing a parallel second departure from B. Clicking an
  already-visited block moves the cursor back there, which is how you
  record an intentional fan-out; undo moves the cursor back too.
- FIX: draw.io edges that visually end ON a block but aren't bound to it
  in the file (draw.io stores just a point on the block's border) now
  import attached to that block instead of dangling — this was the
  disconnected proxy-gateway ↔ agent edges after import.

## v0.5.0 — 2026-07-16

draw.io/Excalidraw import now preserves the original diagram EXACTLY —
positions, routes, colors — instead of producing a scrambled board.

- draw.io import fidelity: authored waypoint routes become connector
  waypoints (orthogonal polylines), entry/exit connection points pin the
  connector to the same node side, edges with a floating end import as
  dangling connectors instead of being dropped, fill/stroke colors are
  kept, and cells inside groups get correct absolute positions (groups
  become boundaries).
- New node shapes: cylinder and cloud (draw.io cylinder3/cloud map to
  them; they round-trip on export).
- Images: draw.io `image=` data URIs and Excalidraw image files render
  inside the block (PNG/JPEG/SVG, cached) and survive export both ways.
- AWS/stencil icons (mxgraph.aws4.*) keep their fill and map to a node
  kind (S3 → database, MQ → queue, …); draw.io-library images that are
  not embedded in the file are reported in the import notes.
- Node labels wrap onto up to 3 lines when the block is too narrow
  (imported diagrams keep their small frames); text on custom fills
  picks black/white by luminance so it stays readable.
- Excalidraw: arrow mid-points import/export as waypoints, shape
  background/stroke colors round-trip.

## v0.4.0 — 2026-07-16

Feedback round from the work Mac: input polish, flows ergonomics, and
agent layer-visibility control.

- Mouse scroll wheel now zooms (trackpad two-finger scroll still pans;
  ⌘-scroll zooms on both).
- NEW: `set_layer_visibility` MCP tool — agent proposals now ALWAYS arrive
  with their layers visible; staged walkthrough reveals are an explicit
  follow-up call instead of boards that open half-invisible.
- FIX: flow recording no longer lets you click blocks hidden by an
  invisible layer (it looked like recording was "generating new nodes").
- FIX: undoing a shape snap no longer leaves an orphaned label editor
  floating over the canvas.
- Flows panel: per-flow playback speed badge (1x → 1.5x → 2x → ½x), wider
  panel, and 1x is meaningfully slower than before so flows are readable.
  Flow and layer names wrap instead of truncating.
- Toolbar: Flows button (⌘J); Add Block / Structurize / Library buttons
  removed (Library lives in the command palette; drawing is freehand-first
  and auto-snaps, so ⌘R/⌘B are gone). Typed-block palette removed.
- New canvases default to the hand-drawn (Excalidraw-like) render style.
- Command palette: synonym keywords (e.g. "show layers" finds Toggle
  Layers Panel) and missing commands added (zoom, imports, agent access,
  auto-convert sketches).
- FIX: layer tint dots on ellipse blocks are anchored inside the ellipse
  instead of floating at the bounding-box corner.
- Agent guide: "nodes are entities, connectors are actions" rule — verbs
  become connector labels, prose moves to props/notes, never block names.

## v0.3.1 — 2026-07-15

- FIX: oversized block names rendered centered on their FULL width, spilling
  left over neighboring blocks — the visible (truncated) width is centered
  now.
- FIX: avoidance detours re-anchor connector endpoints toward the detour
  they arrive from (no more hooked arrivals on the wrong side), and the
  smoothed route is verified against blockers — it flips sides or falls
  back to a straight line rather than clipping a third block's corner.

## v0.3.0 — 2026-07-15

Agent boards now read like a human drew them (analysis of two real bad
outputs drove this release).

- Narrative auto-layout replaces the depth grid: cycle-safe columns (cycles
  in real systems made the old longest-path depths explode into 27,000pt
  towers), entry points on the left, deep pipelines compressed monotonically
  into ≤8 columns, blocks sharing a specialty layer laid out adjacent,
  `kind: external` blocks in a bottom row, blocks sized to their names, and
  tall columns spilling sideways. Direction is selectable via the new
  top-level `layout` wire field: left-right (default) | right-left |
  top-down (persisted on the board).
- Connector captions are now collision-managed as a set: each placed pill
  repels the next, candidates slide along the route AND nudge perpendicular
  (dense boards), runaway label/condition text truncates. Canvas, PNG, SVG.
- propose_board reports layout metrics to the agent — extent, average
  connector length, tightest block gap — with actionable warnings, so
  external agents self-correct instead of shipping sprawl.
- The agent guide now teaches composition: entry points left, related
  blocks together, externals at the edge, short names, ~3–4 screens max.

## v0.2.0 — 2026-07-15

Feedback round from the first work-machine deployment, plus interchange.

- FIX: an agent proposal onto a fresh empty canvas rendered nothing — the
  empty-board draw path skipped the ghost overlay. Ghosts (and hints) now
  render on empty boards, and accepting a proposal frames the new content.
- FIX: agent auto-layout marched deep chains far right (an onboarding map
  landed at x≈8,300, fitting at 13% zoom). Layouts now wrap after 8 columns
  into bands, staying ~2,000pt wide.
- Space-bar panning: hold ⎵ and drag to pan with any pointing device — no
  trackpad needed.
- FIX: connector labels no longer sit on top of blocks — caption pills probe
  the board and slide along their route to the nearest clear spot (canvas,
  PNG, and SVG export).
- FIX: long connectors (the agent's speciality) now weave past EVERY block
  in their way — avoidance places one waypoint per blocker cluster instead
  of attempting a single giant bow and giving up. Ghost previews route with
  the same avoidance, so what you review is what you get.
- ⌘S on a new untitled board now prompts for a name and location instead of
  silently keeping "Untitled" (the draft file is cleaned up; autosave
  unchanged).
- Everything since v0.1.0 shipped: agent layers + flows, clearer proposal
  ghosts, stacked side panels, draw.io + Excalidraw interchange, toolbar
  assistant/palette buttons, parallel-by-default connections.

Versioning: [SemVer](https://semver.org). `VERSION` at the repo root is the
source of truth; builds stamp it into the bundle together with the commit
count (build number) and date+sha (`DesignerBuildInfo`). Release artifacts
are named `Designer-v<version>-<date>.zip` (`scripts/package-app.sh`).

## v0.1.0 — 2026-07-14

First testable release: the full MVP plus the post-MVP feature set.

### Canvas & authoring
- Zoom HUD (bottom-left): always-visible zoom percentage — click for 100%
  (⌘0), fit button beside it (⌘9). New blocks are sized for what you see:
  matching visible neighbors, or readable at the current zoom on empty space
  — no more zoomed-in specks next to giant old content.
- Infinite pan/zoom canvas: blocks (rectangle / ellipse / diamond / triangle
  with orientation), connectors with labels + semantics (protocol, data,
  condition, direction), notes, freehand ink — everything undoable through a
  single operation layer.
- Sketch-to-structure: draw rough shapes/arrows with the Draw tool (D); they
  snap live into clean blocks and connectors, or convert on demand (⌘R);
  name-on-snap opens the label editor immediately. Shapes drawn as several
  strokes (a box from four lines) are chained and recognized as one block —
  live, the stroke that closes the shape completes it.
- Typed block palette (toolbar menu / ⌘K): service, database, queue, cache,
  gateway, client, external, decision, alert.
- Connectors bend: drag a selected connector to curve it smoothly through
  your drop point (drop back on the line to straighten). Straight connectors
  automatically curve around blocks that would otherwise be crossed.
- Drawn twice means two connections: connecting an already-connected pair
  (drag or sketch, either direction) creates a parallel connector with its
  own label — nothing is silently merged; bidirectional is an edge-editor
  property.
- Grouping (⌘G/⇧⌘G): click one member, move the whole group. Boundaries
  (⌥⌘B): labeled subsystem/trust-zone containers rendered behind content.
- Inspector (⌥⌘I): edit names, kinds, shapes, and connector semantics
  directly. Snapping & alignment guides; fuzzy ⌘K command palette.
- Hand-drawn style (Board menu): the whole board renders like a marker
  sketch — wobbly outlines, handwritten labels — while staying fully
  structured. Per board, undoable, off by default.
- Layers (⌘L): one board, many concerns; visibility, locking, focus dimming.
- Side panels (layers, versions, library, flows, assistant) stack in one
  right-hand column — open panels never overlap, windows have a sane
  minimum size.
- Library (⌘Y): save and reuse diagram patterns.

### Understanding traffic
- Simulate (⌘↩): flood playback — watch data propagate wave-by-wave from any
  block, honoring connector direction, with pause/speed/restart transport.
- Flows (⌘J / ⇧⌘↩): record the exact journey a request takes by clicking the
  blocks it visits — candidate next blocks are highlighted with their
  connectors shown normally while unreachable ones dim; parallel connectors
  (gRPC vs HTTP) prompt a one-click choice — then replay it as an animated
  packet in the flow's color; conditions surface during playback; isolate a
  flow to dim everything it doesn't touch. Connectors sharing a node side
  spread along it automatically so arrows never stack.

### AI collaboration
- Local MCP server (Board ▸ Enable Agent Access, persists): any MCP client —
  Claude Desktop, Claude Code — can read the board and PROPOSE edits.
  Proposals appear as ghosts on the canvas with a diff banner and legend:
  green dashed + "+" badge = will be added, red dashed + ✕ strike = will be
  removed; auto-placed additions never land on existing blocks. Nothing
  applies until accepted (one undo step). Agents receive an authoring guide
  (kinds, shapes, labeling, progressive-disclosure layering) automatically;
  they can create LAYERS (name-addressed, tint, hidden, multi-membership)
  and FLOWS (recorded journeys with per-hop connector choice); renames are
  detected instead of read as remove+add; freehand ink and boundaries are
  never touched by proposals.
- In-app assistant (⇧⌘A): chat with Claude inside Designer, billed to your
  Claude subscription via the Claude Code CLI — model and thinking-effort
  selectors included. Edits arrive through the same propose→review flow.
- Version history (⇧⌘H): named snapshots stored inside the board package —
  save one manually (⌃⌘S), one is captured automatically before accepting an
  assistant proposal. Preview any version as a ghost diff against the current
  board, restore it (one undo step; the pre-restore state is snapshotted
  first), rename or delete. Automatic snapshots are pruned; manual ones never
  expire.

### Interchange & files
- Boards are folder packages (board.json + assets), autosaved, with a
  catalog start screen (New Canvas + previous boards with thumbnails;
  right-click a board to open, reveal in Finder, or move it to the Trash).
- Copy for LLM / import back (lossless text round-trip), PNG + SVG export,
  copy/paste/duplicate across windows.
- draw.io and Excalidraw interchange (File menu): import .drawio/.xml
  (including draw.io's compressed saves) and .excalidraw/.json into a new
  board, and export any board (or selection) to either format — shapes,
  labels, connectors with labels, and notes map across; freehand ink
  round-trips with Excalidraw.

### Performance
- Full-viewport redraw holds 60 fps on 6,000-element boards during
  continuous pan, with raw draw cost at avg 4.0 ms / p95 8.1 ms — inside the
  120 Hz ProMotion budget (verified by --perf-test's draw-cost line).
