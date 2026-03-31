#!/bin/bash
#
# Uninstall TextEcho completely
#
# This script:
# 1. Kills all running processes
# 2. Removes launchd services
# 3. Removes the app from Applications
# 4. Removes config files and sockets
# 5. Removes log files
# 6. Provides instructions for removing permissions
#
# Usage:
#   ./uninstall.sh
#

set -e

echo "==> Uninstalling TextEcho..."
echo ""

# 1. Kill all running processes
echo "==> Killing running processes..."
pkill -f "TextEcho" 2>/dev/null && echo "    Killed TextEcho app" || true
pkill -f "textecho_app_mac" 2>/dev/null && echo "    Killed textecho_app_mac" || true
pkill -f "transcription_daemon_mlx" 2>/dev/null && echo "    Killed transcription daemon" || true
pkill -f "llm_daemon" 2>/dev/null && echo "    Killed LLM daemon" || true
pkill -f "TextEchoOverlayHelper" 2>/dev/null && echo "    Killed overlay helper" || true
echo "    Done"
echo ""

# 2. Remove launchd services
echo "==> Removing launchd services..."
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.textecho.app.plist 2>/dev/null && echo "    Removed com.textecho.app" || true
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.textecho.transcription.plist 2>/dev/null && echo "    Removed com.textecho.transcription" || true
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.textecho.llm.plist 2>/dev/null && echo "    Removed com.textecho.llm" || true
rm -f ~/Library/LaunchAgents/com.textecho.*.plist
echo "    Done"
echo ""

# 3. Remove app from Applications
echo "==> Removing app from Applications..."
if [ -d "/Applications/TextEcho.app" ]; then
    rm -rf "/Applications/TextEcho.app"
    echo "    Removed /Applications/TextEcho.app"
else
    echo "    App not found in /Applications"
fi
echo ""

# 4. Remove config and data files
echo "==> Removing config and data files..."
rm -f ~/.textecho_config && echo "    Removed ~/.textecho_config" || true
rm -f ~/.textecho_app.log && echo "    Removed ~/.textecho_app.log" || true
rm -f ~/.textecho_transcription.log && echo "    Removed ~/.textecho_transcription.log" || true
rm -f ~/.textecho_llm.log && echo "    Removed ~/.textecho_llm.log" || true
rm -f ~/.textecho_app.pid && echo "    Removed ~/.textecho_app.pid" || true
rm -f ~/.textecho_transcription.pid && echo "    Removed ~/.textecho_transcription.pid" || true
rm -f ~/.textecho_llm.pid && echo "    Removed ~/.textecho_llm.pid" || true
echo "    Done"
echo ""

# 5. Remove registers file
echo "==> Removing registers..."
rm -f ~/.textecho_registers.json && echo "    Removed ~/.textecho_registers.json" || true
echo ""

# 6. Remove WhisperKit models
echo "==> Removing WhisperKit models..."
HF_MODELS="$HOME/Documents/huggingface/models/argmaxinc/whisperkit-coreml"
if [ -d "$HF_MODELS" ]; then
    rm -rf "$HF_MODELS"
    echo "    Removed $HF_MODELS"
else
    echo "    No WhisperKit models found"
fi
echo ""

# 7. Remove log directory
echo "==> Removing log files..."
if [ -d ~/Library/Logs/TextEcho ]; then
    rm -rf ~/Library/Logs/TextEcho
    echo "    Removed ~/Library/Logs/TextEcho"
else
    echo "    Log directory not found"
fi
echo ""

# 8. Remove sockets
echo "==> Removing sockets..."
rm -f /tmp/textecho_transcription.sock && echo "    Removed transcription socket" || true
rm -f /tmp/textecho_llm.sock && echo "    Removed LLM socket" || true
echo "    Done"
echo ""

# 9. Eject any mounted DMG
echo "==> Ejecting DMG if mounted..."
hdiutil detach /Volumes/TextEcho 2>/dev/null && echo "    Ejected TextEcho DMG" || echo "    No DMG mounted"
echo ""

# 10. Reset TCC permissions (requires manual action)
echo "==> Permission Cleanup"
echo ""
echo "    To fully remove permissions, you need to manually remove TextEcho from:"
echo ""
echo "    1. System Settings → Privacy & Security → Accessibility"
echo "       - Find TextEcho or python and toggle OFF or remove"
echo ""
echo "    2. System Settings → Privacy & Security → Microphone"
echo "       - Find TextEcho or python and toggle OFF or remove"
echo ""
echo "    Alternatively, reset ALL permissions for TextEcho with:"
echo "    tccutil reset All com.textecho.app"
echo ""
echo "    (This requires running in Terminal with appropriate permissions)"
echo ""

# Try to reset TCC permissions automatically (may fail without SIP disabled)
echo "==> Attempting to reset TCC permissions..."
tccutil reset Accessibility com.textecho.app 2>/dev/null && echo "    Reset Accessibility permission" || echo "    Could not reset Accessibility (manual removal required)"
tccutil reset Microphone com.textecho.app 2>/dev/null && echo "    Reset Microphone permission" || echo "    Could not reset Microphone (manual removal required)"
echo ""

echo "==> Uninstall complete!"
echo ""
echo "    TextEcho has been removed from your system."
echo "    Please manually check Privacy & Security settings if permissions remain."
echo ""
