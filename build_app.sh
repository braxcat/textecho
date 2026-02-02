#!/bin/bash
#
# Build Dictation-Mac as a standalone .app bundle using py2app.
#
# Prerequisites:
#   pip install py2app
#
# Usage:
#   ./build_app.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Cleaning previous build..."
rm -rf build dist

echo "==> Building .app bundle with py2app..."
python setup.py py2app

APP_PATH="dist/Dictation.app"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Build failed — $APP_PATH not found"
    exit 1
fi

# Make overlay helper executable (if included)
OVERLAY_HELPER="$APP_PATH/Contents/Resources/DictationOverlay/DictationOverlayHelper"
if [ -f "$OVERLAY_HELPER" ]; then
    echo "==> Setting overlay helper permissions..."
    chmod +x "$OVERLAY_HELPER"
fi

# MLX is a namespace package with native extensions (.so, .dylib).
# py2app zips the .pyc files and puts .so in lib-dynload/ but misses:
#   1. libmlx.dylib + mlx.metallib (needed by core.so at @loader_path/lib)
#   2. Some .py modules the scanner doesn't find (_reprlib_fix, extension)
# Copy these from the venv as a post-build fixup.
MLX_DYNLOAD="$APP_PATH/Contents/Resources/lib/python3.12/lib-dynload/mlx"
MLX_VENV=".venv/lib/python3.12/site-packages/mlx"
if [ -d "$MLX_DYNLOAD" ] && [ -d "$MLX_VENV" ]; then
    echo "==> Fixing up MLX package in bundle..."
    # Native libraries (core.so loads libmlx.dylib via @loader_path/lib)
    mkdir -p "$MLX_DYNLOAD/lib"
    cp "$MLX_VENV/lib/libmlx.dylib" "$MLX_DYNLOAD/lib/"
    cp "$MLX_VENV/lib/mlx.metallib" "$MLX_DYNLOAD/lib/" 2>/dev/null || true
    # Missing Python modules — copy to lib-dynload/mlx/ so they're on sys.path
    for mod in _reprlib_fix.py extension.py; do
        if [ -f "$MLX_VENV/$mod" ]; then
            cp "$MLX_VENV/$mod" "$MLX_DYNLOAD/"
        fi
    done
    echo "    Done"
fi

# Create libsndfile.dylib symlink in Frameworks (soundfile's fallback expects this name)
SNDFILE_ARM="$APP_PATH/Contents/Frameworks/libsndfile_arm64.dylib"
SNDFILE_LINK="$APP_PATH/Contents/Frameworks/libsndfile.dylib"
if [ -f "$SNDFILE_ARM" ] && [ ! -f "$SNDFILE_LINK" ]; then
    echo "==> Creating libsndfile.dylib symlink..."
    ln -s "libsndfile_arm64.dylib" "$SNDFILE_LINK"
fi

echo "==> Attempting ad-hoc code signing..."
# Clear extended attributes first
xattr -rc "$APP_PATH" 2>/dev/null || true

if codesign --force --deep --sign - "$APP_PATH" 2>/dev/null; then
    echo "    Code signing succeeded"
else
    echo "    Code signing skipped (com.apple.provenance xattrs on newer macOS)"
    echo "    The app will still work — right-click → Open on first launch"
fi

echo ""
echo "==> Build complete!"
echo "    $APP_PATH"
echo ""
echo "To test:"
echo "    open dist/Dictation.app"
echo ""
echo "To create a DMG installer:"
echo "    ./build_dmg.sh"
