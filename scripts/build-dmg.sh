#!/bin/bash
# Builds SimpleRing.app in Release configuration and packages it as a
# drag-to-install .dmg in the app/ directory.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_DIR="app"
VERSION=$(grep MARKETING_VERSION "$APP_DIR/Config/Shared.xcconfig" | awk '{print $3}')
DMG_NAME="SimpleRing-${VERSION}.dmg"

echo "==> Building SimpleRing.app (Release, version ${VERSION})"
cd "$APP_DIR"
rm -rf build
xcodebuild -project SimpleRing.xcodeproj -scheme SimpleRing -configuration Release \
  -derivedDataPath build clean build

APP_PATH="build/Build/Products/Release/SimpleRing.app"
if [ ! -d "$APP_PATH" ]; then
  echo "error: build did not produce $APP_PATH" >&2
  exit 1
fi

echo "==> Packaging ${DMG_NAME}"
rm -rf dmg-staging "$DMG_NAME"
mkdir dmg-staging
cp -R "$APP_PATH" dmg-staging/
ln -s /Applications dmg-staging/Applications
hdiutil create -volname "SimpleRing" -srcfolder dmg-staging -ov -format UDZO "$DMG_NAME"
rm -rf dmg-staging

echo "==> Done: $APP_DIR/$DMG_NAME"
