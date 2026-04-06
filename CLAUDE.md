# TextEcho

Native macOS menu bar app for voice-to-text dictation. Dual transcription engines: **Parakeet TDT** (default, via FluidAudio SDK) and **WhisperKit** — both run on Core ML / Apple Neural Engine. Fully native Swift, no Python needed. Native local LLM processing via **MLX** (6 models, 4 modes, Shift+Middle-click). No cloud, no network after model download, fully offline.

### Documentation Index

| Document                                                   | Purpose                                           | Update when...                |
| ---------------------------------------------------------- | ------------------------------------------------- | ----------------------------- |
| [README.md](README.md)                                     | Project overview, installation, usage             | Features or setup changes     |
| [claude_docs/ARCHITECTURE.md](claude_docs/ARCHITECTURE.md) | System design, transcription flow, build pipeline | Architectural changes         |
| [claude_docs/CHANGELOG.md](claude_docs/CHANGELOG.md)       | Release history                                   | After each deploy             |
| [claude_docs/FEATURES.md](claude_docs/FEATURES.md)         | Feature inventory                                 | Any feature ships/changes     |
| [claude_docs/PLANNING.md](claude_docs/PLANNING.md)         | Future features, research                         | New ideas or research         |
| [claude_docs/ROADMAP.md](claude_docs/ROADMAP.md)           | Phase plan + future work                          | Planning or completing phases |
| [claude_docs/SECURITY.md](claude_docs/SECURITY.md)         | Permissions, signing, data handling               | Security changes              |
| [claude_docs/TESTING.md](claude_docs/TESTING.md)           | Test strategy                                     | Test stack changes            |
| [claude_docs/WORKLOG.md](claude_docs/WORKLOG.md)           | Dev session log                                   | After each session            |
| [docs/SIGNING.md](docs/SIGNING.md)                         | Code signing, notarization, secret rotation       | Signing or release changes    |

## Quick Start

**Prerequisites:** macOS 14+, Apple Silicon, Xcode CLI tools

```bash
# Build the native app (pure Swift, no Python needed)
./build_native_app.sh

# Deploy to /Applications
cp -R dist/TextEcho.app /Applications/ && open /Applications/TextEcho.app
```

Grant **Accessibility** and **Microphone** permissions in System Settings when prompted.

On first launch, choose a transcription model (~1.6GB download for recommended model).

## Commands

| Command                            | Description                                                                                 |
| ---------------------------------- | ------------------------------------------------------------------------------------------- |
| `./install_dev.sh`                 | **Dev workflow**: debug build, kill, deploy to /Applications, reset Accessibility, relaunch |
| `./reset_accessibility.sh`         | Reset Accessibility permission after a rebuild invalidates the signature                    |
| `./build_native_app.sh`            | Release build — outputs to `dist/TextEcho.app`                                              |
| `./build_native_app.sh --debug`    | Debug build — faster incremental rebuilds, outputs to `dist/TextEcho.app`                   |
| `./build_native_app.sh --sign`     | Release build with Developer ID signing + hardened runtime + notarization                   |
| `./build_native_app.sh --with-llm` | Build with bundled Python LLM (legacy — MLX is built-in)                                    |
| `./build_native_dmg.sh`            | Create distributable DMG                                                                    |

## Architecture

```
TextEcho.app (Swift)
├── AppMain → AppState (orchestrator)
├── InputMonitor (CGEventTap → hotkeys, 30s health check timer)
├── AudioRecorder (AVAudioEngine → PCM, onAudioBuffer for streaming chunks)
├── Transcriber protocol (batch backend, swappable)
│   ├── ParakeetTranscriber (FluidAudio TDT V3 → Core ML, default)
│   └── WhisperKitTranscriber (WhisperKit → Core ML, fallback)
├── StreamingTranscriber protocol (streaming backend, opt-in)
│   └── StreamingEouAsrManager (FluidAudio EOU 120M, 160ms chunks, partial callbacks)
├── StreamDeckPedalMonitor (IOKit HID, exponential backoff retry)
├── TrackpadMonitor (IOKit HID, disabled by default)
├── Overlay (SwiftUI floating window, .streamingPartial state for ghost text)
├── TextInjector (clipboard + Cmd+V paste)
├── HelpWindow (embedded user docs)
└── MLXLLMProcessor (native MLX LLM, 6 models, 4 modes)
```

Transcription and LLM processing are fully native Swift — no IPC, no temp files, no Python process.

## Key Configuration

`~/.textecho_config` (JSON):

| Field                  | Default                                    | Description                                            |
| ---------------------- | ------------------------------------------ | ------------------------------------------------------ |
| `trigger_button`       | `2`                                        | Mouse button (2=middle)                                |
| `dictation_keycode`    | `2`                                        | Keyboard trigger (2=D key)                             |
| `silence_duration`     | `2.5`                                      | Seconds before auto-stop                               |
| `transcription_engine` | `parakeet`                                 | Engine: `parakeet` or `whisper`                        |
| `parakeet_model`       | `parakeet-tdt-v3`                          | Parakeet model: `parakeet-tdt-v3` or `parakeet-tdt-v2` |
| `whisper_model`        | `openai_whisper-large-v3_turbo`            | WhisperKit model name                                  |
| `whisper_idle_timeout` | `0`                                        | Seconds before model unloads from RAM (0=never)        |
| `llm_enabled`          | `false`                                    | Enable LLM processing (requires --with-llm build)      |
| `llm_model`            | `mlx-community/Llama-3.2-3B-Instruct-4bit` | MLX LLM model (HuggingFace repo ID)                    |
| `llm_mode`             | `clean`                                    | LLM mode: `clean`, `fix`, `expand`, `custom`           |
| `llm_custom_prompt`    | `""`                                       | Custom system prompt for `custom` mode                 |
| `streaming_enabled`    | `false`                                    | Enable streaming transcription Beta (EOU 120M model)   |
| `trackpad_enabled`     | `false`                                    | Enable Magic Trackpad as dictation trigger             |
| `trackpad_gesture`     | `force_click`                              | Trackpad gesture: `force_click` or `right_click`       |
| `trackpad_mode`        | `hold`                                     | Trackpad mode: `hold` or `toggle`                      |

