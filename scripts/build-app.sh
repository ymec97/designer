#!/bin/bash
# Builds Designer.app without xcodebuild: SwiftPM compiles the executable,
# this script assembles and ad-hoc-signs the bundle.
#
#   scripts/build-app.sh [debug|release]
#
# Output: build/Designer.app
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "▸ swift build (${CONFIG})"
swift build --package-path "$ROOT/DesignerKit" --product Designer -c "$CONFIG"
BIN_PATH="$(swift build --package-path "$ROOT/DesignerKit" -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/Designer.app"
echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

sed -e 's/$(EXECUTABLE_NAME)/Designer/g' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.yarden.designer/g' \
    -e 's/$(DEVELOPMENT_LANGUAGE)/en/g' \
    "$ROOT/App/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ROOT/App/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_PATH/Designer" "$APP/Contents/MacOS/Designer"

echo "▸ codesign (ad hoc)"
codesign --force --sign - "$APP"

echo "✓ $APP"
