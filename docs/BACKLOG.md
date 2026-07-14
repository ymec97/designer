# Backlog — acknowledged, deliberately not scheduled yet

Issues and ideas the user has flagged. Each entry says when it should be
revisited. Do not silently drop items; move them to a milestone when picked up.

## Bugs

### B1. Label editor font overflows its box at high zoom — FIXED 2026-07-14
*Reported 2026-07-12 by Yarden.* The editing field now scales with the zoomed
node (height tracks the scaled font) instead of clipping at a fixed 24px.

### B2. Sort keys grow under repeated sequential insertion — FIXED 2026-07-14
*Found 2026-07-12 during M2 perf work.* Boards are renumbered to compact bulk
keys at document load (before undo history exists) whenever any key exceeds
24 chars; z-order preserved exactly. Mid-session growth remains bounded by
how much a user can insert in one sitting.
`SortKey.after()` chained N times grows keys ~1 char per ~17 insertions
(quadratic total cost; a 5.9k-element chain visibly hung board generation).
Bulk builders now use `SortKey.bulk(_:of:)`, but interactive boards that add
thousands of elements over their lifetime will accumulate long keys. Fix:
adopt integer-part fractional keys (jitter-style "a0/a1/b00" scheme) with a
migration, or periodically renumber keys in an idle pass.

## Open questions (no decision yet)

### Q1. Should saved traffic paths / simulations be layers? — RESOLVED 2026-07-13
Decision (Yarden, during the F5 design cycle): **flows are their own concept**,
not layers. Layers keep solving grouping/visibility of concerns; Flows (F5,
shipped) solve sequence + correlation — named, recorded paths that pick
specific edges among parallels. A flow's eye-toggle gives the layer-like
"isolate this traffic" view. Possible future bridge: "Create layer from flow".

### F4-refine. Agent-proposal review polish
*Noted 2026-07-13 while building the MCP agent surface (F4).*
Two refinements deferred from the first cut:
- **Rename-aware diff.** DONE 2026-07-14: removed+added pairs with matching
  footprint (or a single related-name pair) collapse to one rename; edges
  re-keyed through the mapping.
- **On-canvas ghost preview.** DONE 2026-07-13: proposals render as dashed
  accent ghosts (additions) and red outlines (removals) on the canvas, with a
  reveal-camera jump to the affected region.

### F6. In-app chat panel (Claude/ChatGPT via user's subscription)
*Requested 2026-07-13 by Yarden.* A chat drawer inside Designer where the user
talks to an assistant that reads/edits the open board — no external app.
Design (CLI-bridge approach, the only subscription-billed path):
- There is NO public API for consumer subscriptions directly; but **Claude
  Code CLI** authenticates with a Claude Pro/Max subscription and runs
  headless (`claude -p --output-format stream-json`), and **Codex CLI**
  signs in with a ChatGPT subscription. Designer spawns the CLI as a child
  process per conversation, pointing it at Designer's own MCP server
  (`--mcp-config` → http://127.0.0.1:PORT/mcp), so the assistant uses the
  same describe/get/search/propose tools — proposals still land in the
  review banner (consent preserved; optional auto-accept toggle later).
- Chat panel: transcript + input, streaming responses, "working on the
  board…" states for tool calls; provider picker (Claude first; Codex
  later); setup detection (`which claude`, logged-in probe) with friendly
  guidance when missing; session continuity via --resume.

### F7. Distribution & first-run (new-machine story)
*Identified 2026-07-14 during the Claude-integration review.*
Gaps between "builds on Yarden's Mac" and "installs on a new laptop":
- **Signing/notarization**: build a Developer-ID-signed, notarized .app (+DMG)
  so Gatekeeper allows it without right-click-open. Hardened runtime must
  still allow spawning the claude CLI (no sandbox — MAS distribution would
  block Process(); stay outside the App Store or drop the chat bridge there).
- **Agent access is per-launch**: the MCP toggle isn't persisted; external
  clients (Claude Desktop) must re-enable it every launch. Persist the
  preference + auto-start the server on launch when enabled.
- **Port conflicts**: preferred port 51737 falls back to an ephemeral port,
  silently breaking saved connector configs; surface the change and/or retry.
- **Boards folder isn't synced** (~/Library/Application Support): consider an
  iCloud Drive container so boards follow the user across Macs.
- Chat prerequisites are handled (CLI detection + guidance) but could add a
  one-click "install & sign in" helper flow.

### P9. iPad story
*Assessed 2026-07-14.* The pure-Swift core (Model, Interop, Recognition,
Agent) is portable to iOS today; DesignerCanvas + the app shell are AppKit
(NSDocument/NSView/NSMenu) and would need a UIKit/SwiftUI canvas rewrite —
a dedicated milestone. The chat bridge cannot work on iPadOS (no spawning
processes; no Claude Code CLI) — an iPad build would need direct-API chat or
none. NEAR-TERM ANSWER: Sidecar — the Mac app already supports pencil
pressure through the ink pipeline, so an iPad + Sidecar gives touch/pencil
drawing today with zero work. Revisit a native iPad app only after the Mac
app stabilizes.

