#!/bin/bash
set -e

VERSION=${1:-"1.0.0"}
DMG_NAME="ScreeMy-${VERSION}.dmg"

echo "Building ScreeMy ${VERSION} (Release)..."

DERIVED=$(xcodebuild -project ScreeMy.xcodeproj -scheme ScreeMy -configuration Release \
    -showBuildSettings 2>/dev/null | awk '/^ *BUILT_PRODUCTS_DIR /{print $3}')

xcodebuild -project ScreeMy.xcodeproj -scheme ScreeMy -configuration Release build \
    -quiet 2>&1 | grep -E "error:|BUILD" || true

echo "Copying app..."
rm -rf ScreeMy.app
cp -R "$DERIVED/ScreeMy.app" ScreeMy.app

echo "Signing..."
codesign --force --deep --sign - \
    --requirements '=designated => identifier "fi.screemy.app"' \
    ScreeMy.app

echo "Creating DMG..."
rm -f "$DMG_NAME"

create-dmg \
    --volname "ScreeMy" \
    --volicon "ScreeMy.icns" \
    --window-pos 200 120 \
    --window-size 540 380 \
    --icon-size 120 \
    --icon "ScreeMy.app" 140 190 \
    --hide-extension "ScreeMy.app" \
    --app-drop-link 400 190 \
    --no-internet-enable \
    "$DMG_NAME" \
    ScreeMy.app

echo ""
echo "Done: $DMG_NAME"
