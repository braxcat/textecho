#!/bin/bash
# Build TextEcho as a native Swift .app bundle.
# Uses xcodebuild (not swift build) so Metal shaders compile correctly for MLX.
# Default: pure Swift + WhisperKit + MLX (no Python needed).
# With --with-llm: also bundles Python venv with llama-cpp-python for local LLM.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="TextEcho"
APP_DIR="dist/${APP_NAME}.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
WITH_LLM=false
CLEAN=false
DEBUG=false
SIGN_MODE="adhoc"
DERIVED_DATA="$SCRIPT_DIR/mac_app/.build/xcode"

for arg in "$@"; do
    case "$arg" in
        --with-llm) WITH_LLM=true ;;
        --clean) CLEAN=true ;;
        --debug) DEBUG=true ;;
        --sign) SIGN_MODE="developer" ;;
    esac
done

if [ "$SIGN_MODE" = "developer" ]; then
    if [ -z "$DEVELOPER_ID" ]; then
        echo "ERROR: --sign requires DEVELOPER_ID env var."
        echo "  Example: DEVELOPER_ID='Developer ID Application: Name (TEAMID)' $0 --sign"
        exit 1
    fi
fi

if [ "$CLEAN" = true ]; then
    echo "==> Clean build: removing all caches..."
    rm -rf mac_app/.build .swiftpm-cache .clang-cache .last_binary_hash dist/
fi

echo "==> Building with xcodebuild (compiles Metal shaders for MLX)..."
if [ "$DEBUG" = true ]; then
    BUILD_CONFIG="Debug"
else
    BUILD_CONFIG="Release"
fi

pushd mac_app > /dev/null
xcodebuild build \
    -scheme TextEchoApp \
    -configuration "$BUILD_CONFIG" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -skipPackagePluginValidation \
    -quiet
popd > /dev/null

# Locate the built binary
PRODUCTS_DIR="$DERIVED_DATA/Build/Products/${BUILD_CONFIG}"
BIN_PATH="$PRODUCTS_DIR/TextEchoApp"
if [ ! -f "$BIN_PATH" ]; then
    echo "ERROR: Build failed; binary not found at $BIN_PATH"
    echo "  Searching derived data for binary..."
    find "$DERIVED_DATA" -name "TextEchoApp" -type f -perm +111 2>/dev/null | head -5
    exit 1
fi

echo "==> Creating .app bundle..."

# Check if binary changed - avoid re-signing if unchanged (preserves macOS permissions)
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

# Bundle MLX Metal shader libraries (required for MLX GPU operations)
# xcodebuild compiles .metal → .metallib and places them in resource bundles
BUNDLES_COPIED=0
for bundle in "$PRODUCTS_DIR"/*.bundle; do
    if [ -d "$bundle" ]; then
        BUNDLE_NAME="$(basename "$bundle")"
        cp -R "$bundle" "$RESOURCES_DIR/$BUNDLE_NAME"
        BUNDLES_COPIED=$((BUNDLES_COPIED + 1))
    fi
done
if [ "$BUNDLES_COPIED" -gt 0 ]; then
    echo "==> Copied $BUNDLES_COPIED resource bundle(s) (includes Metal shaders)"
else
    echo "WARNING: No resource bundles found — MLX GPU operations may fail"
fi

# Optional: Bundle Python venv with LLM support
if [ "$WITH_LLM" = true ]; then
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
        echo "==> Creating cached Python venv for LLM..."
        rm -rf "$VENV_CACHE_DIR"
        "$PYTHON_BIN" -m venv "$VENV_CACHE_DIR"
        "$VENV_CACHE_DIR/bin/python3" -m pip install --upgrade pip
        "$VENV_CACHE_DIR/bin/python3" -m pip install llama-cpp-python
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

    # Bundle LLM daemon script
    cp llm_daemon.py "$RESOURCES_DIR/" 2>/dev/null || true
    echo "==> LLM module bundled"
else
    echo "==> Skipping Python/LLM bundling (pure Swift build)"
fi

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
    <string>2.0</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0</string>
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
    <string>14.0</string>
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
    if [ "$SIGN_MODE" = "developer" ]; then
        echo "==> Signing with Developer ID (hardened runtime)..."
        codesign --force --deep --sign "$DEVELOPER_ID" \
            --entitlements mac_app/TextEcho.entitlements \
            --options runtime \
            --timestamp \
            "$APP_DIR"
        echo "==> Developer ID signing complete"
    else
        if codesign --force --deep --sign - "$APP_DIR" 2>/dev/null; then
            echo "==> Ad-hoc code signing complete"
        else
            echo "==> Code signing skipped (ad-hoc failed)"
        fi
        echo ""
        echo "NOTE: macOS permissions (Accessibility, Microphone) are tied to the code signature."
        echo "      You may need to re-grant them in System Settings → Privacy & Security."
        echo "      Use --sign with DEVELOPER_ID for stable signatures."
    fi
else
    echo "==> Code signing skipped (binary unchanged, permissions preserved)"
fi

echo "==> Build complete: $APP_DIR"
echo "    Build: xcodebuild ($BUILD_CONFIG)"
echo "    LLM: native MLX with Metal shaders (enable in Settings)"
