# Worklog

## 2026-03-29 — Signed Release Pipeline

**Focus:** Developer ID code signing, notarization, GitHub Actions release workflow, security hardening

### Code Signing
- Created `mac_app/TextEcho.entitlements` (non-sandboxed + disable-library-validation)
- Updated `build_native_app.sh` — `--sign` flag for Developer ID signing with hardened runtime
- Updated `build_native_dmg.sh` — `--sign` flag for signed + notarized DMG
- Notarization via App Store Connect API key (not app-specific password)

### Release Workflow
- Created `.github/workflows/release.yml` — triggered by `v*` tags
- Full pipeline: build → sign → notarize → staple → DMG → GitHub Release → Sigstore attestation
- Ephemeral keychain for certificate handling (created and destroyed in workflow)
- All third-party actions SHA-pinned

### Security Hardening
- GitHub Environment with required approval before release jobs
- Tag protection rules for `v*` tags
- `.github/CODEOWNERS` — require review on workflow and signing file changes
- `docs/SIGNING.md` — signing architecture and secret rotation documentation

## 2026-03-22 — Theme Customization + Swift CI

**Focus:** Theme presets, custom color picker, CI workflow, dependency updates

### Theme System (PR #7)
- 5 built-in presets: TextEcho, Cyber, Classic, Ocean, Sunset
- Full color picker UI in Settings for custom themes
- Save/load/delete user presets (~/.textecho_themes.json)
- Fixed overlay not reading from config (was hardcoded)
- Menu bar tooltip showing recording status
- Settings save button for explicit persistence
- CodeQL fix: @MainActor on TextEchoApp deinit

### Swift CI
- Created `.github/workflows/swift-ci.yml` — `swift test` + `swift build -c release` on PRs to main
- Uses macos-latest + actions/checkout@v6

### Dependency Updates
- Merged Dependabot PRs #4 (actions/checkout v6) and #5 (codeql-action v4)

### GitHub Security
- Enabled Dependency graph, Dependabot alerts, Dependabot security updates, Code scanning

## 2026-03-20 — UX Polish & Cyberpunk Overlay

**Focus:** Per-pedal actions, auto-detect, Settings persistence, overlay redesign, setup wizard

### Stream Deck Pedal
- Added per-pedal callbacks: center=push-to-talk, left=paste, right=enter
- Fixed audio capture from pedal: deferred engine.start() via DispatchQueue.main.async (IOKit HID callback was blocking AVAudioEngine)
- Added 3-second auto-detect retry timer — no unplug/replug needed
- Auto-reconnect on disconnect
- Added detectConnectedPedals() static method for one-shot USB check
- Pedal toggle + position picker in Settings UI, persists across saves

### Overlay Redesign
- Cyberpunk aesthetic: deep blue-black glassmorphic background
- Color flow: Pink (magenta) → Electric Purple → Neon Green (matrix #33FF33)
- Waveform: magenta-to-green gradient, 60pt bars, green glow shadows
- Logo: silver TEXT + neon green ECHO with glow
- Model badge: "WHISPER // LARGE V3 TURBO" at bottom
- Full transcription visible (removed 4-line limit)
- Smart auto-hide: 1.5s base + text length scaling, max 4s
- Fixed overlay drop-out: proper auto-hide cancellation, orderFrontRegardless(), canJoinAllSpaces

### Setup Wizard Redesign
- 6 steps: Welcome → Accessibility → Microphone → Model → Pedal → Ready
- Progress dots, back buttons, restart helper
- Pedal detection step with auto-scan

### Model & Config Fixes
- Fixed model names: HF repo uses `openai_whisper-large-v3_turbo` (underscore, not hyphen)
- Fixed cache detection: models at `~/Documents/huggingface/models/` not `~/Library/Caches/`
- Model name migration on config load (old short names auto-fix)
- Error display in Settings manage models + Setup Wizard

### Scripts
- Created `rebuild.sh` — one-command pull + build + deploy + launch
- Added `--clean` flag to `build_native_app.sh`
- Updated `uninstall.sh` — removes WhisperKit models + registers

## 2026-03-20 — Native WhisperKit Migration

**Focus:** Replace Python MLX Whisper daemon with native Swift WhisperKit for transcription

### Phase 1: Foundation
- Created `Transcriber.swift` protocol for swappable backends
- Created `WhisperKitTranscriber.swift` actor — PCM conversion, silence detection, hallucination filter, resampling, model lifecycle, 30s timeout
- Updated `Package.swift` — added WhisperKit 0.9.0+ dependency, bumped macOS 13 → 14
- Ported all transcription logic from Python to Swift (audio conversion, RMS, hallucination phrases, resampling)

### Phase 2: Integration
- Rewrote `AppState.swift` — replaced socket IPC with async/await WhisperKit calls, pre-warms model on start
- Slimmed `PythonServiceManager.swift` — LLM-only, removed transcription process management
- Added `whisperModel` and `whisperIdleTimeout` to `AppConfig.swift` with `llmAvailable` computed property
- Rewrote `SetupWizard.swift` — model picker with 3 options, cached status badges, download flow
- Rewrote `SettingsWindow.swift` — transcription model section, conditional LLM section
- Added downloading state to `Overlay.swift`

### Phase 3: Cleanup
- Deleted `transcription_daemon_mlx.py` (436 lines Python)
- Renamed `TranscriptionClient.swift` → `UnixSocket.swift`, deleted TranscriptionClient class
- Updated `build_native_app.sh` — pure Swift default, `--with-llm` flag for optional Python/LLM
- Updated `pyproject.toml` — removed mlx-whisper/numpy/soundfile, LLM deps optional only
- Created `HelpWindow.swift` — embedded user documentation (8 sections)
- Added Help menu item to `TextEchoApp.swift`
- Updated all claude_docs, CLAUDE.md, README.md

### Key decisions
- WhisperKit actor isolation for thread safety (no shared mutable state)
- 30s timeout wrapper on transcribe() to prevent infinite hangs
- Model name sanitization (alphanumeric + hyphens/dots/slashes only)
- Idle timeout clamped to 60s–86400s range
- LLM completely optional — default install is zero Python

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
- Tested on M4 Max 36GB — model downloads ~1.6GB on first use

## 2026-02-12 — Distribution & Bug Fix Session

**Focus:** App icon bundling, DMG rebuild, fix critical runtime bugs (ffmpeg PATH, CGEventTap timeout)

### Bug Fix: ffmpeg not found
- Root cause: lightning-whisper-mlx calls `ffmpeg` as subprocess; .app bundles from Finder have minimal PATH excluding /opt/homebrew/bin
- Fix: PythonServiceManager.launchPython() prepends Homebrew paths to PATH env var

### Bug Fix: Input dies after first recording
- Root cause: recorder.stop() calls completion synchronously on main run loop → transcribe() blocks up to 5s in waitForTranscriptionSocket() → macOS disables CGEventTap (timeout)
- Fix: Dispatch transcribe() to DispatchQueue.global(qos: .userInitiated)
- Safety net: Handle .tapDisabledByTimeout to re-enable tap

## 2026-02-11 — Cleanup & Hardening Session

**Focus:** Technical debt cleanup, stability fixes, dead code removal (4,500+ lines)

## 2026-02-11 — Documentation Scaffold
- Ran chippy-scaffold-docs to create claude_docs/ structure
