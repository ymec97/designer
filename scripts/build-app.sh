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

# Version stamping: VERSION file is the source of truth; the build number is
# the commit count (monotonic), and DesignerBuildInfo carries date + sha.
APP_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP_BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
APP_BUILD_INFO="$(date +%Y-%m-%d) $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"
sed -e 's/$(EXECUTABLE_NAME)/Designer/g' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.yarden.designer/g' \
    -e 's/$(DEVELOPMENT_LANGUAGE)/en/g' \
    -e "s/\$(APP_VERSION)/$APP_VERSION/g" \
    -e "s/\$(APP_BUILD)/$APP_BUILD/g" \
    -e "s/\$(APP_BUILD_INFO)/$APP_BUILD_INFO/g" \
    "$ROOT/App/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ROOT/App/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_PATH/Designer" "$APP/Contents/MacOS/Designer"

echo "▸ codesign (ad hoc)"
codesign --force --sign - "$APP"

echo "✓ $APP"
