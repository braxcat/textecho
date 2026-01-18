# Dictation-Mac: Linux to macOS Migration Plan

> **Created**: 2026-01-18 | **Status**: Planning

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
| GTK4 + layer-shell | AppKit + NSWindow via PyObjC | Native overlay windows |
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

### Phase 1: Core Transcription
**Goal**: Get basic voice → text working on macOS

#### Tasks
1. [ ] Set up MLX Whisper integration
   - Install mlx-whisper package
   - Create `transcription_daemon_mac.py` or modify existing daemon
   - Test with Whisper base/small models
   - Benchmark against OpenVINO performance

2. [ ] Verify PyAudio works on macOS
   - Test audio recording
   - Ensure silence detection still functions
   - Check microphone permissions handling

3. [ ] Create basic CLI test
   - Record audio → transcribe → output text
   - Verify end-to-end pipeline

### Phase 2: Input Handling
**Goal**: Global hotkey and mouse button detection

#### Tasks
1. [ ] Implement CGEventTap for global input monitoring
   - Create `input_monitor_mac.py` module
   - Handle keyboard shortcuts (Cmd+Shift+D or similar)
   - Handle mouse button events (Mouse 4/5)
   - Request Accessibility permissions gracefully

2. [ ] Map hotkeys to macOS conventions
   - Transcribe: Configurable global hotkey + Mouse 4
   - LLM prompt: Modifier + trigger
   - Register capture: Cmd+Option+[1-9]
   - Cancel: ESC

3. [ ] Test input handling in various contexts
   - Works in all apps
   - Doesn't interfere with normal input
   - Handles permission denied gracefully

### Phase 3: Text Injection
**Goal**: Paste transcribed text into active application

#### Tasks
1. [ ] Implement Accessibility API text injection
   - Create `text_injector_mac.py` module
   - Use AXUIElement to find focused text field
   - Insert text or fall back to clipboard + paste
   - Handle permission requirements

2. [ ] Test across applications
   - Native macOS apps (Notes, TextEdit, Mail)
   - Electron apps (VS Code, Slack)
   - Terminal
   - Web browsers

### Phase 4: Menu Bar App & UI
**Goal**: Native macOS app experience with overlay

#### Tasks
1. [ ] Create menu bar application
   - Create `dictation_app_mac.py` as main entry point
   - NSStatusItem for menu bar presence
   - Dropdown menu: Start/Stop daemons, Settings, Quit
   - Show recording status in menu bar icon

2. [ ] Implement overlay window
   - Create `overlay_mac.py` using NSWindow
   - Floating, always-on-top, transparent background
   - Show recording indicator (waveform or pulsing dot)
   - Display transcription progress
   - Stream LLM responses
   - Tokyo Night color theme

3. [ ] Settings interface
   - NSWindow-based settings panel
   - Configure hotkeys, model paths, silence duration
   - Save to `~/.dictation_config`

### Phase 5: Daemon Management
**Goal**: Proper macOS service lifecycle

#### Tasks
1. [ ] Create launchd plist files
   - `com.dictation.transcription.plist`
   - `com.dictation.llm.plist`
   - Auto-start on login (optional)

2. [ ] Menu bar daemon controls
   - Start/stop individual daemons
   - Show daemon status
   - View logs option

3. [ ] Update daemon scripts for macOS
   - Modify `daemon_control.sh` or create macOS version
   - Handle PID files in macOS-appropriate location

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

### New Files
```
dictation_app_mac.py      - Main menu bar application
overlay_mac.py            - AppKit overlay window
input_monitor_mac.py      - CGEventTap input handling
text_injector_mac.py      - Accessibility API text injection
transcription_mlx.py      - MLX Whisper integration (or modify daemon)
com.dictation.*.plist     - launchd service definitions
```

### Modified Files
```
transcription_daemon.py   - Replace OpenVINO with MLX Whisper
llm_daemon.py            - Minimal changes (Metal already works)
daemon_control.sh        - macOS compatibility or separate script
pyproject.toml           - Update dependencies
```

### Removed/Deprecated Files
```
dictation_app_gtk.py     - Replaced by dictation_app_mac.py
dictation_overlay.py     - Replaced by overlay_mac.py
gnome-extension/         - Not needed on macOS
test_evdev.py           - Linux-specific
window_positioner.py    - Replaced by AppKit positioning
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

### Phase 1 Complete
- [ ] Can record audio and transcribe using MLX Whisper
- [ ] Performance is acceptable (<2s for short clips)

### Phase 2 Complete
- [ ] Global hotkey triggers recording from any app
- [ ] Mouse button triggers work

### Phase 3 Complete
- [ ] Transcribed text appears in active text field
- [ ] Works in common apps (browser, editor, terminal)

### Phase 4 Complete
- [ ] Menu bar app shows status and controls
- [ ] Overlay displays during recording/transcription

### Phase 5 Complete
- [ ] Daemons start/stop cleanly
- [ ] Survives logout/login

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
