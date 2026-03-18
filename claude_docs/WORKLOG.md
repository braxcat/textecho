# Worklog

## 2026-03-18 — MLX Whisper Upgrade Session

**Focus:** Replace unmaintained lightning-whisper-mlx with mlx-whisper, upgrade to large-v3-turbo model

### Library Swap
- Researched MLX whisper ecosystem: lightning-whisper-mlx (dead, April 2024), mlx-whisper (active, v0.4.3), mlx-audio (active, broader)
- Chose mlx-whisper — drop-in Whisper replacement, actively maintained, supports large-v3-turbo
- Updated pyproject.toml: `lightning-whisper-mlx` → `mlx-whisper>=0.4.0`
- Updated build_native_app.sh pip install line
- Updated PythonServiceManager.swift comment

### Daemon Rewrite
- Rewrote transcription_daemon_mlx.py to use `mlx_whisper.transcribe()` API
- New default models: `mlx-community/whisper-large-v3-turbo` (single/fast), `mlx-community/whisper-large-v3-mlx` (accurate)
- Removed LightningWhisperMLX class instantiation — mlx-whisper uses a functional API
- Removed batch_size/quant config (mlx-whisper handles internally)
- Preload now uses dummy silent WAV to trigger model download/cache
- Preserved all existing features: hallucination filtering, silence detection, IPC protocol, idle unload

### Deployment
- Created feature branch `feature/mlx-whisper-turbo`, pushed to GitHub
- Merged via PR #1, cleaned up branch
- Tested on M4 Max 36GB — model downloads ~1.6GB on first use, cached at ~/Library/Caches/TextEcho/hf/

## 2026-02-12 — Distribution & Bug Fix Session

**Focus:** App icon bundling, DMG rebuild, fix critical runtime bugs (ffmpeg PATH, CGEventTap timeout)

### Icon & DMG
- Copied TextEcho.icns to .app/Contents/Resources/ in build_native_app.sh
- Added CFBundleIconFile to Info.plist heredoc
- Rebuilt DMG with all fixes
- Updated README with "Install from DMG" instructions

### Bug Fix: ffmpeg not found
- Root cause: lightning-whisper-mlx calls `ffmpeg` as subprocess; .app bundles from Finder have minimal PATH excluding /opt/homebrew/bin
- Fix: PythonServiceManager.launchPython() prepends Homebrew paths to PATH env var

### Bug Fix: Input dies after first recording
- Root cause: recorder.stop() calls completion synchronously on main run loop → transcribe() blocks up to 5s in waitForTranscriptionSocket() → macOS disables CGEventTap (timeout)
- Fix: Dispatch transcribe() to DispatchQueue.global(qos: .userInitiated)
- Safety net: Handle .tapDisabledByTimeout to re-enable tap
- Also dispatch transcription results back to main thread for UI/paste operations

### Daemon Pre-warming
- ensureTranscriptionDaemon() now called at startup on utility queue
- First recording no longer waits for daemon to launch + model to load

### Merged to master
- Fast-forward merge of major_change-mac_native → master, rebased over remote, pushed

## 2026-02-11 — Cleanup & Hardening Session

**Focus:** Technical debt cleanup, stability fixes, dead code removal

### Phase 1: Documentation Alignment
- Rewrote CLAUDE.md from generic template to chippy project format
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
- Ran chippy-scaffold-docs to create claude_docs/ structure
