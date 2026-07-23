# Test plan — connector clutter: anchors, caption modes, selection fixes

**Branch:** `claude/diagram-connector-clutter-uioc6l`
**Tip at handoff:** `48148a5` (base `222dbb0` on `main`)
**Authored in:** a Claude Code on the web (Linux) session — **not compiled or
run** there (no Xcode toolchain). Everything below must be executed on a Mac
with Xcode before merge.

> Handoff to a Mac agent: run the release battery, then the feature checks.
> If anything fails, fix on **this same branch**, re-run the battery, and push.

---

## 1. Release battery (must be 0 failures)

Run from the repo root with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` set.

```sh
cd DesignerKit && swift test                                   # full unit suite
cd .. && scripts/build-app.sh                                  # build build/Designer.app
./build/Designer.app/Contents/MacOS/Designer --ui-test         # expect: UI-TEST PASS
./build/Designer.app/Contents/MacOS/Designer --smoke-test /tmp/smoke.designerboard
caffeinate -u -t 5; caffeinate -dimsu ./build/Designer.app/Contents/MacOS/Designer --perf-test
./build/Designer.app/Contents/MacOS/Designer --agent-test      # live MCP round-trip
```

Notes:
- `--perf-test` needs the display awake and **not** on battery / Low Power Mode
  (macOS throttles the refresh rate → false frame-time failures). Plug in and
  re-run; that failure is environmental, not a regression.
- If a stale incremental build fails linking with phantom symbol errors after
  the `Style`/model changes, run `swift package clean` and rebuild.

The new `--ui-test` PASS line ends with:
`… style-panel-polish, caption-mode+density-nudge, rubber-band-precise, endpoint-slot-snap, linked-boards verified`

---

## 2. Automated tests added / changed

**Unit — `DesignerKit/Tests/DesignerModelTests/`**
- `EdgeGeometryTests.swift`
  - `testAnchorSlotsCoverEveryFace` — 12 slots, all on the border.
  - `testNearestAnchorSlotSnapsToTheClosestFacePoint` — right/top/left snapping.
  - `testRouteIntersectionIgnoresBoundingBoxGaps` — bbox overlaps but the line
    doesn't; a band on the midpoint does.
- `CaptionModeTests.swift` (new) — default `.always`, `extra` round-trip,
  unknown-value fallback, JSON encode/decode.

**UI driver — `DesignerKit/Sources/Designer/UITest.swift`**
- `step30CaptionModeAndDensityNudge` — banner fires once past the threshold and
  not again; caption mode cycles Always→On Focus→Off→Always.
- `step31RubberBandExcludesDistantConnector` — band in empty diagonal space does
  not grab the connector; band on the line does; partial node overlap still selects.
- `step32EndpointSnapsToDiscreteSlot` — dragging an endpoint onto a block pins a
  discrete `(side, offset)` slot (top face when dragged toward the top edge).
- `step28StylePanelPolish` — updated: undoing a fresh shape now **hides** the
  style panel (empty selection), and deselecting a connector hides it.

---

## 3. Manual verification in the app (`build/Designer.app`)

### Feature — relocatable anchor points
1. Draw two blocks, connect them. The connector attaches to the facing side's
   near point (default, unchanged). Add 2–3 more parallel connectors → they
   fan out automatically (anchorSpread preserved).
2. Select one connector, grab an endpoint grip, drag it around the block.
   **Expect:** candidate anchor dots appear on the block; the endpoint snaps
   between discrete points (3 per face); the highlighted dot is where it lands.
3. Drop it on a different face. **Expect:** it stays pinned there (does not
   re-auto-pick), and that endpoint no longer participates in auto fan-out.
4. Drag the endpoint off the block onto empty canvas → it detaches (dangles),
   as before. Undo/redo restores each step.

### Feature — caption visibility mode + density nudge
1. **View ▸ Connector Captions** shows Always / On Focus / Off with a checkmark
   on the current mode.
2. **On Focus:** labels disappear except for the selected connector; hovering a
   connector reveals its label; isolating a flow keeps only that flow's labels.
3. **Off:** no connector captions anywhere.
4. **Always:** all captions (current default behavior).
5. Mode persists across save/reload (stored in board.json `extra`) and undoes.
6. Export PNG/SVG honors the mode (Off hides captions; On Focus/Always show all).
7. **Density nudge:** open/build a board with ≥ 40 connectors while in Always
   mode → a floating banner suggests On Focus. "Switch to On Focus" applies it;
   "Dismiss" closes it. It must **not** re-appear when you add more connectors,
   and must not appear on boards already in On Focus/Off.

### Fix — rubber-band selection precision
1. Zoom in with a long diagonal connector partly on screen. Drag a selection
   rectangle over empty space that the connector's bounding box spans but the
   line does not cross. **Expect:** the connector is **not** selected.
2. Drag a rectangle that actually crosses the connector line → it **is** selected.
3. Partial overlap of a shape still selects it (unchanged, intended).

### Fix — style panel visibility
1. Select a shape → style panel shows. Deselect (click empty canvas) → panel
   **hides**.
2. Select a connector → panel shows connector controls. Deselect → panel hides
   (does **not** revert to shape mode).
3. Draw a shape then undo → panel hides (empty selection). With the shape/pencil
   tool active, the panel still shows its pending style (unchanged).

---

## 4. Risk areas to scrutinize (unverified by a compiler in cloud)

- **Swift build**: the change was never compiled. Watch for tuple-label
  coercion and optional-pattern (`if case … ? =`) issues in
  `EdgeGeometry.anchorSlots`/`nearestAnchorSlot` and `Board+Captions.swift`.
- **`drawEdge(emphasized:)` default = true**: overlays that draw edges outside
  the main pass (agent-proposal ghost review, flow-recording candidates) rely on
  the default and will therefore hide captions only in **Off** mode. Confirm
  that's acceptable (it's consistent, but eyeball the flow recorder in Off).
- **Density "shown once"** persists in `UserDefaults` keyed by `board.id` (not in
  the document). Confirm it doesn't re-nag and doesn't dirty the board.
- **Far-zoom path**: captions are still gated below 0.35 scale; the new mode adds
  no per-node work there. Confirm `--perf-test` is unaffected.

---

## 5. If something fails

Fix on `claude/diagram-connector-clutter-uioc6l`, re-run the affected battery
step (and `swift package clean` if linking is flaky), then push. Do not merge to
`main` until the entire battery is green.
