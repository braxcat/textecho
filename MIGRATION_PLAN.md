# Dictation-Mac: Linux to macOS Migration Plan

> **Created**: 2026-01-18 | **Status**: Phase 5 In Progress | **Last Updated**: 2026-01-19

## Overview

This document outlines the migration plan for converting Dictation-Mac from a Linux (GNOME/Wayland) application to a native macOS application optimized for Apple Silicon.

### Target Hardware
- MacBook Pro M4 Max
- 36GB unified memory
- Apple Silicon (ARM64)

### Migration Scope
- **macOS-only**: No need to maintain Linux compatibility
- **Priority features**: Basic transcription → Hotkey system → UI overlay
- **New feature**: System-wide dictation replacement

---

## Component Migration Map

| Linux Component | macOS Replacement | Notes |
|-----------------|-------------------|-------|
| `evdev` | CGEventTap / IOKit via PyObjC | Global input monitoring |
| OpenVINO Whisper | MLX Whisper | Apple Silicon native |
| GTK4 + layer-shell | Swift/SwiftUI helper app | Native overlay (PyObjC had threading issues) |
| `ydotool` / `xdotool` | Accessibility API (AXUIElement) | Text injection |
| GNOME extension | Not needed | AppKit handles window positioning |
| Shell daemon scripts | launchd + menu bar controls | Native macOS service management |
| PyGObject | PyObjC | Python-to-native bridge |

---

## Architecture Decisions

### Keep (Minimal Changes)
- **Daemon architecture**: Separate transcription/LLM daemons with Unix sockets
- **PyAudio**: Cross-platform, works on macOS with PortAudio
- **llama-cpp-python**: Already supports Metal acceleration on Apple Silicon
- **JSON-over-socket protocol**: Platform-agnostic IPC
- **Configuration file**: `~/.dictation_config` format unchanged

### Replace
- **Whisper inference**: OpenVINO → MLX Whisper
- **UI framework**: GTK4 → AppKit via PyObjC
- **Input handling**: evdev → CGEventTap
- **Text injection**: ydotool → Accessibility API
- **App model**: CLI scripts → Menu bar app

---

## Implementation Phases

### Phase 1: Core Transcription ✅ COMPLETE
**Goal**: Get basic voice → text working on macOS

#### Tasks
1. [x] Set up MLX Whisper integration
   - Using `lightning-whisper-mlx` package
   - Created `transcription_daemon_mlx.py` with full daemon support
   - Supports distil-medium.en (fast) and distil-large-v3 (accurate) models
   - Supports fast/accurate/single daemon modes

2. [x] Verify PyAudio works on macOS
   - Test audio recording - works via `test_mlx_transcription.py --record`
   - Microphone permissions handled

3. [x] Create basic CLI test
   - `test_mlx_transcription.py` created
   - Supports direct transcription and daemon mode
   - Record audio → transcribe → output text verified

### Phase 2: Input Handling ✅ COMPLETE
**Goal**: Global hotkey and mouse button detection

#### Tasks
1. [x] Implement global input monitoring
   - Created `input_monitor_mac.py` using hybrid approach:
     - CGEventTap for mouse (reliable side button detection)
     - pynput for keyboard (simpler modifier tracking)
   - Configurable trigger button (default: middle click)
   - Requires Accessibility permissions
   - **Status**: Tested and working

2. [x] Map hotkeys to macOS conventions
   - Transcribe: Mouse 4 (hold to record)
   - LLM prompt: Ctrl + Mouse 4
   - Register capture: Cmd+Option+[1-9]
   - Clear registers: Cmd+Option+0
   - Settings: Cmd+Option+Space
   - Cancel: ESC

3. [x] Test input handling in various contexts
   - [x] Mouse buttons detected correctly (middle, back, forward)
   - [x] Keyboard hotkeys work (Cmd+Option+0-9, Space)
   - [ ] Test across various apps (partial)
   - [ ] Handles permission denied gracefully (needs testing)

### Phase 3: Text Injection ✅ COMPLETE
**Goal**: Paste transcribed text into active application

