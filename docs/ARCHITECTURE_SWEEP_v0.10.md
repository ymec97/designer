# Architecture coherency sweep — v0.5 → v0.10

*Read-only sweep produced for Workstream F (v0.10). Covers drift across the
last five releases (v0.5.0 → v0.9.0) plus the in-progress v0.10 work on
`feature/v0.10-feedback`. No source was modified. Line numbers are against the
branch state at sweep time.*

---

## (a) Intended architecture (recap)

Designer keeps **one mutation channel**: every board change is a
`BoardOperation` applied through `Board.apply(_:)`, which returns its exact
inverse; `BoardDocument.perform(_:actionName:)` is the single place that runs an
op and registers the inverse as one undo step. The canvas never mutates the
model — it calls its delegate, which routes to `perform`. On disk the model is
UUID-addressed and lossless, with unknown JSON kept in per-type `extra` bags
(tolerant coding). The **agent wire format (`WireBoard`) is a deliberately
lossy, name-addressed projection**: it carries nodes/edges/notes/layers/flows
and now positions, sizes, and explicit `fill`/`stroke`/`opacity`, but it never
carries ink, boundaries, dangling edges, or node `extra` (board links) — so an
agent can neither see nor wipe what it isn't shown. Proposals parse *anchored to
the current board* (matched nodes inherit frame + style for unset fields) and
are reviewed as a diff/ghost before a single wholesale `perform` applies them.
`Style` uses hex colors, a `fill:"none"` sentinel, and 0…1 element opacity
composited as one unit. Coordinates are world-space y-down mapped by
`CanvasViewport`. Performance is priority #1: all derived caches rebuild once on
`board` didSet (never per frame), and a far-zoom batch path bypasses per-node
drawing.

---

## (b) Per-area assessment

| # | Area | Verdict | Evidence |
|---|------|---------|----------|
| 1 | Agent wire format's growing responsibility; is "lossy on purpose" still coherent; any leak? | **Concern** | Boundary is still coherent on the *read* side, but there is a real **write-side leak of board links.** |
| 2 | Style sentinels + opacity layering; focus-dim; double-composite? | **Minor drift** | Core layering coherent and well-reasoned; one niche inconsistency where opacity and focus-dim interact. |
| 3 | diff ↔ apply ↔ ghost triad; v0.10 layer-in-diff | **Coherent** (one pre-existing gap) | Triad lines up; v0.10 layer change is handled end-to-end; moved-only nodes have no ghost. |
| 4 | Linked-board read-only guarding | **Concern** | Airtight for the canvas + undo/redo paths; **panel/menu-driven `document.perform` calls are not gated.** |
| 5 | Caches on `board` didSet vs live-drag transient recompute | **Minor drift** | Split is deliberate and correct for perf, but the drag path drops obstacle avoidance — a real "weird edges" source. |
| 6 | Undo integrity: `perform`/`groupsByEvent`/`isNoOp`; bypass paths | **Coherent** (with caveats) | v0.10 root-cause fix is sound; `isNoOp` is narrower than its comment; a few intentional non-undoable paths. |
| 7 | Sort-key growth + load-time normalize | **Minor drift** | Load-time normalize is adequate; interchange importers regressed to `topSortKey` instead of bulk keys. |

### 1 — Agent wire format (Concern: board links wiped on accept)

The read boundary is intact. `WireBoard` (`WireBoard.swift:36-55`) has no field
for `NodeSemantic.extra`, ink, boundaries, or dangling edges;
`WireBoard(from:)` never emits them, and `ProposalApply.isWireRepresentable`
(`ProposalApply.swift:73-80`) explicitly preserves ink, boundaries, and
dangling edges across an accepted proposal. Positions/sizes/`fill`/`stroke`/
`opacity`/`layers` growing into the wire is coherent and is correctly paired
with anchoring (`WireBoard.anchorPositions` `WireBoard.swift:211-233`) and style
inheritance so unset fields fall back to the current look.

