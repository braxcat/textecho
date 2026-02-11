# TextEcho

Native macOS menu bar app for voice-to-text dictation. Uses MLX Whisper for local Apple Silicon transcription and optional local LLM processing via llama-cpp-python. Swift UI with embedded Python daemons — no cloud, no network, fully offline.

### Documentation Index

| Document | Purpose | Update when... |
|----------|---------|----------------|
| [README.md](README.md) | Project overview, installation, usage | Features or setup changes |
| [claude_docs/ARCHITECTURE.md](claude_docs/ARCHITECTURE.md) | System design, IPC protocol, build pipeline | Architectural changes |
| [claude_docs/CHANGELOG.md](claude_docs/CHANGELOG.md) | Release history | After each deploy |
| [claude_docs/FEATURES.md](claude_docs/FEATURES.md) | Feature inventory | Any feature ships/changes |
| [claude_docs/PLANNING.md](claude_docs/PLANNING.md) | Future features, research | New ideas or research |
| [claude_docs/ROADMAP.md](claude_docs/ROADMAP.md) | Phase plan + future work | Planning or completing phases |
| [claude_docs/SECURITY.md](claude_docs/SECURITY.md) | Permissions, signing, data handling | Security changes |
| [claude_docs/TESTING.md](claude_docs/TESTING.md) | Test strategy | Test stack changes |
| [claude_docs/WORKLOG.md](claude_docs/WORKLOG.md) | Dev session log | After each session |

## Quick Start

**Prerequisites:** macOS 13+, Apple Silicon, Python 3.12 (NOT 3.13+), Xcode CLI tools

```bash
# Build the native app
PYTHON_BUNDLE_BIN=/opt/homebrew/bin/python3.12 ./build_native_app.sh

# Deploy to /Applications
cp -R dist/TextEcho.app /Applications/ && open /Applications/TextEcho.app
```

Grant **Accessibility** and **Microphone** permissions in System Settings when prompted.

## Commands

| Command | Description |
|---------|-------------|
| `./build_native_app.sh` | Build Swift app + bundle Python venv into .app |
| `swift build -c release --package-path mac_app` | Build Swift only (no Python bundle) |
| `./build_native_dmg.sh` | Create distributable DMG |
| `./daemon_control_mac.sh status` | Check daemon status (dev diagnostic) |

## Architecture

**Swift app** (`mac_app/Sources/TextEchoApp/`) is the sole entry point. It manages two Python daemons:

```
TextEcho.app (Swift)
├── AppMain → AppState (orchestrator)
├── InputMonitor (CGEventTap → hotkeys)
├── AudioRecorder (AVAudioEngine → PCM)
├── PythonServiceManager (launches daemons)
├── TranscriptionClient (UnixSocket IPC)
├── Overlay (SwiftUI floating window)
└── TextInjector (clipboard + Cmd+V paste)

Python Daemons (bundled venv)
├── transcription_daemon_mlx.py → /tmp/textecho_transcription.sock
└── llm_daemon.py → /tmp/textecho_llm.sock
```

**IPC Protocol:** JSON header + newline + optional binary body, over Unix domain sockets.

## Key Configuration

`~/.textecho_config` (JSON):

| Field | Default | Description |
|-------|---------|-------------|
| `trigger_button` | `2` | Mouse button (2=middle) |
| `dictation_keycode` | `2` | Keyboard trigger (2=D key) |
| `silence_duration` | `2.5` | Seconds before auto-stop |
| `llm_enabled` | `false` | Enable LLM processing |
| `llm_model_path` | `""` | Path to GGUF model |
| `python_path` | auto-detected | Python 3.12 executable |
| `daemon_scripts_dir` | auto-detected | Directory containing daemon .py files |

## Hotkeys

| Action | Hotkey |
|--------|--------|
| Transcribe & paste (mouse) | Middle-click (hold to record) |
| Transcribe & paste (keyboard) | Ctrl+D (hold to record) |
| LLM prompt (mouse) | Ctrl + Middle-click |
| LLM prompt (keyboard) | Ctrl+Shift+D |
| Save clipboard to register | Cmd+Option+[1-9] |
| Clear all registers | Cmd+Option+0 |
| Settings dialog | Cmd+Option+Space |
| Cancel recording | ESC |

## Development Guidelines

- **macOS only** — Apple Silicon (ARM64)
- **Python 3.12** required — 3.13+ breaks tiktoken (Rust/pyo3 segfault)
- **Do NOT auto-install deps** — no sudo, no pip install, no downloads
- Delete `.venv-bundle-cache` to force venv rebuild
- Unix sockets for IPC (not HTTP), JSON protocol with newline delimiters
- Lazy model loading, auto-unload after idle timeout

## Project Structure

```
dictation-mac/
├── mac_app/                          # Swift app (SwiftPM package)
│   ├── Package.swift
│   └── Sources/TextEchoApp/
│       ├── AppMain.swift             # Entry point, menu bar setup
│       ├── AppState.swift            # Orchestrator (recording flow)
│       ├── AppConfig.swift           # ~/.textecho_config reader
│       ├── PythonServiceManager.swift # Daemon process lifecycle
│       ├── TranscriptionClient.swift  # UnixSocket IPC client
│       ├── LLMClient.swift           # LLM socket client
│       ├── InputMonitor.swift        # CGEventTap hotkey detection
│       ├── AudioRecorder.swift       # AVAudioEngine recording
│       ├── Overlay.swift             # SwiftUI floating overlay
│       ├── TextInjector.swift        # Clipboard + Cmd+V paste
│       ├── SetupWizard.swift         # First-launch permission wizard
│       ├── SettingsWindow.swift      # Settings UI
│       ├── LogsWindow.swift          # Log viewer UI
│       ├── LaunchdManager.swift      # Autostart via launchd
│       ├── AccessibilityHelper.swift # AX permission checks
│       ├── MicrophoneHelper.swift    # Mic permission checks
│       ├── UninstallManager.swift    # Cleanup helper
│       └── RestoreWindow.swift       # Window restore helper
├── transcription_daemon_mlx.py       # MLX Whisper transcription daemon
├── llm_daemon.py                     # Local LLM daemon (llama-cpp)
├── build_native_app.sh               # Build script (Swift + bundled Python)
├── build_native_dmg.sh               # DMG creation script
├── daemon_control_mac.sh             # Dev diagnostic tool
├── pyproject.toml                    # Python dependencies
└── claude_docs/                      # Project documentation
```
