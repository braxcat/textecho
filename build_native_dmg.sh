#!/bin/bash
# Create a DMG for the native Swift TextEcho app.
# With --sign: signs the DMG with Developer ID, notarizes with Apple, and staples the ticket.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="TextEcho"
APP_PATH="dist/${APP_NAME}.app"
DMG_NAME="TextEcho"
DMG_PATH="dist/${DMG_NAME}.dmg"
STAGING_DIR="dist/dmg-staging"
SIGN_MODE="none"

for arg in "$@"; do
    case "$arg" in
        --sign) SIGN_MODE="developer" ;;
    esac
done

if [ "$SIGN_MODE" = "developer" ]; then
    if [ -z "$DEVELOPER_ID" ]; then
        echo "ERROR: --sign requires DEVELOPER_ID env var."
        exit 1
    fi
    # Notarization requires ASC API key
    if [ -z "$ASC_API_KEY_PATH" ] || [ -z "$ASC_KEY_ID" ] || [ -z "$ASC_ISSUER_ID" ]; then
        echo "ERROR: --sign requires ASC_API_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID env vars for notarization."
        exit 1
    fi
fi

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

if [ "$SIGN_MODE" = "developer" ]; then
    echo "==> Signing DMG with Developer ID..."
    codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG_PATH"

    echo "==> Submitting for notarization (App Store Connect API key)..."
    xcrun notarytool submit "$DMG_PATH" \
        --key "$ASC_API_KEY_PATH" \
        --key-id "$ASC_KEY_ID" \
        --issuer "$ASC_ISSUER_ID" \
        --wait

    echo "==> Stapling notarization ticket..."
    xcrun stapler staple "$DMG_PATH"

    echo "==> DMG signed + notarized: $DMG_PATH"
else
    echo "==> DMG created (unsigned): $DMG_PATH"
fi
