#!/bin/bash
# Build TextEcho as a native Swift .app bundle and embed Python daemons.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="TextEcho"
APP_DIR="dist/${APP_NAME}.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

# SwiftPM and Clang cache dirs (avoid permission issues under sandboxed runs)
mkdir -p "$SCRIPT_DIR/.swiftpm-cache/config" \
         "$SCRIPT_DIR/.swiftpm-cache/cache" \
         "$SCRIPT_DIR/.swiftpm-cache/security" \
         "$SCRIPT_DIR/.clang-cache" \
         "$SCRIPT_DIR/.tmp"

export SWIFTPM_CONFIG_DIR="$SCRIPT_DIR/.swiftpm-cache/config"
export SWIFTPM_CACHE_DIR="$SCRIPT_DIR/.swiftpm-cache/cache"
export SWIFTPM_SECURITY_DIR="$SCRIPT_DIR/.swiftpm-cache/security"
export CLANG_MODULE_CACHE_PATH="$SCRIPT_DIR/.clang-cache"
export TMPDIR="$SCRIPT_DIR/.tmp"

echo "==> Building Swift app..."
swift build -c release --package-path mac_app

BIN_PATH="mac_app/.build/release/TextEchoApp"
if [ ! -f "$BIN_PATH" ]; then
    echo "ERROR: Swift build failed; binary not found at $BIN_PATH"
    exit 1
fi

echo "==> Creating .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/${APP_NAME}"
chmod +x "$MACOS_DIR/${APP_NAME}"

# Bundle a self-contained Python venv with required deps (cached for faster builds)
if [ -n "$PYTHON_BUNDLE_BIN" ]; then
    PYTHON_BIN="$PYTHON_BUNDLE_BIN"
else
    PYTHON_BIN="$(command -v python3.12 || true)"
    if [ -z "$PYTHON_BIN" ]; then
        PYTHON_BIN="$(command -v python3.11 || true)"
    fi
    if [ -z "$PYTHON_BIN" ]; then
        PYTHON_BIN="$(command -v python3 || true)"
    fi
fi

if [ -z "$PYTHON_BIN" ]; then
    echo "ERROR: python3 not found. Set PYTHON_BUNDLE_BIN to a Python 3 interpreter."
    exit 1
fi

PY_MINOR="$("$PYTHON_BIN" -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo "")"
if [ -n "$PY_MINOR" ] && [ "$PY_MINOR" -ge 13 ]; then
    echo "WARNING: Detected Python 3.$PY_MINOR. Some deps crash on 3.13+; prefer 3.12 or 3.11."
fi

VENV_CACHE_DIR="$SCRIPT_DIR/.venv-bundle-cache"

if [ ! -x "$VENV_CACHE_DIR/bin/python3" ]; then
    echo "==> Creating cached Python venv..."
    rm -rf "$VENV_CACHE_DIR"
    "$PYTHON_BIN" -m venv "$VENV_CACHE_DIR"
    "$VENV_CACHE_DIR/bin/python3" -m pip install --upgrade pip
    "$VENV_CACHE_DIR/bin/python3" -m pip install numpy soundfile lightning-whisper-mlx
else
    echo "==> Reusing cached Python venv..."
fi

echo "==> Copying bundled Python venv..."
rm -rf "$RESOURCES_DIR/venv"
mkdir -p "$RESOURCES_DIR"
ditto "$VENV_CACHE_DIR" "$RESOURCES_DIR/venv"

# Embed Python daemon scripts for native app to launch
cp transcription_daemon_mlx.py "$RESOURCES_DIR/" 2>/dev/null || true
cp llm_daemon.py "$RESOURCES_DIR/" 2>/dev/null || true

# Write Info.plist
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.textecho.app</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>TextEcho needs microphone access for dictation.</string>
    <key>NSInputMonitoringUsageDescription</key>
    <string>TextEcho needs input monitoring for global hotkeys.</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>TextEcho needs accessibility access to paste transcriptions.</string>
</dict>
</plist>
PLIST

xattr -rc "$APP_DIR" 2>/dev/null || true

if codesign --force --deep --sign - "$APP_DIR" 2>/dev/null; then
    echo "==> Code signing complete"
else
    echo "==> Code signing skipped (ad-hoc failed)"
fi

echo "==> Build complete: $APP_DIR"
