# Designer — Product Brief & MVP Definition

*Working title: **Designer**. This is the founding brief the app was built
against; current feature state lives in CHANGELOG.md.*
*Brief written 2026-07-11; header updated 2026-07-15.*

---

## 1. Product brief

Designer is a native macOS app for engineers to **think in system diagrams at the speed of a whiteboard, and keep the result as a structured, reusable artifact**. The dominant use case is sketching during design work and meetings; the second is exporting clean diagrams into docs and chat.

Four ideas define the product:

1. **Sketch becomes structure.** Freehand ink is a first-class input. A rough rectangle becomes a real block; a rough line between two blocks becomes a real connector. Ink can also stay ink.
2. **Connectors carry meaning.** An edge is not a line — it records what moves, from where to where, over which protocol/channel, under which conditions. The board makes data transmission legible.
3. **One system, many concerns.** Layers are *views over the same objects* (multi-membership), so the same board reads as infra, data flow, security, ownership, failure modes, etc., without duplication.

4. **Diagrams are LLM-legible.** A board can be handed to any LLM (Claude, ChatGPT, …) for questions, analysis, and edits — model-agnostic, driven by the user's existing paid chat subscriptions, no API keys. Phase 1 (MVP): first-class text interchange — copy a board/selection as canonical JSON with a format primer, paste edited JSON back. Phase 2 (post-MVP): the app exposes an agent surface via **MCP** so chat apps can read and edit the live board directly.

Plus a **library**: any board, group, or selection can be archived as a named, tagged, searchable, re-insertable entry.

**Quality bar:** interaction smoothness is the top priority, and a **minimal, Excalidraw-like UI** is a co-equal top priority — a new user should face a nearly empty screen that explains itself: one slim toolbar, contextual inspector, everything reachable through ⌘K and context menus, defaults over preferences. 120 Hz on ProMotion, no dropped frames during pan/zoom/drag/draw, immediate feel under mouse, trackpad, and iPad-via-Sidecar pencil input.

## 2. Requirements Decisions (locked)

