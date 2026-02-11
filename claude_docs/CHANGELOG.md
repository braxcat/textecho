# Changelog

## 2026-02-11 — Cleanup & Hardening Release

### Documentation
- Rewrote CLAUDE.md to devax project format (removed generic template boilerplate)
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

- Initial claude_docs/ structure created via devax-scaffold-docs

## 2026-02-06 — Native Swift App

- Swift menu bar app replaces Python UI
- Embedded Python venv in .app bundle
- All macOS-only (Linux/GNOME artifacts removed)
