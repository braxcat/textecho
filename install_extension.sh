#!/bin/bash
# Install the GNOME Shell extension for dictation window positioning

set -e

EXTENSION_UUID="dictation@local"
SOURCE_DIR="$(dirname "$0")/gnome-extension/$EXTENSION_UUID"
TARGET_DIR="$HOME/.local/share/gnome-shell/extensions/$EXTENSION_UUID"

echo "Installing GNOME Shell extension: $EXTENSION_UUID"

# Check source exists
if [ ! -d "$SOURCE_DIR" ]; then
    echo "Error: Source directory not found: $SOURCE_DIR"
    exit 1
fi

# Create target directory
mkdir -p "$TARGET_DIR"

# Copy files
cp "$SOURCE_DIR/extension.js" "$TARGET_DIR/"
cp "$SOURCE_DIR/metadata.json" "$TARGET_DIR/"

echo "Extension installed to: $TARGET_DIR"
echo ""
echo "To complete installation:"
echo "  1. Log out and log back in (required for Wayland)"
echo "     OR on X11: press Alt+F2, type 'r', press Enter"
echo ""
echo "  2. Enable the extension:"
echo "     gnome-extensions enable $EXTENSION_UUID"
echo ""
echo "  3. Verify it's running:"
echo "     gnome-extensions show $EXTENSION_UUID"
echo ""
echo "  4. Test it:"
echo "     python3 window_positioner.py"