**The leak:** board links live in `NodeSemantic.extra["linkedBoard"]`
(`NodeLink.swift:9-27`) and are correctly kept out of the wire. But accepting a
proposal rebuilds matched nodes from the wire and swaps them in wholesale:
`WireBoard.toBoard` constructs `NodeSemantic(kind:name:)` with an **empty**
extra bag (`WireBoard.swift:306-310`); `inheritingStyles` merges only the
`Style` struct, **not** `NodeSemantic.extra` (`LLMInterchange.swift:139-169`);
and `ProposalApply.replaceOperation` removes every current wire-representable
element and inserts the proposed fresh ones (`ProposalApply.swift:44-55`). So a
node that carried a board link loses it the moment any proposal that includes it
is accepted — which is every proposal, since the node appears in the wire. This
**contradicts the stated invariant** (CLAUDE.md: "node `extra` (e.g. board
links)… so agents can't wipe what they can't see"; CHANGELOG v0.9.0: "an
accepted AI proposal can't wipe or forge them"). The "can't forge / can't see"
half holds; the "can't wipe" half does not. There is no test covering it —
`ProposalApplyTests` preserves ink and dangling edges
(`ProposalApplyTests.swift:30,50`) but not links; `NodeLinkTests` only checks
JSON round-trip.

### 2 — Style sentinels + opacity layering (Minor drift)

Coherent and deliberately reasoned: element opacity fades fill+stroke+label as
one via a transparency layer to avoid the stroke-over-fill double-composite
(`BoardRenderer.swift:236-244,370-373`); `fill:"none"` (`Style.noFill`) skips
fill, shadow, and image (`Style.hasFill` `Style.swift:41`, renderer `250-273`);
`effectiveOpacity` clamps to 0…1 (`Style.swift:43`). The v0.10 focus-dim label
fix is correct for the common case: a dimmed node's label is recolored against
the ground and floored at `dimmedLabelFloor` (0.6) so it stays legible while the
node recedes (`BoardRenderer.swift:346-368`), and the embedded image folds the
dim into its `fraction` because `NSImage.draw` doesn't inherit the context alpha
(`BoardRenderer.swift:324-332`) — no double-dim there.

**The niche inconsistency:** `CGContext.setAlpha` is *absolute*, not
multiplicative. Focus-dim wraps a node in `setAlpha(0.22)`
(`withFocusAlpha` `CanvasView.swift:2508-2514`), but if that node also has
element opacity < 1, `drawNode`'s inner `setAlpha(opacity)`
(`BoardRenderer.swift:242`) **clobbers** the 0.22 blanket, so a semi-transparent
node on a *non-focused* layer renders at its own opacity and does not visibly
recede. The far-zoom batch path is separately inconsistent here: it dims via a
uniform `alpha: dimmedAlpha` batch and ignores per-node opacity entirely
(`CanvasView.swift:461-463`) — acceptable under the documented "far-zoom skips
per-node decorations" rule, but worth noting opacity is one of those skipped
properties. Exposure is small (requires opacity<1 **and** focus dimming at once)
but the near/far paths disagree.

### 3 — diff ↔ apply ↔ ghost triad (Coherent; one pre-existing gap)

The triad is consistent. The diff computes on the wire projection of both boards
and carries proposed-side element ids for adds/changes and current-side ids for
removes (`BoardDiff.swift:32-38,150-197`); the ghost renders exactly those sets
(`CanvasView.swift:919-985`); and apply inserts the proposed elements keeping
their ids while removing the current ones — so the ids the ghost previews are
the ids apply produces. v0.10's **layer-in-diff** change is coherent end to end:
`delta()` now compares `layersLabel` for nodes and edges
(`BoardDiff.swift:242-244,285-287`), a re-layer therefore lands in
`changedNodes`/`changedElementIDs` and renders as a "changed" ghost, and
`ProposalApply` maps membership by layer name (`ProposalApply.swift:22-41,52-53`)
so the accepted result matches the preview.

**Pre-existing gap (not v0.10):** a *move-only* node (frame changed, nothing
else) is recorded in `movedNodes` but is deliberately **not** added to
`changedElementIDs` (`BoardDiff.swift:164-166`), and the ghost overlay has no
"moved" pass — so the banner says "N repositioned" while the canvas shows the
node only at its **old** position with no preview of where it will land. Text
and ghost disagree for that one case.

### 4 — Linked-board read-only guarding (Concern: not all mutation paths gated)

The board-swap design is sound: entering a link swaps `canvasView.board` to a
foreign board and sets `isReadOnly`, while `document.board` (and the undo
manager) stay on the original (`LinkedBoards.swift:303-304,329-330`). Its safety
rests on gating mutations, and the two paths the v0.10 handoff addressed are now
airtight:

