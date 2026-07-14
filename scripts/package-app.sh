#!/bin/bash
# Builds an optimized Designer.app and zips it for moving to another Mac.
#
#   scripts/package-app.sh
#
# Output: build/Designer.zip
#
# The app is ad-hoc signed (no Developer ID), so on the destination Mac,
# Gatekeeper will object on first launch. Either:
#   - Right-click Designer.app → Open → Open   (macOS 14 and earlier), or
#   - Launch once, then System Settings → Privacy & Security → "Open Anyway"
#     (macOS 15+), or
#   - Clear quarantine up front:  xattr -dr com.apple.quarantine Designer.app
# For the in-app assistant on the destination Mac, also install Claude Code:
#   npm install -g @anthropic-ai/claude-code   (then run `claude` and log in)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-app.sh" release

echo "▸ zipping"
ditto -c -k --keepParent "$ROOT/build/Designer.app" "$ROOT/build/Designer.zip"
echo "✓ $ROOT/build/Designer.zip"
echo "  Copy to the other Mac, unzip into /Applications, then right-click → Open"
echo "  (or: xattr -dr com.apple.quarantine /Applications/Designer.app)"
