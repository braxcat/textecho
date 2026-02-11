# Worklog

## 2026-02-11 — Cleanup & Hardening Session

**Focus:** Technical debt cleanup, stability fixes, dead code removal

### Phase 1: Documentation Alignment
- Rewrote CLAUDE.md from generic template to devax project format
- Populated ARCHITECTURE.md with component diagram, IPC protocol, build pipeline
- Populated FEATURES.md with complete feature inventory
- Populated SECURITY.md with permissions, signing, data handling
- Populated ROADMAP.md with 5-phase cleanup plan
- Updated README.md

### Phase 2: Critical Stability Fixes
- Fixed PythonServiceManager process lifecycle (nil refs, close handles, deinit)
- Fixed InputMonitor CGEventTap disable-on-stop ordering
- Added 30s socket timeouts and 4KB buffered reads to UnixSocket
- Fixed thread safety in transcription_daemon_mlx.py (consolidated lock)
- Fixed thread safety in llm_daemon.py (consolidated lock)
- Added 5-second auto-hide to Overlay.showError()
- Added os_unfair_lock to AudioRecorder for shared state

### Phase 3: Resource Hardening
- Added serial DispatchQueue to TextInjector for register access
- Bounded LogsWindow file reads to last 100KB
- Added 5MB log rotation to AppLogger
- Fixed SetupWizard orphaned daemon (removed separate PythonServiceManager)
- Wrapped AppConfig model reads in queue.sync
- Moved Python signal handlers before socket creation
- Added graceful executor shutdown with server socket timeout
- Added stale socket cleanup in AppState.start()

### Phase 4: Dead Code Removal
- Deleted 8 legacy Python files (~4,000 lines)
- Deleted TextEchoOverlay/ directory (legacy Swift overlay helper)
- Deleted StatusBarController.swift
- Deleted legacy build scripts (build_app.sh, build_dmg.sh, setup.py)
- Deleted stale files (dumps, test audio, lock files)
- Trimmed pyproject.toml (removed PyObjC, pyaudio, pynput)
- Organized test files into tests/
- Cleaned up daemon_control_mac.sh and .gitignore

### Phase 5: Code Quality
- Mapped raw socket errors to user-friendly messages in TranscriptionClient
- Final documentation pass

## 2026-02-11 — Documentation Scaffold
- Ran devax-scaffold-docs to create claude_docs/ structure