| # | Decision |
|---|----------|
| D1 | Initial audience: Yarden as a personal daily tool; built so team distribution later is cheap. |
| D2 | Primary moment: thinking/sketching during design work; clean export is a strong second. |
| D3 | macOS-only, permanently acceptable → **native Swift stack**. |
| D4 | Minimum macOS 14 (Sonoma). |
| D5 | Distribution: direct build via Xcode with **free** Apple developer account (local signing; runs indefinitely on own Mac). Notarized distribution to others requires the paid program — deferred. |
| D6 | No language preference from user → stack chosen purely on merit. |
| D7 | MVP export: PNG, SVG, native JSON. MVP import: none required (Excalidraw import if cheap). |
| D8 | Edge semantics: free-text label + key/value tags, with **well-known keys** the UI renders specially (`protocol`, `data`, `condition`, `direction`, plus open set: `ownership`, `latency`, `trust-boundary`, `failure-mode`, …). Upgrade path to typed schema later. |
| D9 | Layers: **multi-membership** (object exists once, appears on any layers it's tagged with). Z-order is a separate per-object mechanism. New objects land on all currently *active* layers, shown explicitly in the UI. |
| D10 | Library: app-managed local library implemented as **plain files in a user-choosable folder** (so iCloud/Dropbox/git sync is free later). |
| D11 | No networking/collab in MVP, but document model is **CRDT-compatible**: stable UUIDs, operation-based mutations (also powers undo/redo). |
| D12 | Performance targets: 120 Hz interaction on ProMotion, never below 60 Hz during pan/zoom/drag; boards of ~2,000 nodes + ~4,000 connectors + ~10 layers stay fluid; such a board opens < 1 s. |
| D13 | Pen hardware: iPad via Sidecar. Pressure + tilt reach Mac apps as system tablet events (verified; pressure-curve quirks are known — validate on real hardware early). |
| D14 | Storage: single-file document per board (package/bundle: JSON + assets + thumbnail), standard open/save/autosave. Local-only, no telemetry, no cloud. |
| D15 | Freehand→structure: on-demand "structurize" engine, with live stroke-end auto-recognition as a toggleable thin trigger on top. |
| D16 | **LLM integration is a core use case**, model-agnostic and subscription-driven (no API keys, no per-token billing). MVP: LLM-legible text interchange (copy canonical JSON + primer, import edited JSON back). Post-MVP: in-app agent surface via **MCP** (open standard; official Swift SDK verified: `modelcontextprotocol/swift-sdk`, client+server, stdio transport). Claude Desktop runs local MCP servers on all plans; ChatGPT supports MCP but **remote HTTPS servers only** (Plus/Team) — local-app bridging for ChatGPT is an open post-MVP question. Copy/paste interchange works with every chat product regardless. |
| D17 | **Minimal UI is a top priority co-equal with performance** (Excalidraw as the benchmark): near-empty first screen, one slim toolbar, contextual inspector (appears with selection), panels hidden by default, ⌘K + context menus as the deep surface, strong defaults instead of settings. Feature additions must not add persistent chrome. |
| D18 | Non-functional requirements adopted as testable constraints — see §9 (NFRs). |

## 3. MVP feature list

**Canvas & interaction**
- Infinite canvas: pan (trackpad scroll/drag), zoom (pinch/⌘±/scroll-modifier), zoom-to-fit, zoom-to-selection.
- Create structured blocks directly (double-click, toolbar, or command palette); text label editing in place.
- Select (click, rubber-band, shift-add), drag, resize with handles, duplicate, delete.
- Snapping & alignment guides (edges, centers, equal spacing), optional grid.
- Full undo/redo across every mutation, stable across save/load.
- Keyboard shortcuts for all common actions; command palette (⌘K) for create/insert/search/toggle-layer.

**Blocks & semantics**
- Block = semantic entity (kind, name, tags, key/value properties) + presentation (geometry, style). Built-in kinds: service, database, queue/topic, cache, gateway/LB, client, external system, generic.
- Annotations: free text notes, ink annotations.

**Connectors**
- Drag from block edge (or draw a line with pen/mouse between two blocks) → semantic edge, attached to anchor points, stays attached when blocks move or resize.
- Edge label + well-known-key badges (protocol, data, condition, direction). Arrowheads, direction, bidirectional.
- Routing: straight and orthogonal with obstacle-avoiding elbow routing (basic), manually adjustable waypoints.

**Freehand & sketch→structure**
- Pressure-sensitive ink (Sidecar pencil, mouse/trackpad fallback), smooth low-latency strokes.
- Structurize: select ink → convert; recognition of closed shapes (rectangle/ellipse/diamond), lines/arrows between existing blocks (→ connectors), text via double-click replacement.
- Live recognition on stroke-end, toggleable.

**Layers**
- Create/rename/show/hide/lock/duplicate layers; per-layer tint/opacity option for "focus mode".
- Objects belong to ≥1 layer; layer panel shows membership; quick "assign selection to layer".
- Active-layer set determines where new objects land (visible indicator).

**Library**
- Save board / selection / group as library entry with name, tags, auto-thumbnail.
- Browse, search (name/tag), insert (drag from panel or via ⌘K), update entry, delete, organize into folders.

**Files & persistence**
- Document package per board; autosave; crash-safe; versioned schema with tolerant reading.
- Export PNG (1x/2x, selection or board), SVG, native JSON.

**LLM interchange (phase 1)**
- **Copy for LLM** (board or selection): canonical, deterministic, human-readable JSON prefixed with a short format primer — paste into any chat (Claude, ChatGPT, …) to ask questions, analyze, or request edits.
- **Import LLM output**: paste/import JSON back with validation and clear error reporting; lands as a new board or inserted selection. (Reviewable structured diff of changes: post-MVP.)
- Canonical serialization (stable key order, stable ID scheme, minimal noise) so LLM edits and git diffs stay small and legible.

**Onboarding**
- Empty-board hint overlay + a built-in "example system" board; shortcut cheat-sheet (⌘/). No manual required.

## 4. Non-goals (MVP)

- Real-time collaboration, comments, accounts, any networking.
- In-app agent integration (MCP server, chat panel, agent actions) — first post-MVP roadmap item; MVP prepares the architecture (operation layer + canonical format) but ships only text interchange.
- Direct LLM API calls / bundled API keys — by design (subscription-driven, model-agnostic).
- Windows/Linux/web/iPad app (iPad is an *input device* only).
- Auto-layout of whole diagrams; Mermaid/PlantUML/DOT *import* (they need layout engines).
- Typed/validated semantic schemas, model checking, C4 conformance.
- Mac App Store distribution, notarization, auto-update.
- Import of Lucidchart/Miro/Figma native files (no stable public formats).
- Presentation mode, slide export, embedding servers.

## 5. Import/export matrix

Verified against current public documentation where noted; nothing below assumes an unverified API.

| Format | Import | Export | Semantic structure preserved? | Known limitations | Complexity |
|---|---|---|---|---|---|
| **Native JSON package** | MVP | MVP | Full | Ours to define; versioned, unknown-field-tolerant | Low |
| **LLM text (canonical JSON + format primer)** | **MVP** (paste/import with validation) | **MVP** (copy board/selection) | Full | Same schema as native JSON, canonicalized for LLM/diff legibility; works with any chat product via copy/paste | Low |
| **PNG** | Later (as embedded image) | **MVP** | No (optionally embed native JSON in metadata later, as Excalidraw does with iTXt) | Raster only | Low (CoreGraphics) |
| **SVG** | Not planned | **MVP** | Partial (can emit semantic `data-*` attributes) | No system SVG *writer* on macOS — we hand-generate the XML (straightforward for our primitives). Ink exported as paths | Medium |
| **PDF** | Not planned | Later (cheap) | No | Vector-faithful; CoreGraphics writes PDF natively | Low |
| **Excalidraw .excalidraw** | Later (first import target) | Later | Partial | Open, documented JSON (type `excalidraw`, version 2, elements array; separate `.excalidrawlib` for libraries). No layers, no typed edge semantics → import as sketch-ish elements; export drops layers/semantics into text | Medium |
| **draw.io .drawio** | Later | Not planned | Partial | XML `mxfile`; content is often **deflate+Base64 compressed** inside `<diagram>` — must inflate first. Style mapping is messy; layers exist and map to ours | Medium-high |
| **Mermaid** | Not supported | Later | Nodes/edges yes; positions/layers lost (Mermaid auto-layouts) | Export of structured graph → flowchart DSL is clean; import would require parsing + a layout engine | Export: low-medium. Import: high |
| **PlantUML / Graphviz DOT** | Not supported | Maybe later | Same profile as Mermaid | Text DSLs; export easy, import needs layout | Export: low. Import: high |
| **Lucidchart / Miro / Figma-FigJam** | Not supported | Not supported | — | Proprietary; no stable public file formats | — |

## 6. Architecture recommendation

**Stack: native Swift.** SwiftUI for app chrome (panels, inspector, library, palette, settings); **AppKit `NSView` canvas** with a Core Animation–based renderer; Metal kept as an upgrade path, not a day-one dependency.

Why native (vs Tauri/Electron/web canvas): macOS-only is confirmed permanent (D3), and the #1 requirement is input latency and frame consistency under trackpad/pencil — exactly where native wins for free: `NSEvent` tablet/pressure events, momentum scrolling, pinch phases, display-link-driven rendering, ProMotion pacing, and 10× lower idle footprint. The costs of native (no web ecosystem, macOS-only) are costs we've explicitly accepted.

**Rendering strategy (the performance core):**
- Scene graph in memory; canvas renders **only the visible viewport** with spatial indexing (R-tree/quadtree) for culling and hit-testing.
- During pan/zoom gestures: apply **Core Animation transforms** to already-rendered content tiles (GPU-composited, effortless 120 Hz), re-rasterize tiles asynchronously at the new scale. This is the proven "feels instant" pattern (Maps-style).
- During drags: dirty-region invalidation; dragged objects lifted onto their own layer.
- Live ink: dedicated stroke layer, points appended incrementally, no full redraws mid-stroke.
- Budget test in CI-ish form: scripted 2k-node board, automated pan/zoom, assert frame pacing.

**Module layout (SwiftPM packages, app target on top):**
- `DesignerModel` — pure Swift document model, operations, undo, no UI imports. Heavily unit-tested.
- `DesignerPersistence` — package read/write, schema versioning/migration, autosave. Unit-tested with fixture files.
- `DesignerRecognition` — stroke → shape/connector recognition (pure functions over point arrays; geometric heuristics: closure detection, corner counting, fit-to-primitive error). Unit-tested with recorded stroke fixtures.
- `DesignerInterop` — exporters (PNG/SVG, later PDF/Mermaid), importers (later Excalidraw/draw.io). Golden-file tests.
- `DesignerCanvas` — AppKit rendering + input.
- `DesignerApp` — SwiftUI shell, panels, palette, library UI.

**Agent-readiness (built into the MVP architecture, shipped post-MVP):**
- The **operation layer is the single mutation API** — UI gestures, the structurize engine, importers, and (later) agents all mutate documents through the same operations. An agent's edits are therefore undoable, autosaved, and reviewable for free.
- Elements have **stable UUIDs plus semantic names**, so a model can address "the edge from `api-gateway` to `orders-db`" reliably.
- Post-MVP shape: an in-app **MCP server** (official Swift SDK, `modelcontextprotocol/swift-sdk`) exposing tools like `read_board`, `query_elements`, `apply_operations`, `export_view`. Claude Desktop connects to local MCP servers directly (all plans; stdio shim bridging to the running app via local socket/XPC). ChatGPT currently requires remote HTTPS MCP servers — bridging option TBD; copy/paste interchange covers it meanwhile.

## 7. Data model proposal

Semantic and presentation are separate on every element; all mutations are **operations** (apply/invert) → one mechanism for undo/redo, autosave dirtiness, and future CRDT.

```
Document
├─ schemaVersion, id (UUID), title, createdAt/modifiedAt
├─ layers: [Layer]            // id, name, colorTint, isVisible, isLocked, order
├─ elements: [Element]        // one flat table, z-order via fractional sortKey
│   Element (enum by role)
│   ├─ common: id (UUID), layerIds: Set<LayerID> (≥1), sortKey, groupId?
│   ├─ Node:   semantic { kind, name, tags, properties [String:String] }
│   │          presentation { frame, style }
│   ├─ Edge:   semantic { label, properties (well-known keys), direction }
│   │          presentation { routing, waypoints, style }
│   │          endpoints: (from: Anchor, to: Anchor)   // Anchor = elementId + side/offset, or free point
│   ├─ Ink:    stroke points (x, y, pressure, t), style   // convertible, no semantics
│   └─ Note:   text annotation
├─ groups: [Group]            // id, name, memberIds
└─ assets/                    // images etc., stored beside document.json in the package
```

- **Well-known edge keys**: `protocol`, `data`, `condition`, `direction`, `ownership`, `latency`, `trust-boundary`, `failure-mode` — rendered as badges; arbitrary keys allowed.
- **File format**: document is a directory package `MyBoard.designerboard/` containing `document.json`, `assets/`, `thumbnail.png`. JSON keeps unknown fields on round-trip (version tolerance); `schemaVersion` + explicit migration functions.
- **Library entry** = the same package format + `entry.json` (name, tags, dates) in a user-chosen library folder the app indexes.

## 8. Implementation milestones (vertical slices)

Each slice ends runnable + tested. Order front-loads the risky bits (canvas performance, recognition).

| # | Slice | Contents | Exit criteria |
|---|---|---|---|
| M0 | Skeleton + persistence | Xcode project, packages, document open/save/autosave, versioned JSON round-trip | Round-trip + migration tests green; app opens/saves an empty board |
| M1 | Canvas core | Pan/zoom at target frame rate, block creation, select/drag/resize, in-place labels, undo/redo, spatial index | 2k-node synthetic board pans/zooms without dropped frames (measured); all ops undoable |
| M2 | Connectors | Drag-to-connect, anchoring, attachment under move/resize, labels + well-known keys, straight+orthogonal routing | Connector torture test (move/resize/undo storms) green; visual QA |
| M3 | Ink + structurize | Low-latency ink, Sidecar pressure validation, on-demand structurize, live recognition toggle | Recorded-stroke fixture suite ≥90% on target shapes; pencil latency acceptable in hands-on test |
| M4 | Layers | Multi-membership, panel, show/hide/lock/duplicate, active-layer rule, focus mode | Same-object-two-layers scenarios correct incl. hit-testing on hidden/locked layers |
| M5 | Library | Save selection/board as entry, browse/search/tags, insert, update | Library round-trip tests; insert lands on active layers with fresh UUIDs |
| M6 | Export + LLM interchange + polish | PNG/SVG export, **Copy for LLM / import-back with validation**, snapping/alignment, ⌘K palette, shortcuts, onboarding overlay + example board, perf hardening | SVG golden-file tests; LLM round-trip test suite (incl. malformed-input handling); export visually faithful; onboarding self-explanatory to a fresh user |

**Post-MVP roadmap (ordered):** R1 in-app agent surface via MCP (read/query/edit the live board from Claude Desktop et al.) → R2 Excalidraw import → R3 PDF + Mermaid export → R4 structured LLM-edit review diff → R5 draw.io import.

## 9. Non-functional requirements

Each is a testable constraint; regressions against P-, R-, and U-class NFRs are release blockers.

**Performance & efficiency**
- P1. 120 Hz on ProMotion during pan/zoom/drag/draw; never below 60 Hz (D12 board sizes).
- P2. Cold launch to interactive < 2 s; document open < 1 s (D12 board).
- P3. Memory < ~500 MB with the D12 board open; no unbounded growth in long sessions.
- P4. Zero CPU/GPU work when idle (render on demand, no polling) — app should not appear in Activity Monitor's high-energy list while sitting open.

**Reliability & data safety**
- R1. Crash or force-quit loses ≤ 5 s of work; document writes are atomic (never a half-written/corrupt package).
- R2. Any schema-vN file opens in all later versions; unknown fields survive round-trip; migrations are tested with fixture files.
- R3. Undo depth ≥ 200 steps per document per session; undo/redo never corrupts state.
- R4. Malformed input (LLM paste, hand-edited JSON, truncated files) is rejected with a precise error, never a crash or silent partial import.

**Usability & minimal UI**
- U1. First-run screen: canvas + one slim toolbar + menu bar, nothing else visible. Panels (layers, library, inspector) appear only when invoked or contextually relevant.
- U2. Every command is reachable via ⌘K; all common actions have shortcuts; the app is fully keyboard-operable for creation/editing workflows.
- U3. New-engineer onboarding ≤ 5 min to first labeled, connected, layered diagram — without documentation.
- U4. Respects system appearance (light/dark), Reduce Motion, and standard macOS text editing/IME behavior in labels.

**Privacy & security**
- S1. MVP makes **zero network calls** (verifiable with a proxy); no telemetry, no analytics. Data leaves the machine only via explicit user export/copy.
- S2. Hardened runtime enabled; documents and library are plain user-readable files (no lock-in).
- S3. When the MCP agent surface ships: local-only by default, explicit per-board consent, agent edits visibly attributed and undoable.

**Maintainability**
- M1. Model, persistence, recognition, and interop packages have no UI dependencies and run their test suites headless via `xcodebuild test` / `swift test`.
- M2. Golden-file tests for every exporter/importer; recorded-stroke fixtures for recognition; performance smoke test scripted against the D12 synthetic board.
- M3. Canonical serialization keeps documents git-diff-friendly (stable ordering, one semantic change ≈ one small diff).

## 10. Acceptance criteria (MVP done =)

1. **Feel**: no visible frame drops during pan/zoom/drag/draw on a 2k-node/4k-edge/10-layer board on an Apple-silicon Mac; board opens < 1 s.
2. **Sketch→structure**: drawing a rough box and a rough arrow between two boxes produces two blocks and one attached connector, editable, in one gesture each (live mode).
3. **Connectors**: never detach under move/resize/undo/group operations; labels and badges render at all zoom levels.
4. **Layers**: the same object toggles across concerns without duplication; hidden layers don't hit-test; locked layers don't edit.
5. **Library**: save selection → find by tag → insert into another board, under 10 seconds of user effort.
6. **Persistence**: kill -9 during editing loses at most a few seconds of work; files from schema v1 always open in later versions.
7. **Undo**: every mutation in the app is undoable/redoable with correct results, including recognition conversions.
8. **Export**: PNG and SVG output matches the board visually; what's lost (semantics in PNG) is documented in the export sheet.
9. **Onboarding**: a new engineer creates blocks, connects them, labels a protocol, and toggles a layer within ~5 minutes, no docs.
10. **LLM round-trip**: copy a board with "Copy for LLM", have Claude or ChatGPT (real subscription session) add a component and reroute an edge, paste the result back — imports cleanly, semantics intact; garbage input produces a precise error, never a crash.
11. **Minimal UI**: first-run screen shows canvas + one toolbar + menu bar only; no persistent chrome was added by any MVP feature.

## 11. Open questions

1. **App name** ("Designer" is a placeholder).
2. **Sidecar pressure curve** — verified that pressure/tilt reach Mac apps, but the system pressure curve is reportedly heavy; if it feels bad on your iPad we may add an in-app pressure curve adjustment. Validate in M3.
3. **PDF export** is nearly free with CoreGraphics — pull into MVP (M6) or keep post-MVP? Default: keep post-MVP unless M6 has slack.
4. **Excalidraw import** — early post-MVP interop target (R2). Do you have existing diagrams (Excalidraw or draw.io) you'd want migrated? That would reprioritize.
5. **ChatGPT ↔ local app bridging** (post-MVP): ChatGPT's MCP support requires remote HTTPS servers, unlike Claude Desktop's local support. Options when R1 lands: local HTTPS endpoint + tunnel, a small hosted relay, or accept copy/paste for ChatGPT. No decision needed now.
