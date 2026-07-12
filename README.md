# Designer

A native macOS app for engineering system design: sketch at whiteboard speed,
keep the result as a structured, reusable, LLM-legible artifact.

Full product definition, decisions, and roadmap: [docs/PRODUCT_BRIEF.md](docs/PRODUCT_BRIEF.md).

## Requirements

- macOS 14+, Xcode 16+ (built against Xcode 26)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

If `xcodebuild` complains about Command Line Tools, either run
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` once, or
prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Build & run

Primary (SwiftPM, no Xcode project needed):

```sh
scripts/build-app.sh              # → build/Designer.app
open build/Designer.app
```

Alternative (Xcode IDE):

```sh
xcodegen generate                 # project.yml → Designer.xcodeproj
open Designer.xcodeproj
```

Note: `xcodebuild` (and therefore Xcode-based building) requires Xcode's
one-time component install, which needs admin rights:
`sudo xcodebuild -runFirstLaunch`. The SwiftPM script works without it.

## Tests

```sh
cd DesignerKit && swift test    # unit suite (model, persistence, canvas math)
```

End-to-end checks built into the app binary (no permissions or UI scripting needed):

```sh
# Real NSDocument pipeline: create → mutate → save → reopen → verify
build/Designer.app/Contents/MacOS/Designer --smoke-test /tmp/out.designerboard

# Frame pacing on a synthetic 2,000-node board (M1/D12 criterion):
# scripted pan + zoom phases, fails if >2% frames drop
build/Designer.app/Contents/MacOS/Designer --perf-test
```

## Layout

| Path | What |
|---|---|
| `DesignerKit/Sources/DesignerModel` | Pure document model: board, elements, layers, sort keys. No UI imports. |
| `DesignerKit/Sources/DesignerPersistence` | Canonical JSON, schema migrations, `.designerboard` package I/O. |
| `App/` | AppKit/SwiftUI app shell (NSDocument-based). |
| `project.yml` | XcodeGen definition — `Designer.xcodeproj` is generated, don't edit it. |
| `docs/` | Product brief and design docs. |

## Status

Milestone M4 (layers) — see the brief's §8 for the roadmap.
Done: document model, versioned persistence, operation layer with undo/redo,
canvas with pan/zoom/select/drag/resize/create/label-edit, and semantic
connectors (border-drag to connect, auto-anchoring that survives move/resize/
undo storms, straight + orthogonal routing, label/protocol/data/condition
badges, popover editor, cascade delete) — fluid at 2k nodes + 4k edges.
Freehand ink (mouse/trackpad + tablet pressure), geometric stroke recognition (rectangle/ellipse/diamond/line), live sketch-to-structure conversion, ⌘R structurize.
Layers: floating panel (⌘L), multi-membership, active layer, show/hide/lock/tint/duplicate/reorder, focus mode dimming.
Next: M5 library.