### F3. Version history (Confluence-style) for boards — DONE 2026-07-15
*Requested 2026-07-13 by Yarden.* Shipped: versions/ directory inside the
board package (index + full board snapshot + thumbnail per version), manual
Save Version (⌃⌘S) + auto-snapshot before accepting agent proposals (pruned
to 10; manual versions never expire), Versions panel (⇧⌘H) with ghost-diff
preview vs current, rename, delete, and restore as one undo step (the
pre-restore board is auto-snapshotted first).
A named-version history per board: snapshot points (manual "save version" and/or
automatic on significant edits or on accepting an agent proposal), a version list,
a visual diff between any two versions, and revert-to-version. Think Confluence
page history. For now the agent-proposal flow relies on ⌘Z undo as the safety
net; this replaces that with durable, browsable, revertible history. Likely
model: store BoardSnapshot + board.json per version in the .designerboard
package (or a sidecar), reuse the MCP proposal diff engine for the version diff
view. Revisit after the MCP surface (F4) lands.

## Post-MVP problems to design for

### P1. Zoom-level drift makes content sizes inconsistent — DONE 2026-07-15
*Reported 2026-07-12 by Yarden.* Shipped: (a) persistent zoom HUD
(bottom-left) — live percentage, tinted when away from 1x, click for 100%,
fit button beside it (menu had ⌘0/⌘9 already); (b) size-normalized creation —
new blocks match the median size of visible neighbors, or on empty space are
sized readable at the current zoom (factor clamped 1/4…4x). Not done (waiting
for real-world need): ambient grid density, zoom-to-match prompt.
Original notes:
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

### P2. Proportional group resize for multi-selection — DONE 2026-07-13
*Requested 2026-07-12 by Yarden.* Shipped: multi-selection bounding box with
handles scales all members (nodes, notes, ink, waypoints) about the anchor in
one undo step.
When multiple items are selected, show a bounding box with handles that
resizes ALL selected elements proportionally — enlarge/shrink while
preserving each item's internal proportions and their relative positions
(scale positions and sizes about the box anchor). Applies to nodes, notes,
ink strokes, and edge waypoints. Should be one undo step (batch operation —
the operation layer already supports this). UI: replace the current
single-selection-only handle box with a multi-selection variant.

### P3. Hand-drawn ("sketchy") render style, toggleable — DONE 2026-07-15
*Requested 2026-07-12 by Yarden.* Shipped: Board ▸ Hand-drawn Style (per-board
flag in extra["sketchy"], undoable via the new setExtra op, off by default).
Outlines render as two overlaid deterministically-jittered passes (seeded by
element size so drags don't shimmer; wobble is world-attached), fills stay
clean, labels go handwritten (Noteworthy, rounded-system fallback). Applies
to canvas + PNG/thumbnail snapshots. SVG export stays clean for now.
Original notes:
An Excalidraw-style roughness option: blocks, connectors, and text render
with hand-drawn jitter/wobble even after structurizing — keeps diagrams
feeling informal. Must be a per-board (or per-export?) toggle, default off.
Implementation sketch: deterministic per-element seed, rough path generation
(2 passes with offset control points), rough fills (hachure or solid),
hand-style font option. Applies to SVG/PNG export too.

### P4. Edge-density visual QA: hubs and parallel connections — DONE 2026-07-14
*Requested 2026-07-12 by Yarden.* All three fixes shipped: parallel edges
separate (anchor spreading supersedes the perpendicular bow for spread edges),
hub nodes distribute anchors along their sides (EdgeGeometry.anchorSpread),
and parallel-edge captions stagger along the route so labels stay readable.
Remaining niche: very short parallel connectors can still clip caption
corners — revisit only if it shows up in real boards.
Build/test a complex board where (a) one node has many parallel connections
to the same other node, and (b) a hub node fans out to many nodes. Judge
whether it reads clearly or becomes an unclear mess. Likely fixes to evaluate
if ugly: parallel-edge separation (offset curves between same node pair),
fan-out anchor spreading (distribute anchor offsets along the node side
instead of all hitting the midpoint), and label decluttering at density.

### P5. Curve connectors after snapping + node-avoiding routing — DONE 2026-07-15
*Requested 2026-07-12 by Yarden.* Shipped: (a) drag a selected connector to
bend it (smooth Catmull-Rom curve through the waypoint; grab dot at the
midpoint; drop back on the line — or run "Straighten Selected Connectors" —
to straighten; one undo step); (b) straight connectors automatically detour
around blocking nodes (perpendicular clearance on the cheaper side, capped so
wild swings never happen; manual waypoints and orthogonal routing opt out).
Original notes:
(a) Let users curve a snapped connector (drag its midpoint to bow it —
`Edge.waypoints` already exists in the model, needs manipulation UX and
curved rendering). (b) Routing should avoid crossing over other nodes where
possible (obstacle-aware orthogonal/curved routing; the spatial index can
supply obstacles).

### P6. App logo / icon — DONE 2026-07-14
*Requested 2026-07-13 by Yarden.* Generated sketch-to-structure mark
(scripts/generate-icon.swift → App/AppIcon.icns), wired into the bundle.
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

## Bugs / UX

### B3. Name-on-snap: focus a label field when a sketch becomes a shape — FIXED 2026-07-14
*Requested 2026-07-13 by Yarden.* Both live conversion and ⌘R now open the
label editor on the produced block (connectors keep the edge editor).
When a freehand stroke structurizes into a block (live conversion or ⌘R),
immediately open and focus an in-place text field on the new shape so the
user can name it without a second action — mirrors the double-click-to-create
flow. Hook: after `SketchConversion` produces a node, call the canvas's
`beginLabelEdit` on the produced element (skip for connectors).

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
