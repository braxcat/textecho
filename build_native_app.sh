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

# Check if binary changed - avoid re-signing if unchanged (preserves macOS permissions)
# Compare unsigned build output hash against saved hash from last build
BINARY_CHANGED=true
BIN_HASH_FILE="$SCRIPT_DIR/.last_binary_hash"
NEW_HASH=$(shasum -a 256 "$BIN_PATH" | cut -d' ' -f1)
if [ -f "$BIN_HASH_FILE" ] && [ -f "$MACOS_DIR/${APP_NAME}" ]; then
    OLD_HASH=$(cat "$BIN_HASH_FILE" 2>/dev/null || echo "")
    if [ "$NEW_HASH" = "$OLD_HASH" ]; then
        BINARY_CHANGED=false
        echo "==> Binary unchanged, preserving existing signature"
    fi
fi

if [ "$BINARY_CHANGED" = true ]; then
    rm -rf "$APP_DIR"
fi
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

if [ "$BINARY_CHANGED" = true ]; then
    cp "$BIN_PATH" "$MACOS_DIR/${APP_NAME}"
    chmod +x "$MACOS_DIR/${APP_NAME}"
    echo "$NEW_HASH" > "$BIN_HASH_FILE"
fi

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
    echo "ERROR: Python 3.$PY_MINOR detected. tiktoken crashes on 3.13+."
    echo "Install Python 3.12: brew install python@3.12"
    echo "Or set: PYTHON_BUNDLE_BIN=/opt/homebrew/bin/python3.12"
    exit 1
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

if [ "$BINARY_CHANGED" = true ] || [ ! -d "$RESOURCES_DIR/venv" ]; then
    echo "==> Copying bundled Python venv..."
    rm -rf "$RESOURCES_DIR/venv"
    mkdir -p "$RESOURCES_DIR"
    ditto "$VENV_CACHE_DIR" "$RESOURCES_DIR/venv"
else
    echo "==> Reusing existing bundled venv (unchanged)"
fi

# Embed Python daemon scripts for native app to launch
cp transcription_daemon_mlx.py "$RESOURCES_DIR/" 2>/dev/null || true
cp llm_daemon.py "$RESOURCES_DIR/" 2>/dev/null || true

# Bundle app icon
cp "$SCRIPT_DIR/assets/TextEcho.icns" "$RESOURCES_DIR/"

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
    <key>CFBundleIconFile</key>
    <string>TextEcho</string>
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

if [ "$BINARY_CHANGED" = true ]; then
    if codesign --force --deep --sign - "$APP_DIR" 2>/dev/null; then
        echo "==> Code signing complete"
    else
        echo "==> Code signing skipped (ad-hoc failed)"
    fi
    echo ""
    echo "NOTE: macOS permissions (Accessibility, Microphone) are tied to the code signature."
    echo "      You may need to re-grant them in System Settings → Privacy & Security."
else
    echo "==> Code signing skipped (binary unchanged, permissions preserved)"
fi

echo "==> Build complete: $APP_DIR"
