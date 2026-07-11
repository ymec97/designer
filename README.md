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
cd DesignerKit && swift test
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

Milestone M0 (skeleton + persistence) — see the brief's §8 for the roadmap.
