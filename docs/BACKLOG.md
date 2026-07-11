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

## Clarified requirements (already in the brief, re-affirmed)

- **Freehand drawing works with a plain mouse/trackpad** — pressure input
  (iPad/Sidecar pencil) enhances stroke rendering but is never required.
  `StrokePoint.pressure` defaults to 0.5 for non-pressure devices (M3).
