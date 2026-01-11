#!/bin/bash
# Simple launcher script for the dictation recorder
# Bind this to a hotkey in your desktop environment settings

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Set ydotool socket path
export YDOTOOL_SOCKET=/tmp/.ydotool_socket

# Launch the recorder GUI
uv run python recorder_gui.py >> ~/.dictation_gui.log 2>&1
