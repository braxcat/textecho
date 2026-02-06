#!/bin/bash
# Create a DMG for the native Swift TextEcho app.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="TextEcho"
APP_PATH="dist/${APP_NAME}.app"
DMG_NAME="TextEcho"
DMG_PATH="dist/${DMG_NAME}.dmg"
STAGING_DIR="dist/dmg-staging"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: $APP_PATH not found. Run ./build_native_app.sh first."
    exit 1
fi

echo "==> Preparing DMG staging area..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

ditto "$APP_PATH" "$STAGING_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH"

echo "==> Creating DMG..."
hdiutil create \
    -volname "$DMG_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "==> DMG created: $DMG_PATH"
