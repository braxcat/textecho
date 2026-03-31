# Changelog

## 2026-03-29 — Native MLX LLM Integration

### MLX Swift LLM
- **Replaced Python LLM daemon with native MLX Swift** — deleted PythonServiceManager.swift, LLMClient.swift, UnixSocket.swift; llm_daemon.py no longer needed
- **MLXLLMProcessor.swift** — new actor using MLXLLM + MLXLMCommon for local inference on Apple Silicon GPU
- **6 curated models:** Qwen 3.5 9B/4B, Gemma 3 12B/4B, Qwen 2.5 Coder 7B, Llama 3.3 8B
- **4 LLM modes:** Grammar Fix, Rephrase, Answer, Custom prompt

### Activation & UI
- **Shift+Middle-click** triggers LLM mode (same as Ctrl+Shift+D)
- **llmAutoPaste** option — display LLM result without auto-pasting
- Settings UI: engine toggle, model picker, mode picker, custom prompt editor, auto-paste toggle

### Security
- maxTokens=2048 limit on LLM output
- Model ID validation against curated list
- Config file 0o600 permissions
- Custom prompt length cap
- No network after model download — fully offline inference

## v2.2.0 (2026-03-29) — Parakeet TDT Transcription Engine

### Dual-Engine Transcription
- **Parakeet TDT v3** added as default transcription engine via FluidAudio SDK
- Evaluated every major local STT model available in 2026 (Whisper variants, Distil-Whisper, Moonshine, NVIDIA Canary/Parakeet, Apple SpeechAnalyzer, MLX Whisper) — Parakeet TDT v3 was the clear winner: 2.1% WER vs Whisper's 7.8% (3.7x more accurate), 3-6x faster inference, smaller model (600M vs 809M params)
- Only model with Core ML support, a Swift SDK (FluidAudio), and better accuracy than Whisper combined
- Runs on Apple Neural Engine via Core ML (all Apple Silicon M1-M4, macOS 14+)
- WhisperKit retained as fallback for rare language support (99 languages vs Parakeet's 25) — user selects in Setup Wizard or Settings

### New Files
- **`ParakeetTranscriber.swift`** — actor conforming to Transcriber protocol, FluidAudio SDK integration
- **FluidAudio** dependency added to `Package.swift` (Apache 2.0 license)

### Config & UI
- New config fields: `transcription_engine` (`parakeet` / `whisper`), `parakeet_model` (`parakeet-tdt-v3` / `parakeet-tdt-v2`)
- `AppState` selects transcriber based on `transcription_engine` config field
- Setup Wizard: engine picker step (Parakeet recommended, Whisper fallback)
- Settings: engine picker and Parakeet model selector

### Licensing
- Parakeet TDT model weights: CC-BY-4.0 (NVIDIA, attribution required)
- FluidAudio SDK: Apache 2.0, 1,763 GitHub stars, actively maintained

## 2026-03-29 — Signed Release Pipeline

### Code Signing & Notarization
- **Developer ID signing** with hardened runtime in `build_native_app.sh` and `build_native_dmg.sh` (`--sign` flag)
- **Apple notarization** via App Store Connect API key — no Gatekeeper warnings for end users
- **Entitlements file** (`mac_app/TextEcho.entitlements`) — non-sandboxed, `audio-input` (microphone) + `network.client` (WhisperKit model download)
- **Sigstore build attestation** — verifiable build provenance on GitHub Releases

### GitHub Actions Release Workflow
- **`.github/workflows/release.yml`** — triggered by `v*` tags: build, sign, notarize, DMG, publish
- **Security hardening:** ephemeral keychain, SHA-pinned actions, GitHub Environment with approval gate
- **Tag protection** and **CODEOWNERS** (`.github/CODEOWNERS`) for workflow/signing file changes

### Build Script Updates
- `build_native_app.sh` — `--sign` flag for Developer ID signing + hardened runtime + entitlements
- `build_native_dmg.sh` — `--sign` flag for signed + notarized DMG

## 2026-03-28 — Event Tap Resilience, Pedal Backoff, Magic Trackpad Support

### Event Tap Health Check
- **30-second health check timer** in InputMonitor.swift detects when macOS invalidates the CGEventTap mach port during long idle periods
- Automatically recreates the tap — previously required an app restart

### Pedal Retry Backoff
- Changed StreamDeckPedalMonitor retry timer from constant 3s polling to **exponential backoff** (3s → 6s → 12s → ... capped at 60s)
- Reduced log noise: only logs on first scan and every 10th attempt

### Magic Trackpad Support
- **New activation method:** Apple Magic Trackpad as dictation trigger via IOKit HID
- Supports **force click** or **right-click** gestures
- **Toggle or hold** mode (matches other activation methods)
- Matches all Magic Trackpad models by Apple vendor/product ID
- Settings UI: enable toggle, gesture picker, mode picker
- **Disabled by default** — IOKit HID approach does not reliably detect force click yet; right-click gesture works
- **New files:** TrackpadMonitor.swift, updates to AppConfig.swift, AppState.swift, SettingsWindow.swift

## 2026-03-22 — Theme Customization + Swift CI (PR #7)

### Theme System
- **5 built-in presets:** TextEcho (original cyan-blue), Cyber, Classic, Ocean, Sunset
- **Custom colors:** full color picker UI in Settings for background, text, accent, waveform
- **User presets:** save/load/delete custom themes (~/.textecho_themes.json)
- **Overlay integration:** overlay reads theme colors from config, updates live
- **Menu bar tooltip:** shows recording status
- **Settings save button:** explicit save for settings changes

### CI/CD
- **Swift CI workflow** (`.github/workflows/swift-ci.yml`) — `swift test` + `swift build -c release` on every PR to main
- Uses `macos-latest` runner with `actions/checkout@v6`
- Complements existing CodeQL weekly SAST scan

### Bug Fixes
- Fixed overlay not reading theme colors from config (was using hardcoded values)
- CodeQL fix: `@MainActor` wrapper in `TextEchoApp.deinit`

### Dependency Updates (Dependabot)
- `actions/checkout` v4 → v6 (PR #4)
- `github/codeql-action` v3 → v4 (PR #5)

## 2026-03-22 — PR #2 Merge + Security/Memory Fixes

### PR #2 Merge (by Lochie / MachinationsContinued)
- **Model management** — download, switch, delete models from Settings + Setup Wizard
- **Settings rework** — activation cards for Caps Lock, mouse, keyboard, pedal with toggle/hold modes
- **Transcription history** — save, review, re-copy transcriptions; menu bar quick access
- **Overlay redesign** — improved layout and state display
- **New files:** HistoryWindow.swift, ModelPickerView.swift, TranscriptionHistory.swift
- **+2427/-725 lines across 20 files, 23 commits**

### Security Fixes (post-merge review)
- **HIGH — Shell injection:** Replaced bash `-c` with direct `Process` call in `restartApp()`
- **HIGH — Thread safety:** Added `@MainActor` to `AppState`, `Task.detached` for background work
- **MEDIUM — File permissions:** Transcription history now 0600 + atomic writes
- **MEDIUM — Config writes:** `AppConfig.save()` now uses atomic writes
- **MEDIUM — Memory leak:** WhisperKitTranscriber instances explicitly nilled after use in SetupWizard
- **MEDIUM — Observer leak:** NotificationCenter observers stored and removed in `AppModel.deinit`
- **MEDIUM — Path traversal:** `deleteModel()` rejects model names containing `..` or `/`

### New Features
- **Idle timeout GUI** in Settings — presets: Never / 1hr / 4hr / 8hr / Custom
- **Default idle timeout changed to 0** (never unload) — instant transcription, uses ~1.6GB RAM

### CI/Security
- **CodeQL** weekly SAST scan for Swift (`.github/workflows/codeql.yml`)
- **Dependabot** weekly dependency checks (`.github/dependabot.yml`)

### Tests
- Security unit tests: path traversal rejection, model name sanitization, file permissions

### Documentation
- README updated with activation modes, history, security section, idle timeout
- In-app help updated with toggle/hold modes, history, model management, idle timeout
- claude_docs updated (CHANGELOG, FEATURES, ARCHITECTURE, SECURITY)

## 2026-03-20 — UX Polish & Cyberpunk Overlay

### Stream Deck Pedal
- **Per-pedal actions:** center=push-to-talk, left=paste (Cmd+V), right=enter
- **Auto-detect timer:** 3-second periodic scan — no unplug/replug needed after launch
- **Auto-reconnect:** pedal re-detected automatically after disconnect
- **Settings UI:** pedal enable toggle + position picker, persists across saves

### Overlay Redesign
- **Cyberpunk aesthetic:** deep blue-black background, glassmorphic texture
- **Color flow:** Pink (recording) → Electric Purple (processing) → Neon Green (result)
- **Matrix green (#33FF33):** result text, model badge, ECHO logo
- **Waveform:** magenta-to-green gradient, taller bars (60pt), green glow
- **Logo:** silver TEXT + neon green ECHO
- **Model badge:** "WHISPER // LARGE V3 TURBO" at bottom
- **Smart display time:** 1.5s base + scales with text length, max 4s
- **Full text visible:** no line limit on transcription result
- **Reliability:** proper auto-hide cancellation, orderFrontRegardless(), canJoinAllSpaces

### Setup Wizard
- **6-step walkthrough:** Welcome → Accessibility → Microphone → Model → Pedal → Ready
- **Progress dots** showing current step
- **Back button** on all steps
- **Pedal setup step** with auto-detection and skip option
- **Restart button** on accessibility step

### Scripts & Config
- `rebuild.sh` — one-command pull + build + deploy + launch
- `rebuild.sh --clean` / `--uninstall` variants
- `build_native_app.sh --clean` flag for guaranteed fresh builds
- Updated `uninstall.sh` — removes WhisperKit models + registers
- Model name migration: old config names auto-fix on load
- Fixed model cache detection (HuggingFace Hub path, not Library/Caches)
- Fixed model names to match HF repo directories (underscore before turbo)

### Audio Engine
- Deferred engine start via DispatchQueue.main.async (fixes 0-byte capture from pedal)
- engine.reset() between recordings for clean state

## 2026-03-20 — Native WhisperKit Migration

### Transcription Engine
- **Replaced Python MLX Whisper daemon with native WhisperKit** — transcription now runs entirely in Swift via Apple Neural Engine (Core ML)
- Deleted `transcription_daemon_mlx.py` (436 lines of Python) — no longer needed
- Memory usage: ~1.6GB (down from ~3GB with Python daemon)
- No GPU contention: Neural Engine offloads from GPU (eliminates UI stutter during inference)
- No temp files: WhisperKit accepts float arrays directly (no WAV write/read cycle)

### Architecture Changes
- **New:** `Transcriber.swift` — protocol for swappable transcription backends
- **New:** `WhisperKitTranscriber.swift` — actor with PCM conversion, silence detection, hallucination filtering, resampling, model lifecycle
- **New:** `HelpWindow.swift` — in-app documentation accessible from menu bar
- **Renamed:** `TranscriptionClient.swift` → `UnixSocket.swift` (TranscriptionClient class deleted, UnixSocket enum kept for LLM)
- `AppState.swift` — replaced socket IPC with async/await WhisperKit calls
- `PythonServiceManager.swift` — LLM-only (transcription methods removed)
- `Package.swift` — added WhisperKit dependency, bumped macOS 13 → 14

### LLM Made Optional
- Default build is now **pure Swift** — zero Python dependency
- LLM support via `./build_native_app.sh --with-llm` (creates Python venv with llama-cpp-python)
- Settings UI: LLM/Python sections only visible when LLM module is installed
- `pyproject.toml`: removed mlx-whisper, numpy, soundfile from dependencies

### Setup & UI
- Setup wizard: model picker with 3 options (large-v3-turbo, large-v3, base.en) with size/quality descriptions
- Settings: Transcription Model section with active model picker and Manage Models disclosure group
- Overlay: added "Downloading model..." state (blue) for first-launch model download
- Menu bar: added Help menu item

### Build Script
- `build_native_app.sh`: default is pure Swift build, `--with-llm` flag for Python/LLM
- `LSMinimumSystemVersion`: 13.0 → 14.0 (WhisperKit requires macOS 14)
- `CFBundleVersion`: 1.0 → 2.0

### Config Changes
- New fields: `whisper_model` (default "large-v3-turbo"), `whisper_idle_timeout` (default 3600)
- Existing fields preserved for backward compatibility
- `llmAvailable` computed property checks if llm_daemon.py is bundled

## 2026-03-18 — MLX Whisper Upgrade

### Transcription Engine
- **Replaced `lightning-whisper-mlx` with `mlx-whisper`** — actively maintained library with broader model support
- **Default model upgraded to `large-v3-turbo`** — near large-v3 quality at 8x speed, ideal for M4 Max
- Accurate mode now uses `whisper-large-v3-mlx` (full 1.55B param model)
- Models are now HuggingFace repo IDs (e.g. `mlx-community/whisper-large-v3-turbo`), downloaded and cached automatically
- Removed batch_size and quantization config — mlx-whisper manages this internally
- Updated pyproject.toml, build script, and PythonServiceManager

### Transcription UX
- Empty transcriptions (silence/noise filtered by daemon) now hide the overlay instead of pasting empty string
- Added transcription text and error logging for debugging

### Stream Deck Pedal (WIP)
- Added `StreamDeckPedalMonitor` — IOKit HID integration for Elgato Stream Deck Pedal push-to-talk
- Configurable pedal position (left/center/right) via `pedal_position` config
- Device seize for exclusive access (no Elgato software needed)
- Not yet confirmed working — needs testing with physical hardware

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
- Removed 8 legacy Python UI files (~4,000 lines)
- Removed TextEchoOverlay/ (legacy Swift overlay helper, 292KB binary)
- Removed StatusBarController.swift (unused)
- Removed legacy build system: build_app.sh, build_dmg.sh, setup.py
- Removed stale files: dictation_dump.txt, config.example.json, test.wav, test2.wav, launch_recorder.sh, uv.lock
- Trimmed pyproject.toml: removed pyobjc, pyaudio, pynput dependencies
- Organized test files into tests/ directory

### Code Quality
- User-friendly error messages in TranscriptionClient (actionable messages instead of raw socket errors)

## 2026-02-11 — Documentation Scaffold
- Initial claude_docs/ structure created via chippy-scaffold-docs

## 2026-02-06 — Native Swift App
- Swift menu bar app replaces Python UI
- Embedded Python venv in .app bundle
- All macOS-only (Linux/GNOME artifacts removed)
