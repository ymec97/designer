# Backlog — acknowledged, deliberately not scheduled yet

Issues and ideas the user has flagged. Each entry says when it should be
revisited. Do not silently drop items; move them to a milestone when picked up.

## Bugs

### B1. Label editor font overflows its box at high zoom
*Reported 2026-07-12 by Yarden. Fix during a polish pass (M6 at the latest).*
The in-place label editor scales its font with `viewport.scale`, but the
NSTextField keeps a fixed ~24px height — at high zoom the text is clipped and
effectively invisible while typing. Likely fix: size the field to the zoomed
node frame (height and width), or clamp the editing font and zoom the canvas
so editing always happens at a readable effective scale.

### B2. Sort keys grow under repeated sequential insertion
*Found 2026-07-12 during M2 perf work. Address in M6 polish.*
`SortKey.after()` chained N times grows keys ~1 char per ~17 insertions
(quadratic total cost; a 5.9k-element chain visibly hung board generation).
Bulk builders now use `SortKey.bulk(_:of:)`, but interactive boards that add
thousands of elements over their lifetime will accumulate long keys. Fix:
adopt integer-part fractional keys (jitter-style "a0/a1/b00" scheme) with a
migration, or periodically renumber keys in an idle pass.

## Post-MVP problems to design for

### P1. Zoom-level drift makes content sizes inconsistent (Excalidraw pain)
*Reported 2026-07-12 by Yarden. Address post-MVP; design thinking welcome earlier.*
On an infinite canvas you lose track of your zoom level; content created while
zoomed differs wildly in world-space size from content created at 1×, which
you only discover when panning to older content. Candidate mitigations to
evaluate (not decided):
- persistent zoom indicator with a one-click "back to 100%";
- size-normalized creation: new blocks/text get a world-space size chosen for
  readability at the *current* zoom (i.e., always ~160×80 on screen), so
  everything created is proportionally consistent with the current view;
- "zoom to match" helper when the user starts creating next to existing
  content whose scale differs a lot from the implied creation scale;
- optional reference grid whose density communicates zoom level ambiently.

### P2. Proportional group resize for multi-selection
*Requested 2026-07-12 by Yarden. Post-MVP.*
When multiple items are selected, show a bounding box with handles that
resizes ALL selected elements proportionally — enlarge/shrink while
preserving each item's internal proportions and their relative positions
(scale positions and sizes about the box anchor). Applies to nodes, notes,
ink strokes, and edge waypoints. Should be one undo step (batch operation —
the operation layer already supports this). UI: replace the current
single-selection-only handle box with a multi-selection variant.

### P3. Hand-drawn ("sketchy") render style, toggleable
*Requested 2026-07-12 by Yarden. Post-MVP.*
An Excalidraw-style roughness option: blocks, connectors, and text render
with hand-drawn jitter/wobble even after structurizing — keeps diagrams
feeling informal. Must be a per-board (or per-export?) toggle, default off.
Implementation sketch: deterministic per-element seed, rough path generation
(2 passes with offset control points), rough fills (hachure or solid),
hand-style font option. Applies to SVG/PNG export too.

### P4. Edge-density visual QA: hubs and parallel connections
*Requested 2026-07-12 by Yarden. Run during M6 polish; fixes post-MVP if needed.*
Build/test a complex board where (a) one node has many parallel connections
to the same other node, and (b) a hub node fans out to many nodes. Judge
whether it reads clearly or becomes an unclear mess. Likely fixes to evaluate
if ugly: parallel-edge separation (offset curves between same node pair),
fan-out anchor spreading (distribute anchor offsets along the node side
instead of all hitting the midpoint), and label decluttering at density.

### P5. Curve connectors after snapping + node-avoiding routing
*Requested 2026-07-12 by Yarden. Post-MVP.*
(a) Let users curve a snapped connector (drag its midpoint to bow it —
`Edge.waypoints` already exists in the model, needs manipulation UX and
curved rendering). (b) Routing should avoid crossing over other nodes where
possible (obstacle-aware orthogonal/curved routing; the spatial index can
supply obstacles).

### P6. App logo / icon
*Requested 2026-07-13 by Yarden.*
Find/design a cool logo for the app: app icon (macOS .icns via Asset
Catalog), Dock icon, About panel. Candidate direction: geometric mark
blending a sketched stroke morphing into a clean block+connector (the
sketch-to-structure identity). Revisit at M6 polish.

### P7. Multi-stroke shape recognition
*Requested 2026-07-13 by Yarden. Post-MVP.*
A shape drawn as several separate line streaks (e.g. 4 strokes forming a
box) should structurize into one block. Approach: on ⌘R over multiple ink
strokes, chain strokes whose endpoints meet within tolerance into a single
virtual stroke, then run normal closed-shape recognition on the chain.
Live mode could also try chaining the last few strokes on stroke-end.

## Requested features (approved-pending, post-MVP)

### F1. Home / catalog start screen
*Requested 2026-07-13 by Yarden.*
On app open, show a catalog: first tile "New Canvas", remaining tiles are
previously created boards with thumbnails, sorted by last-modified, click to
open. Key decision: source of "previous canvases" — recommend a default
managed "Boards" folder (new boards auto-save there; Save As elsewhere still
allowed) indexed alongside NSDocumentController recent documents, deduped.
Reuse BoardSnapshot for thumbnails and the LibraryStore folder-index pattern.

### F2. Traffic / data-flow simulation
*Requested 2026-07-13 by Yarden.* Ties directly to core intent (data
transmission legibility).
Select a node, press Play (affordance appears near the selection / in a
transport control), and watch data propagate: highlight the source node, then
its outgoing connectors, then the next nodes, then their connectors — a
staged, wave-by-wave animation. Directed BFS from the source respecting edge
direction (forward/both/backward); visited-set for cycles. Animate a moving
packet along edge routes + node pulses; play/pause/restart + speed; a
non-destructive read-only "Simulate" mode (esc to exit). Must stay smooth
(display-link driven, dirty-region redraw) and respect Reduce Motion.

### P8. High-refresh / tiled-canvas rendering (120 Hz on ProMotion)
*Identified 2026-07-13 during the design pass. Performance investment.*
The canvas fully re-rasterizes every frame. It holds ~60 fps (16.7 ms, p95
16.7 ms) during worst-case continuous pan of 2k nodes + 4k edges — meeting the
D12 hard floor ("never below 60 Hz") but not the 120 Hz-on-ProMotion target
(≤8.3 ms). The architecture's intended upgrade path: composite pan/zoom as a
GPU transform of pre-rendered tiles (re-rasterize tiles async at new scale),
and cache the far-zoom edge batch + node text as rasters so per-frame work is
a blit, not a redraw. This is a dedicated perf effort, independent of visuals.
Note: the design pass was verified perf-neutral (identical A/B numbers).

## Clarified requirements (already in the brief, re-affirmed)

- **Freehand drawing works with a plain mouse/trackpad** — pressure input
  (iPad/Sidecar pencil) enhances stroke rendering but is never required.
  `StrokePoint.pressure` defaults to 0.5 for non-pressure devices (M3).