- **Canvas gestures** — `mouseDown` early-returns to navigation/selection only
  in read-only (`CanvasView.swift:1528`), and every gesture commit funnels
  through `delegate?.canvasView(_:perform:)`, which the controller blocks at a
  single choke point (`CanvasViewController.swift:1920-1923`). So even the
  keyboard paths that don't self-check `isReadOnly` (delete/nudge in `keyDown`
  `CanvasView.swift:2071-2098`; `deleteSelection:2117`) cannot reach the model.
- **Undo/redo** — the v0.10 `undo:`/`redo:` overrides on the controller beep and
  return in read-only, and `validateMenuItem` disables them
  (`CanvasViewController.swift:1945-1953,1957-1960`). This correctly fixes the
  "⌘Z mutates the hidden board" bug.

**The residual concern:** many mutations call `document.perform` **directly**
from menus and side panels, bypassing the canvas delegate — layer show/hide,
rename, delete, reorder, assign-to-layer (`CanvasViewController.swift:1077,1363-
1423`), flow rename/delete (`809,815`), structurize, library insert
(`1693`), inspector edits (`applyInspectorEdit` `153`), and agent
`setLayerVisibility` (`1070-1078`). None of these is gated on
`canvasView.isReadOnly`, and `validateMenuItem` gates only `undo:`/`redo:`. The
side panels are not hidden on entering read-only (only the *style* panel is, via
`refreshStylePanel` `244-247`), so a layer toggle or flow edit performed while
"inside" a linked board mutates the **parent** document invisibly and strands an
undo step that the read-only guard then refuses to replay. Selection-based
actions are incidentally inert (selection ids belong to the swapped board and
miss in `document.board`), but layer/flow/simulate actions are not. The clean
fix matches the existing "single channel" spirit: one controller-level
`canEdit` used by every `document.perform` call site (or hide the editing panels
while `linkedViewModel.isActive`), rather than the current per-path guarding.

### 5 — Caches vs live-drag transient recompute (Minor drift; the "weird edges")

The cache split is deliberate and correct for the frame budget: all derived
state (`parallelOffsetCache`, `anchorSpreadCache`, `routeCache`, `spatialIndex`,
`edgeBatchCache`, z-order) rebuilds once in `board` didSet
(`CanvasView.swift:17-45`), and only edges anchored to an in-flight drag are
re-resolved per frame (`dragAffectedEdges`, `CanvasView.swift:390-427`) — the
comment records this was the 45ms→16ms difference.

**The drift:** the cached routes come from `SpatialIndex.resolveRoutes`, which
passes node **obstacles** into `EdgeGeometry.route` for avoidance
(`SpatialIndex.swift:60-72`). The per-frame drag recompute calls
`EdgeGeometry.route(for:frames:parallelOffset:anchorOffsets:)` with **no
`obstacles` argument** (`CanvasView.swift:420-424`), so a dragged edge routes
straight — crossing blocks it would normally detour around — then snaps to the
avoided route on mouse-up when `routeCache` rebuilds. This transient-vs-committed
divergence is a genuine source of the B10 / Workstream-A "weird edges" reports
(edges that hook or cross mid-drag and jump on release). It is an intentional
perf trade (obstacle queries per dragged edge per frame are costly), but it is a
latent bug surface. Options: feed the spatial index as obstacles only when the
dragged-edge count is small, or accept it and stop routing avoidance mid-drag
consistently (draw a straight rubber-band) so there's no visible "jump".

### 6 — Undo integrity (Coherent, with caveats)

The v0.10 root-cause fix is correct: `groupsByEvent = false` is set **once** in
the `undoManager` setter (`BoardDocument.swift:21-27`) instead of on every
`perform`, which is what stranded AppKit's open per-event group and caused the
"stuck ⌘Z"; `perform` now just brackets each op in one explicit group
(`BoardDocument.swift:161-184`). The single-channel invariant holds — spot-check
of every `document.perform`/`board.apply` call site shows mutations flowing
through it (agent accept `CanvasViewController.swift:1039-1041`, version restore
`BoardDocument.swift:136-144`, linking `LinkedBoards.swift:191`, all panel/menu
edits).

Caveats:
- **`isNoOp` is narrower than its doc comment.** It returns true only for an
  empty batch or a batch of empty batches; a non-batch op — including a
  `replaceElement` whose element is byte-identical to the current one — reports
  `false` (`BoardOperation.swift:39-44`). So the "a ⌘Z that changes nothing"
  guard catches empty batches but not identity replaces. Fine today (call sites
  mostly pre-check), but the comment overstates it.