## Hotkeys

| Action                        | Hotkey                                    |
| ----------------------------- | ----------------------------------------- |
| Transcribe & paste (mouse)    | Middle-click (hold to record)             |
| Transcribe & paste (keyboard) | Ctrl+D (hold to record)                   |
| LLM prompt (mouse)            | Shift + Middle-click                      |
| LLM prompt (keyboard)         | Ctrl+Shift+D                              |
| Save clipboard to register    | Cmd+Option+[1-9]                          |
| Clear all registers           | Cmd+Option+0                              |
| Settings dialog               | Cmd+Option+Space                          |
| Transcribe & paste (trackpad) | Force click or right-click (configurable) |
| Cancel recording              | ESC                                       |

## Development Guidelines

- **macOS 14+ only** — Apple Silicon (ARM64), required by WhisperKit and FluidAudio
- **No Python needed** — pure Swift for everything including LLM
- **Do NOT auto-install deps** — no sudo, no pip install, no downloads
- Lazy model loading, auto-unload after idle timeout
- WhisperKit models cached at `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`
- All transcription runs via actor isolation (no shared mutable state)
- CGEventTap callbacks must return fast — all async work dispatched off main thread

## Known Gotchas

### macOS 14 Minimum

WhisperKit requires macOS 14+ for Core ML Neural Engine support. All Apple Silicon Macs support macOS 14.

### CGEventTap Gotcha

**CGEventTap callbacks MUST return fast** — macOS disables the tap if callback blocks too long. All WhisperKit transcription runs via `Task(priority:)` off the main thread.

### Accessibility Permission Annoyance

**Ad-hoc code signing changes the signature every rebuild** — macOS invalidates Accessibility grant when signature changes. User must re-grant in System Settings.

### Model Download on First Launch

First launch requires internet to download the WhisperKit Core ML model (~1.6GB for large-v3-turbo). After that, the app is fully offline.

## Project Structure

```
dictation-mac/
├── mac_app/                          # Swift app (SwiftPM package)
│   ├── Package.swift                 # WhisperKit + FluidAudio dependencies, macOS 14+
│   ├── TextEcho.entitlements         # Hardened runtime entitlements (non-sandboxed)
│   └── Sources/TextEchoApp/
│       ├── AppMain.swift             # Entry point, menu bar setup
│       ├── AppState.swift            # Orchestrator (recording flow)
│       ├── AppConfig.swift           # ~/.textecho_config reader
│       ├── Transcriber.swift         # Protocol for transcription backends
│       ├── ParakeetTranscriber.swift   # Parakeet TDT transcription via FluidAudio (actor, default)
│       ├── WhisperKitTranscriber.swift # Native WhisperKit transcription (actor, fallback)
│       ├── MLXLLMProcessor.swift      # Native MLX LLM (6 models, 4 modes)
│       ├── InputMonitor.swift        # CGEventTap hotkey detection
│       ├── AudioRecorder.swift       # AVAudioEngine recording
│       ├── Overlay.swift             # SwiftUI floating overlay
│       ├── TextInjector.swift        # Clipboard + Cmd+V paste
│       ├── SetupWizard.swift         # First-launch wizard (permissions + model)
│       ├── SettingsWindow.swift      # Settings UI (model picker, key bindings)
│       ├── HelpWindow.swift          # In-app user documentation
│       ├── LogsWindow.swift          # Log viewer UI
│       ├── LaunchdManager.swift      # Autostart via launchd
│       ├── AccessibilityHelper.swift # AX permission checks
│       ├── MicrophoneHelper.swift    # Mic permission checks
│       ├── UninstallManager.swift    # Cleanup helper
│       ├── RestoreWindow.swift       # Window restore helper
│       ├── StreamDeckPedalMonitor.swift # IOKit HID pedal monitor
│       ├── TrackpadMonitor.swift      # IOKit HID Magic Trackpad monitor
│       ├── TextEchoApp.swift         # @main SwiftUI app + menu bar
│       └── AppLogger.swift           # File logging
├── .github/
│   ├── workflows/release.yml        # Signed release pipeline (triggered by v* tags)
│   └── CODEOWNERS                   # Require review on workflow/signing changes
├── build_native_app.sh               # Build script (--sign for signing, --with-llm for MLX LLM)
├── build_native_dmg.sh               # DMG creation script (--sign for signed DMG)
├── docs/SIGNING.md                  # Code signing architecture and secret rotation
└── claude_docs/                      # Project documentation
```

## Conventions

- Transcription logic lives in `ParakeetTranscriber` (default) and `WhisperKitTranscriber` (fallback), both actor-isolated
- LLM is fully optional — guard all LLM code paths with `llmAvailable` check (native MLX, no Python)
- Config backward compatible — new fields have defaults, old fields preserved
- No temp files for transcription — WhisperKit accepts float arrays directly
- **Break all user requests into tracked tasks** using TodoWrite before starting work, so progress is visible and nothing is missed
- **After any code change, run `./install_dev.sh`** so the updated app is deployed and ready for the user to test immediately
- After completing anything that could be considered a self-contained bug fix or feature, prompt the user to ask if a commit should be made for that change.