#### Tasks
1. [x] Implement text injection
   - Created `text_injector_mac.py` module
   - Primary: clipboard + Cmd+V paste (works everywhere)
   - Optional: direct Accessibility API (native apps only)
   - Configurable method (clipboard/accessibility/auto)

2. [x] Test across applications
   - [x] Native macOS apps (Notes) - works
   - [x] Web browsers (Chrome) - works via clipboard
   - [x] Terminal - works via clipboard
   - Note: clipboard+paste method works universally

### Phase 4: Menu Bar App & UI ✅ COMPLETE
**Goal**: Native macOS app experience with overlay

#### Tasks
1. [x] Create menu bar application
   - Created `dictation_app_mac.py` as main entry point
   - NSStatusItem for menu bar presence (🎤 icon)
   - Dropdown menu: Start/Stop daemons, Settings, Quit
   - Recording status shown in menu bar icon
   - PyAudio recording with middle-click trigger
   - **Status**: Working

2. [x] Implement overlay window
   - **Solution**: Swift/SwiftUI helper app (`DictationOverlay/`)
   - PyObjC overlay (`overlay_mac.py`) had threading crashes - abandoned
   - Created `DictationOverlayHelper` (Swift) + `overlay_swift.py` (Python wrapper)
   - Features:
     - Shows recording/processing/result/error states
     - Live waveform visualization during recording
     - Follows mouse cursor (positions above, or side/below if near screen edge)
     - Tokyo Night color theme
   - Communication via stdin/stdout JSON protocol
   - **Status**: Working

3. [ ] Settings interface
   - NSWindow-based settings panel (or Swift helper)
   - Configure hotkeys, model paths, silence duration
   - Save to `~/.dictation_config`

### Phase 5: Daemon Management ✅ COMPLETE
**Goal**: Proper macOS service lifecycle

#### Tasks
1. [x] Create launchd plist files
   - Created `launchd/com.dictation.transcription.plist`
   - Created `launchd/com.dictation.llm.plist`
   - Created `launchd/com.dictation.app.plist`
   - Uses venv Python: `__WORKING_DIR__/.venv/bin/python3.12`
   - Auto-start on login via RunAtLoad
   - **Important**: Must set `HOME` environment variable for cache directories
   - **Important**: Must set `WorkingDirectory` to user home

2. [x] Menu bar daemon controls
   - Added Restart Daemons option
   - Added Auto-Start Options submenu
   - Added View Logs submenu
   - Show daemon status in menu

3. [x] Update daemon scripts for macOS
   - Created `daemon_control_mac.sh` with launchd support
   - Commands: install, uninstall, start, stop, restart, status, logs
   - Falls back to direct execution if launchd not installed
   - Checks if process already running before starting (prevents duplicates)

4. [x] Set up Python virtual environment
   - Created `.venv` with Homebrew Python 3.12
   - Installed: mlx-whisper, lightning-whisper-mlx, pyobjc, pyaudio, numpy, soundfile, pynput

5. [x] Text injection (auto-paste) - RESOLVED
   - Auto-paste now works correctly
   - Requires Accessibility permission for `.venv/bin/python3.12`

#### Launchd Debugging Notes
- Use `python3.12` not `python3` (symlink resolution issues)
- Must set `HOME` env var - MLX Whisper needs `~/.cache` for model downloads
- Must set `WorkingDirectory` to avoid read-only filesystem errors
- Python binary needs Accessibility permissions for paste simulation

### Phase 6: Polish & System Integration
**Goal**: Production-ready macOS app

#### Tasks
1. [ ] Handle macOS permissions gracefully
   - Accessibility (input monitoring, text injection)
   - Microphone
   - Guide user through permission grants

2. [ ] Create proper .app bundle (optional)
   - py2app or similar
   - Code signing considerations
   - DMG distribution

3. [ ] System-wide dictation replacement
   - Register as system service
   - Potentially replace built-in dictation

4. [ ] Testing & documentation
   - Test on clean macOS install
   - Update README with macOS instructions
   - Document permissions requirements

---

## File Changes Summary

