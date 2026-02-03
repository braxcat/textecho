#!/bin/bash
#
# Create a DMG installer for TextEcho.
#
# Prerequisites:
#   ./build_app.sh (creates dist/TextEcho.app)
#
# Usage:
#   ./build_dmg.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="TextEcho"
APP_PATH="dist/${APP_NAME}.app"
DMG_NAME="TextEcho"
DMG_PATH="dist/${DMG_NAME}.dmg"
STAGING_DIR="dist/dmg-staging"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: $APP_PATH not found. Run ./build_app.sh first."
    exit 1
fi

echo "==> Preparing DMG staging area..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy app (ditto preserves code signatures and handles permissions correctly)
ditto "$APP_PATH" "$STAGING_DIR/${APP_NAME}.app"

# Create Applications symlink (drag-to-install)
ln -s /Applications "$STAGING_DIR/Applications"

# Remove old DMG if it exists
rm -f "$DMG_PATH"

echo "==> Creating DMG..."
hdiutil create \
    -volname "$DMG_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# Cleanup staging
rm -rf "$STAGING_DIR"

echo ""
echo "==> DMG created!"
echo "    $DMG_PATH"
echo ""
echo "To install:"
echo "    1. Double-click ${DMG_NAME}.dmg"
echo "    2. Drag TextEcho to Applications"
echo "    3. Right-click → Open (first launch only, bypasses Gatekeeper)"
