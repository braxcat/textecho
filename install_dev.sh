#!/bin/bash
# Build (debug) and deploy TextEcho for local development.
# Faster than a release build — use this during active development.
# Kills the running instance, deploys to /Applications, resets
# Accessibility permission, and relaunches.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="TextEcho"
APP_PATH="/Applications/${APP_NAME}.app"

# Kill running instance
echo "==> Stopping TextEcho..."
pkill -9 "$APP_NAME" 2>/dev/null && echo "    Killed." || echo "    (Not running.)"
sleep 0.5

# Build (debug — much faster incremental rebuilds)
echo "==> Building (debug)..."
./build_native_app.sh --debug

# Deploy
echo "==> Deploying to /Applications..."
rm -rf "$APP_PATH"
cp -R "dist/${APP_NAME}.app" "$APP_PATH"

# Reset Accessibility (signature changed, old grant is invalid)
echo ""
bash "$SCRIPT_DIR/reset_accessibility.sh"

# Launch
echo "==> Launching TextEcho..."
open "$APP_PATH"

echo ""
echo "=== Done! Grant Accessibility access when prompted. ==="
