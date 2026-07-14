# Changelog

Versioning: [SemVer](https://semver.org). `VERSION` at the repo root is the
source of truth; builds stamp it into the bundle together with the commit
count (build number) and date+sha (`DesignerBuildInfo`). Release artifacts
are named `Designer-v<version>-<date>.zip` (`scripts/package-app.sh`).

## v0.1.0 — 2026-07-14

First testable release: the full MVP plus the post-MVP feature set.

### Canvas & authoring
- Infinite pan/zoom canvas: blocks (rectangle / ellipse / diamond / triangle
  with orientation), connectors with labels + semantics (protocol, data,
  condition, direction), notes, freehand ink — everything undoable through a
  single operation layer.
- Sketch-to-structure: draw rough shapes/arrows with the Draw tool (D); they
  snap live into clean blocks and connectors, or convert on demand (⌘R);
  name-on-snap opens the label editor immediately.
- Typed block palette (toolbar menu / ⌘K): service, database, queue, cache,
  gateway, client, external, decision, alert.
- Grouping (⌘G/⇧⌘G): click one member, move the whole group. Boundaries
  (⌥⌘B): labeled subsystem/trust-zone containers rendered behind content.
- Inspector (⌥⌘I): edit names, kinds, shapes, and connector semantics
  directly. Snapping & alignment guides; fuzzy ⌘K command palette.
- Layers (⌘L): one board, many concerns; visibility, locking, focus dimming.
- Library (⌘Y): save and reuse diagram patterns.

### Understanding traffic
- Simulate (⌘↩): flood playback — watch data propagate wave-by-wave from any
  block, honoring connector direction, with pause/speed/restart transport.
- Flows (⌘J / ⇧⌘↩): record the exact journey a request takes by clicking the
  blocks it visits — candidate next blocks are highlighted with their
  connectors shown normally while unreachable ones dim; parallel connectors
  (gRPC vs HTTP) prompt a one-click choice — then replay it as an animated
  packet in the flow's color; conditions surface during playback; isolate a
  flow to dim everything it doesn't touch. Parallel connectors fan apart
  visually.

### AI collaboration
- Local MCP server (Board ▸ Enable Agent Access, persists): any MCP client —
  Claude Desktop, Claude Code — can read the board and PROPOSE edits.
  Proposals appear as ghosts on the canvas with a diff banner; nothing
  applies until accepted (one undo step). Agents receive an authoring guide
  (kinds, shape conventions, labeling) automatically; renames are detected
  instead of read as remove+add; freehand ink and boundaries are never
  touched by proposals.
- In-app assistant (⇧⌘A): chat with Claude inside Designer, billed to your
  Claude subscription via the Claude Code CLI — model and thinking-effort
  selectors included. Edits arrive through the same propose→review flow.

### Interchange & files
- Boards are folder packages (board.json + assets), autosaved, with a
  catalog start screen (New Canvas + previous boards with thumbnails).
- Copy for LLM / import back (lossless text round-trip), PNG + SVG export,
  copy/paste/duplicate across windows.

### Performance
- Full-viewport redraw holds 60 fps (p95 16.7 ms) on 6,000-element boards
  during continuous pan; 120 Hz tiled rendering is on the roadmap.
