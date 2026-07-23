# Designer — agent context

Native macOS app for engineering system-design diagrams: freehand sketching
that snaps to structure, plus layers, flows, traffic simulation, and an MCP
server so AI agents can read and propose board edits. Product decisions live
in `docs/PRODUCT_BRIEF.md` (D1–D17); the working backlog is `docs/BACKLOG.md`.

## Layout

SwiftPM package in `DesignerKit/`:

| Target | Role |
|---|---|
| `DesignerModel` | Board/elements/operations, geometry, routing (Swift 6, UI-free) |
| `DesignerPersistence` | `.designerboard` package (board.json + assets), catalog store |
| `DesignerRecognition` | stroke → shape/connector recognition |
| `DesignerInterop` | LLM wire format, diff, narrative auto-layout, draw.io/Excalidraw, SVG |
| `DesignerAgent` | MCP server (localhost JSON-RPC), proposal staging/apply, agent guide |
| `DesignerCanvas` | AppKit canvas view + renderer (120 Hz tiled) |
| `Designer` | the app: controllers, panels, menus, UI test driver (Swift 5) |

## Build, test, verify

Always set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```sh
cd DesignerKit && swift test          # full package suite — must be 0 failures
cd .. && scripts/build-app.sh         # builds build/Designer.app (ad-hoc signed)
./build/Designer.app/Contents/MacOS/Designer --ui-test      # expect UI-TEST PASS
./build/Designer.app/Contents/MacOS/Designer --smoke-test <tmp>/smoke.designerboard
caffeinate -u -t 5; caffeinate -dimsu ./build/Designer.app/Contents/MacOS/Designer --perf-test
./build/Designer.app/Contents/MacOS/Designer --agent-test   # live MCP round-trip
```

This is the release battery — every step must pass before merging/tagging.
The perf test needs the display awake and NOT in Low Power Mode / on battery
(macOS throttles the refresh rate and every run fails at ~2× frame times);
that failure mode is environmental, not a regression — plug in and re-run.
Release workflow (branching, tagging, packaging) is codified in
`.claude/skills/release/SKILL.md` — follow it exactly.

## Architecture rules that bite

- **All board mutations flow through `BoardDocument.perform(_:actionName:)`**
  (one undoable `BoardOperation` per user action; `apply()` returns the
  inverse). The canvas never mutates directly — it calls its delegate.
- **Tolerant coding**: model types keep unknown JSON keys in `extra` bags
  (`TolerantCoding.swift`). New persisted fields must be added to
  `CodingKeys` + `init(from:)`/`encode(to:)` or they silently drop.
- **The agent wire format is name-addressed and lossy on purpose**
  (`WireBoard`): node `extra` (e.g. board links), ink, and boundaries never
  cross it, so agents can't wipe what they can't see. Proposals parse
  **anchored to the current board** — matched nodes inherit position and
  style for fields the agent leaves unset. If you add a model field, decide
  explicitly whether agents may see/set it.
- **`Style`**: hex colors `#RRGGBB[AA]`, `fill: "none"` sentinel for no
  background, element `opacity` 0…1. Nodes, ink, notes, and edges all carry
  one.
- **Coordinates**: world space is y-down; `CanvasViewport` (origin+scale)
  maps world↔view. Never size UI chrome from zoomed view rects without
  clamping (a label editor once blanketed the toolbar at 13× zoom).
- **Performance is priority #1** (120 Hz budget): the canvas has a far-zoom
  batch fast path that bypasses per-node drawing — per-node decorations must
  either live in an overlay pass or accept being skipped at far zoom. Caches
  (routes, spatial index, batches) rebuild on `board` didSet, never per frame.

## Testing conventions

- `--ui-test` (`Designer/UITest.swift`) synthesizes real mouse/keyboard
  events through `NSWindow.sendEvent` — add a `stepNN...()` for user-facing
  behavior, register it in `run()`, extend the PASS line. Watch out: the
  left style panel swallows clicks — keep test scenes clear of view x ≲ 260.
- Env-gated visual checks render PNGs for eyeballing (`ImportVisualCheck`,
  `StyleVisualCheck`, `RelayoutVisualCheck` — see their env vars). They skip
  unless the vars are set, so they're free in CI runs.
- After changing `Style`/model Codable shapes, a stale incremental build can
  fail linking with phantom symbol errors — `swift package clean` fixes it.

## Repo hygiene

- Branch per change set → battery → `git merge --no-ff` into `main` → bump
  `VERSION` + `CHANGELOG.md` when releasing → annotated tag `v<semver>` →
  push `main` + tag. No force pushes. Shipped tags never move.
- `internal/` and `.claude/settings.local.json` are local-only (gitignored).

## Cloud / remote sessions (Claude Code on the web)

- This is a macOS/AppKit app: the Xcode toolchain is **not** present on the
  Linux cloud runner, so `swift test` / `scripts/build-app.sh` / the `--*-test`
  battery cannot run there. Write the code + tests carefully and run the full
  release battery on a Mac before merging/tagging.
- `git push` fails there: the git relay allows fetch (read) but returns
  **403 Forbidden** on `git-receive-pack` (write). When the session's GitHub
  App has `contents: write`, push with the **GitHub MCP** instead —
  `mcp__github__create_branch` (from `main`) then `mcp__github__push_files`
  (owner/repo `ymec97/designer`, the feature branch, all changed+new file
  contents in one commit). Don't retry the raw `git push`.
- If the MCP write also 403s with **"Resource not accessible by integration"**
  (as it did on 2026-07-23), the app installation is read-only — commit
  locally and ask the user to grant Claude's GitHub integration write access
  for this repo; do not keep retrying either path.
