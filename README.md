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

## Package a release zip

One command builds an optimized, version-stamped app and zips it:

```sh
scripts/package-app.sh            # → build/Designer-v<version>-<date>.zip
```

The zip is ad-hoc signed (no Developer ID yet), so on another Mac,
Gatekeeper objects on first launch: unzip into /Applications, then
right-click → Open (macOS ≤14), use System Settings → Privacy & Security →
"Open Anyway" (macOS 15+), or clear quarantine up front with
`xattr -dr com.apple.quarantine /Applications/Designer.app`.

For the in-app assistant on that Mac, also install the Claude Code CLI
(`npm install -g @anthropic-ai/claude-code`, run `claude` once and log in).

## Tests

```sh
cd DesignerKit && swift test    # unit suite (model, geometry, persistence, recognition)
```

End-to-end checks built into the app binary (no permissions or UI scripting needed):

```sh
# Synthesized-event UI walk: create, connect, sketch, layers, flows, versions…
build/Designer.app/Contents/MacOS/Designer --ui-test

# Real NSDocument pipeline: create → mutate → save → reopen → verify
build/Designer.app/Contents/MacOS/Designer --smoke-test /tmp/out.designerboard

# Frame pacing on a synthetic 2,000-node + 4,000-edge board: scripted pan +
# zoom phases; fails if >2% frames drop below 60 Hz. Also reports raw draw
# cost against the 120 Hz budget. Needs the display awake.
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

**v0.1.0** — first testable release. The full feature set (canvas, sketch
recognition, semantic connectors, layers, flows with recorded playback,
traffic simulation, version history, MCP agent access + in-app Claude
assistant, library, exports, hand-drawn style) is listed in
[CHANGELOG.md](CHANGELOG.md); product definition and design decisions in
[docs/PRODUCT_BRIEF.md](docs/PRODUCT_BRIEF.md).
