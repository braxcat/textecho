#!/bin/bash
# Rebuild and deploy TextEcho in one command.
# Run from anywhere — it finds the project automatically.
#
# Usage:
#   ./rebuild.sh           # Normal rebuild
#   ./rebuild.sh --clean   # Full clean rebuild
#   ./rebuild.sh --uninstall  # Uninstall first, then rebuild fresh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="TextEcho"
APP_PATH="/Applications/${APP_NAME}.app"

# Parse args
CLEAN=""
UNINSTALL=false
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN="--clean" ;;
        --uninstall) UNINSTALL=true ;;
    esac
done

# Uninstall first if requested
if [ "$UNINSTALL" = true ]; then
    echo "==> Running uninstall first..."
    bash "$SCRIPT_DIR/uninstall.sh"
    echo ""
fi

# Kill running instance
echo "==> Stopping TextEcho..."
killall "$APP_NAME" 2>/dev/null || true
sleep 1

# Pull latest code
echo "==> Pulling latest code..."
git pull 2>/dev/null || echo "    (git pull skipped — not on a branch or no remote)"

# Build
echo "==> Building..."
./build_native_app.sh $CLEAN

# Deploy
echo "==> Deploying to /Applications..."
rm -rf "$APP_PATH"
cp -R "dist/${APP_NAME}.app" "$APP_PATH"

# Launch
echo "==> Launching TextEcho..."
open "$APP_PATH"

echo ""
echo "=== Done! TextEcho is running. ==="
echo ""
echo "If permissions need re-granting, check System Settings → Privacy & Security."
