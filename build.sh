#!/bin/bash
set -e

DERIVED=$(xcodebuild -project ScreeMy.xcodeproj -scheme ScreeMy -configuration Debug \
    -showBuildSettings 2>/dev/null | awk '/^ *BUILT_PRODUCTS_DIR /{print $3}')

echo "Building..."
xcodebuild -project ScreeMy.xcodeproj -scheme ScreeMy -configuration Debug build \
    -quiet 2>&1 | grep -E "error:|BUILD" || true

echo "Copying app..."
rm -rf ScreeMy.app
cp -R "$DERIVED/ScreeMy.app" ScreeMy.app

echo "Signing with stable bundle-ID requirement..."
codesign --force --deep --sign - \
    --requirements '=designated => identifier "fi.screemy.app"' \
    ScreeMy.app

echo "Done. Launch with: open ScreeMy.app"