### New Files (Created)
```
transcription_daemon_mlx.py  ✅ - MLX Whisper daemon (replaces OpenVINO)
test_mlx_transcription.py    ✅ - Transcription testing utility
input_monitor_mac.py         ✅ - NSEvent + pynput input handling
text_injector_mac.py         ✅ - Clipboard + paste text injection
dictation_app_mac.py         ✅ - Menu bar app (working)
overlay_swift.py             ✅ - Python wrapper for Swift overlay
DictationOverlay/main.swift  ✅ - Swift overlay with waveform visualization
DictationOverlay/DictationOverlayHelper ✅ - Compiled Swift binary
overlay_mac.py               ⚠️ - PyObjC overlay (crashes, abandoned)
```

### New Files (Created - Phase 5)
```
launchd/com.dictation.app.plist          ✅ - Menu bar app launchd service
launchd/com.dictation.transcription.plist ✅ - Transcription daemon launchd service
launchd/com.dictation.llm.plist          ✅ - LLM daemon launchd service
daemon_control_mac.sh                     ✅ - macOS daemon control script (launchd)
.venv/                                    ✅ - Python virtual environment (Homebrew 3.12)
```

### Modified Files
```
llm_daemon.py            - Minimal changes (Metal already works)
pyproject.toml           - Update dependencies
```

### Removed Files (Linux-only, deleted)
```
dictation_app_gtk.py     - Replaced by dictation_app_mac.py
dictation_overlay.py     - Replaced by Swift overlay
dictation_daemon.py      - Replaced by input_monitor_mac.py
recorder_gui.py          - Replaced by dictation_app_mac.py
transcription_daemon.py  - Replaced by transcription_daemon_mlx.py
daemon_control.sh        - Replaced by daemon_control_mac.sh
window_positioner.py     - Replaced by AppKit positioning
gnome-extension/         - Not needed on macOS
test_evdev.py           - Linux-specific (evdev)
export_whisper_*.py/sh  - Linux-specific (OpenVINO)
```

---

## Dependencies Update

### Remove (Linux-only)
```
evdev
PyGObject
pycairo
openvino
openvino-genai
```

### Add (macOS)
```
pyobjc-core              - Core PyObjC framework
pyobjc-framework-Cocoa   - AppKit, Foundation
pyobjc-framework-Quartz  - CGEventTap, accessibility
mlx                      - Apple ML framework
mlx-whisper              - Whisper on MLX
```

### Keep
```
numpy
pyaudio
soundfile
pynput                   - May still be useful for some input
pillow
llama-cpp-python         - With Metal support
```

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Accessibility permissions complex | Medium | High | Clear user guidance, graceful fallbacks |
| MLX Whisper performance unknown | Low | Medium | Benchmark early, whisper.cpp as backup |
| CGEventTap edge cases | Medium | Medium | Thorough testing across apps |
| PyObjC learning curve | Medium | Low | Good documentation available |
| Text injection failures in some apps | Medium | Medium | Clipboard fallback always available |

---

## Success Criteria

### Phase 1 Complete ✅
- [x] Can record audio and transcribe using MLX Whisper
- [x] Performance is acceptable (<2s for short clips)

### Phase 2 Complete ✅
- [x] Global hotkey triggers recording from any app
- [x] Mouse button triggers work

### Phase 3 Complete ✅
- [x] Transcribed text appears in active text field
- [x] Works in common apps (browser, editor, terminal)

### Phase 4 Complete ✅
- [x] Menu bar app shows status and controls
- [x] Overlay displays during recording/transcription (Swift solution)
- [x] Waveform visualization shows audio levels in real-time

### Phase 5 Complete ✅
- [x] Daemons start/stop cleanly
- [x] Survives logout/login (via launchd RunAtLoad)

### Phase 6 Complete
- [ ] Works on fresh macOS install
- [ ] User can install and use without developer assistance

---

## Notes

- Start with Phase 1-2 to validate core functionality before UI work
- Keep daemon architecture for fast response times
- Unix sockets work fine on macOS, no need to change IPC
- Tokyo Night theme should translate well to AppKit
- Consider using rumps library for simpler menu bar app (optional)

---

## Progress Log

> This section tracks work done across sessions. Update after each significant change.

### 2026-01-18 - Session 2
- **Phase 1 COMPLETED**: MLX Whisper transcription daemon working
  - `transcription_daemon_mlx.py` - full daemon with fast/accurate modes
  - `test_mlx_transcription.py` - testing utility
  - Using `lightning-whisper-mlx` package
