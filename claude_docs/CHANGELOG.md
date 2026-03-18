# Changelog

## 2026-03-18 — MLX Whisper Upgrade

### Transcription Engine
- **Replaced `lightning-whisper-mlx` with `mlx-whisper`** — actively maintained library with broader model support
- **Default model upgraded to `large-v3-turbo`** — near large-v3 quality at 8x speed, ideal for M4 Max
- Accurate mode now uses `whisper-large-v3-mlx` (full 1.55B param model)
- Models are now HuggingFace repo IDs (e.g. `mlx-community/whisper-large-v3-turbo`), downloaded and cached automatically
- Removed batch_size and quantization config — mlx-whisper manages this internally
- Updated pyproject.toml, build script, and PythonServiceManager

### Config Changes
- `mlx_model` / `mlx_model_fast` / `mlx_model_accurate` now accept HuggingFace repo IDs
- Removed: `mlx_batch_size`, `mlx_quant`, and per-mode variants
- Users must delete `.venv-bundle-cache` and rebuild to pick up the new library

## 2026-02-12 — Distribution & Bug Fix Release

### Distribution
- Bundled app icon (TextEcho.icns) into .app Resources + Info.plist CFBundleIconFile
- Rebuilt DMG with icon and all fixes
- Added "Install from DMG" section to README, renamed existing to "Build from source"

### Bug Fixes
- **Fixed ffmpeg not found from .app bundle** — added /opt/homebrew/bin and /usr/local/bin to PATH in PythonServiceManager when launching daemons (Finder-launched .app bundles have minimal PATH)
- **Fixed input monitor dying after first recording** — CGEventTap callback was blocked for up to 5s by synchronous transcription socket wait, causing macOS to disable the tap. Dispatched transcription to background queue.
- **Added tapDisabledByTimeout handler** — safety net to re-enable CGEventTap if macOS disables it
- **Dispatched transcription results to main thread** — UI updates (overlay, text injection) now properly run on main queue

### Improvements
- Pre-warm transcription daemon at app startup (first recording no longer waits for daemon launch)
- Added polish/bugfix backlog to ROADMAP.md (download progress bar, DMG folder icon, accessibility UX)

## 2026-02-11 — Cleanup & Hardening Release

### Documentation
- Rewrote CLAUDE.md to chippy project format (removed generic template boilerplate)
- Populated all claude_docs/ files: ARCHITECTURE, FEATURES, SECURITY, ROADMAP, TESTING
- Updated README.md to reflect current Swift-native architecture

### Critical Stability Fixes
- PythonServiceManager: nil out process refs after terminate, close logHandle, stale socket cleanup, added deinit
- InputMonitor: disable CGEventTap before removing run loop source, added deinit
- UnixSocket: added 30s read/write timeouts, replaced byte-by-byte reads with 4KB buffered reads
- Transcription daemon: consolidated lock around model check + transcription (thread safety)
- LLM daemon: same thread safety pattern for generate/generate_stream
- Overlay: added 5-second auto-hide for error states
- AudioRecorder: added os_unfair_lock for shared state accessed from audio tap callback

### Resource Hardening
- TextInjector: serial DispatchQueue for register access and file I/O
- LogsWindow: bounded file reads (last 100KB only)
- AppLogger: log rotation at 5MB
- SetupWizard: removed orphaned PythonServiceManager (only polls socket readiness)
- AppConfig: wrapped model property reads in queue.sync
- Python daemons: signal handlers installed before socket creation
- Python daemons: graceful executor shutdown with server socket timeout
- AppState: stale socket cleanup at startup

### Dead Code Removal
- Removed 8 legacy Python UI files (~4,000 lines): textecho_app_mac.py, daemon_manager.py, input_monitor_mac.py, text_injector_mac.py, overlay_swift.py, overlay_mac.py, log_config.py, transcribe.py, main.py
- Removed TextEchoOverlay/ (legacy Swift overlay helper, 292KB binary)
- Removed StatusBarController.swift (unused)
- Removed legacy build system: build_app.sh, build_dmg.sh, setup.py
- Removed stale files: dictation_dump.txt, config.example.json, test.wav, test2.wav, launch_recorder.sh, uv.lock
- Trimmed pyproject.toml: removed pyobjc, pyaudio, pynput dependencies
- Organized test files into tests/ directory
- Updated daemon_control_mac.sh (stripped legacy textecho_app_mac.py references)
- Updated .gitignore

### Code Quality
- User-friendly error messages in TranscriptionClient (actionable messages instead of raw socket errors)

## 2026-02-11 — Documentation Scaffold

- Initial claude_docs/ structure created via chippy-scaffold-docs

## 2026-02-06 — Native Swift App

- Swift menu bar app replaces Python UI
- Embedded Python venv in .app bundle
- All macOS-only (Linux/GNOME artifacts removed)
