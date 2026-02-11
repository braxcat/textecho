# Roadmap

## Phase Summary

| Phase | Status | Description |
|-------|--------|-------------|
| 1 | COMPLETE | Documentation Alignment — devax methodology |
| 2 | COMPLETE | Critical Stability Fixes — process lifecycle, socket timeouts, thread safety |
| 3 | COMPLETE | Resource Management Hardening — log rotation, graceful shutdown, thread safety |
| 4 | COMPLETE | Dead Code Removal — 4,500+ lines of legacy Python UI, stale files |
| 5 | COMPLETE | Code Quality — user-friendly errors, final docs |
| 6 | PLANNED | Distribution — DMG signing, notarization, auto-update |
| 7 | PLANNED | Enhanced Transcription — multi-language, speaker diarization |
| 8 | PLANNED | LLM Improvements — conversation memory, model switching |

## Phase 1: Documentation Alignment
**Status:** COMPLETE

Aligned TextEcho with devax documentation methodology:
- Rewrote CLAUDE.md to match wombat-wise/fbar-bot format
- Populated all claude_docs/ files (ARCHITECTURE, FEATURES, SECURITY, etc.)
- Updated README.md to reflect Swift-native architecture
- Removed generic template boilerplate

## Phase 2: Critical Stability Fixes
**Status:** COMPLETE

- PythonServiceManager: nil out process refs after terminate, close logHandle, stale socket cleanup, deinit
- InputMonitor: disable CGEventTap before removing run loop source, deinit
- UnixSocket: 30s SO_RCVTIMEO/SO_SNDTIMEO, 4KB buffered reads
- Transcription daemon: consolidated lock for model check + transcription
- LLM daemon: same thread safety pattern
- Overlay: 5-second auto-hide on errors
- AudioRecorder: os_unfair_lock for shared state

## Phase 3: Resource Management Hardening
**Status:** COMPLETE

- TextInjector: serial DispatchQueue for register access
- LogsWindow: read only last 100KB via FileHandle seek
- AppLogger: rotate when file exceeds 5MB
- SetupWizard: removed orphaned PythonServiceManager, polls socket only
- AppConfig: wrapped model reads in queue.sync
- Python daemons: signal handlers before socket creation, graceful executor shutdown
- AppState: stale socket cleanup at startup

## Phase 4: Dead Code Removal
**Status:** COMPLETE

Removed ~4,500 lines of dead legacy code and stale files.

## Phase 5: Code Quality
**Status:** COMPLETE

- User-friendly error messages in TranscriptionClient
- Final documentation pass

## Phase 6+: Future Work (TBD)

- DMG signing and notarization for distribution
- Auto-update mechanism
- Multi-language transcription support
- Speaker diarization
- LLM conversation memory across sessions
- Model management UI (download/switch models)
