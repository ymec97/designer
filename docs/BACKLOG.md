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

## Clarified requirements (already in the brief, re-affirmed)

- **Freehand drawing works with a plain mouse/trackpad** — pressure input
  (iPad/Sidecar pencil) enhances stroke rendering but is never required.
  `StrokePoint.pressure` defaults to 0.5 for non-pressure devices (M3).