- **Phase 2 COMPLETED**: Input monitoring
  - `input_monitor_mac.py` created and tested
  - Uses NSEvent global monitor for mouse (replaced CGEventTap due to crashes)
  - Uses pynput for keyboard (hotkeys with virtual key codes)
  - Trigger button configurable (default: middle click / button 2)
  - Tested: middle click, back/forward buttons, Cmd+Option+0-9, Cmd+Option+Space, ESC
- **Phase 3 COMPLETED**: Text injection
  - `text_injector_mac.py` - clipboard + Cmd+V paste (works universally)
  - Tested in Notes, Chrome, Terminal
- **Phase 4 PARTIAL**: Menu bar app
  - `dictation_app_mac.py` - working menu bar app with recording/transcription
  - `overlay_mac.py` - created but disabled due to crashes
  - **Issue**: Overlay causes trace trap crashes (PyObjC threading with NSApplication)

### 2026-01-18 - Session 3
- **Phase 4 COMPLETED**: Swift overlay solution
  - PyObjC overlay had persistent threading crashes (trace trap)
  - Created Swift/SwiftUI overlay helper: `DictationOverlay/main.swift`
  - Python wrapper: `overlay_swift.py` communicates via stdin/stdout JSON
  - Features implemented:
    - Recording/Processing/Result/Error states with Tokyo Night colors
    - Live waveform visualization (40 bars, responds to voice)
    - Smart positioning: above cursor, repositions if near screen edges
    - Follows mouse while recording
  - Fixed menu bar actions (removed @objc.python_method decorators)
  - Waveform updates run in separate thread to avoid blocking audio recording
  - **Status**: Fully working

### 2026-01-19 - Session 4
- **Phase 5 IN PROGRESS**: Daemon management
  - Created launchd plist files in `launchd/` directory
  - Created `daemon_control_mac.sh` with full launchd support
  - Set up Python venv (`.venv`) with Homebrew Python 3.12
  - Installed all dependencies: mlx-whisper, lightning-whisper-mlx, pyobjc, pyaudio, pynput, etc.

### 2026-01-20 - Session 5
- **Phase 5 COMPLETED**: Daemon management fully working
  - Fixed launchd plist issues:
    - Use `python3.12` instead of `python3` (symlink resolution)
    - Added `HOME` environment variable (required for MLX cache)
    - Added `WorkingDirectory` set to user home
    - Use full paths for Python scripts
  - Fixed duplicate instance issue (script checks if already running)
  - Added Accessibility permission for `.venv/bin/python3.12` (required for auto-paste)
  - All features working via launchd:
    - ✅ Transcription daemon auto-starts
    - ✅ Menu bar app auto-starts
    - ✅ Recording with middle-click
    - ✅ Overlay with waveform
    - ✅ MLX Whisper transcription
    - ✅ Auto-paste into active app

### How to Run (Current State)
```bash
# First time setup:
brew install python@3.12
/opt/homebrew/bin/python3.12 -m venv .venv
source .venv/bin/activate
pip install mlx-whisper lightning-whisper-mlx pyobjc pyaudio numpy soundfile pynput

# Install launchd services (auto-start on login):
./daemon_control_mac.sh install

# Start everything:
./daemon_control_mac.sh start

# Check status:
./daemon_control_mac.sh status

# View logs:
./daemon_control_mac.sh logs

# Stop everything:
./daemon_control_mac.sh stop

# Uninstall auto-start:
./daemon_control_mac.sh uninstall

# Usage:
# - Middle-click (hold) to record, release to transcribe
# - Overlay appears above cursor with live waveform
# - Text is auto-pasted into active app
# - Cmd+Option+1-9: Save clipboard to register
# - Cmd+Option+0: Clear registers
# - ESC: Cancel recording
# - Menu bar: Restart Daemons, Auto-Start Options, View Logs, Quit

# Required Permissions (System Settings → Privacy & Security):
# - Accessibility: Add .venv/bin/python3.12 (for auto-paste and input monitoring)
# - Microphone: Allow access when prompted (for audio recording)
```