- **Intentional non-undoable paths** (correct, but list them for the record):
  `saveVersion`/`renameVersion`/`deleteVersion` mutate the version archive
  outside `perform` by design (`BoardDocument.swift:118-154`); the linked-board
  board-swap changes view state only; agent `setLayerVisibility` *is* undoable
  (routes through `perform`).

### 7 — Sort-key growth + load-time normalize (Minor drift)

`normalizeSortKeysIfNeeded` at load (threshold 24 chars, rewrites to compact
`SortKey.bulk` keys preserving z-order, before any undo history exists) is a
sound answer to B2 for interactive growth (`SortKeyMaintenance.swift`,
`BoardDocument.swift:99`).

**The drift:** the B2 resolution says "bulk builders now use
`SortKey.bulk(_:of:)`", and the synthetic builders do (`PerfTest.swift:37,63`,
`ExampleBoard.swift:16`, `Screenshot.swift:21`). But the **interchange
importers** build with `board.topSortKey` per element in a loop —
`WireBoard.toBoard` (`WireBoard.swift:305,321,341,364`), `DrawioFormat`
(`274-386`), `ExcalidrawFormat` (`82-121`). `topSortKey` is
`SortKey.after(elements.values.map(\.sortKey).max())`
(`Board.swift:58-59`): an O(N) scan that also chains `after()`, so a large
import is O(N²) in the scan alone and grows keys ~1 char per ~17 inserts — the
exact pattern B2 flags. It self-heals on the next load (normalize), and agent
proposals are small enough not to notice, but a multi-thousand-cell draw.io
import pays it up front. Converting the importers to `SortKey.bulk(index, of:
count)` (they already know the element count) removes it.

---

## (c) Prioritized recommendations

### Fold into v0.10 (low-risk, high-value)

1. **Preserve board links across an accepted proposal (Area 1 — fixes a broken
   invariant).** Extend the proposal parse to re-merge the matched current
   node's `NodeSemantic.extra` (at minimum `linkedBoardKey`) onto the proposed
   node — the same place `inheritingStyles` restores `Style`
   (`LLMInterchange.swift:139-169`) — or preserve it in
   `ProposalApply.replaceOperation`. Add a `ProposalApplyTests` case: a linked
   node survives a node-only proposal. Small, contained, and restores a
   documented v0.9 guarantee. Pairs naturally with Workstream E (linked boards).

2. **Gate panel/menu mutations in read-only linked view (Area 4).** Add one
   controller-level `canEdit` (`!canvasView.isReadOnly`) checked at the
   direct `document.perform` call sites, or hide the editing panels while
   `linkedViewModel.isActive`, plus extend `validateMenuItem` beyond
   `undo:`/`redo:`. This completes Workstream D's read-only guard rather than
   leaving it half-covered. Add a `--ui-test` step: a layer toggle is inert
   inside a linked view.

3. **Tighten `isNoOp` or its comment (Area 6).** Either detect an identity
   `replaceElement`/`replaceLayer`/`replaceFlow` (compare against the current
   element) so genuine no-ops don't consume undo slots, or narrow the doc
   comment to "empty batch". Trivial, avoids future confusion.

### File as backlog follow-ups (larger or lower urgency)

4. **Mid-drag edge routing (Area 5 / B10).** Decide the transient-route policy —
   obstacle-aware when few edges are dragged, or a consistent straight
   rubber-band — so committed and in-flight routes don't disagree. This is the
   substance of Workstream A's "weird edge routing"; treat the cache/transient
   split as the root cause, not just `route()` heuristics.

5. **Convert interchange importers to bulk sort keys (Area 7 / B2).**
   `WireBoard`, `DrawioFormat`, `ExcalidrawFormat` should assign
   `SortKey.bulk(index, of: count)` instead of per-element `topSortKey`. Removes
   an O(N²) import cost and the key-growth path for large imports.

6. **Move-only ghost preview (Area 3).** Give `movedNodes` an element-id set and
   a ghost pass (arrow or before/after outline) so "N repositioned" has an
   on-canvas preview, closing the last text↔ghost gap.

7. **Opacity × focus-dim consistency (Area 2).** If semi-transparent nodes on
   dimmed layers matter, compose the two multiplicatively (dim the fill inside
   the transparency layer, or multiply the floors) so near-zoom and far-zoom
   agree. Low urgency — niche visual only.
