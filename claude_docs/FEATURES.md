# Features

## Voice-to-Text Dictation
- Multiple activation methods: Caps Lock, mouse button, keyboard shortcut, Stream Deck Pedal, Magic Trackpad
- Toggle mode (press to start/stop) and Hold mode (hold to record, release to stop)
- Automatic silence detection (configurable threshold + duration)
- Automatic text paste into active window via clipboard + Cmd+V
- Cancel recording with ESC

## Transcription History
- Automatic save of all transcriptions (configurable)
- History window for review and re-copy
- Menu bar quick access to 5 most recent transcriptions
- Configurable max entries (10-1000)
- Stored locally with 0600 file permissions

## Parakeet TDT Transcription (Default)
- **Default engine** — Parakeet TDT v3 via FluidAudio SDK (Core ML / Apple Neural Engine)
- 2.1% WER, 600M params, 3-6x faster than Whisper, 25 European languages
- Available models: Parakeet TDT v3 (default), Parakeet TDT v2 (English-only)
- Runs on all Apple Silicon Macs (M1-M4), macOS 14+
- Model weights licensed CC-BY-4.0 (NVIDIA)

## WhisperKit Transcription (Fallback)
- Apple Silicon native via WhisperKit (Core ML / Apple Neural Engine)
- No Python process — runs entirely in Swift
- Default Whisper model: large-v3-turbo (~1.6GB download, ~1.6GB RAM, 7.8% WER)
- Available models: large-v3 (highest quality), base.en (fastest, smallest)

## Shared Transcription Features
- Engine selection in Setup Wizard and Settings (`transcription_engine` config field)
- Model selection per engine in Setup Wizard and Settings
- Models cached locally after first download — fully offline after that
- Lazy model loading — first use downloads/loads, subsequent uses instant
- Configurable idle timeout: Never / 1hr / 4hr / 8hr / Custom (default: Never — stays loaded)
- Hallucination filtering (17 known phrases + repeated segment detection)
- RMS silence detection (skip transcription if audio too quiet)
- 30-second timeout on inference to prevent indefinite hangs

## Native MLX LLM Processing
- **Native MLX Swift** via MLXLLM + MLXLMCommon — GPU inference on Apple Silicon, no Python
- **6 curated models:** Qwen 3.5 9B/4B, Gemma 3 12B/4B, Qwen 2.5 Coder 7B, Llama 3.3 8B
- **4 modes:** Grammar Fix (correct grammar/spelling), Rephrase (reword), Answer (respond to question), Custom prompt
- **Activation:** Shift+Middle-click or Ctrl+Shift+D (transcribe then process with LLM)
- **llmAutoPaste** option — display result in overlay without auto-pasting
- Settings UI: engine toggle, model picker, mode picker, custom prompt editor, auto-paste toggle
- maxTokens=2048 limit, model ID validation, config file 0o600 permissions
- Models cached locally after first download — fully offline after that

## Theme Customization
- 5 built-in presets: TextEcho (original cyan-blue), Cyber, Classic, Ocean, Sunset
- Full color picker in Settings: background, text, accent, waveform colors
- Save/load/delete custom user presets stored at `~/.textecho_themes.json`
- Live overlay preview when changing themes
- Built-in presets cannot be deleted; user presets can be

## Cyberpunk Overlay UI
- Floating overlay follows cursor during recording
- Real-time waveform visualization (40-bar RMS, magenta→neon green gradient)
- Theme-aware: colors driven by active theme preset
- Silver TEXT + neon green ECHO logo (default TextEcho theme)
- Model badge: "WHISPER // LARGE V3 TURBO" at bottom
- Full transcription text visible (no line limit, auto-expands)
- Smart auto-hide: 1.5s base + scales with text length, max 4s
- Glassmorphic dark background with accent glow borders
- Animated scanner bar during processing
- Pulsing recording indicator

## Stream Deck Pedal
- Elgato Stream Deck Pedal via IOKit HID (shared mode, no Elgato software needed)
- Per-pedal actions: center=push-to-talk, left=paste (Cmd+V), right=enter
- Exponential backoff auto-detect (3s → 6s → 12s → ... capped at 60s) — reduced log noise
- Auto-reconnect after disconnect
- Configurable push-to-talk pedal position (left/center/right)

## Magic Trackpad
- Apple Magic Trackpad as dictation trigger via IOKit HID
- Gesture options: force click or right-click
- Toggle mode (tap to start/stop) and Hold mode (hold to record, release to stop)
- Matches all Magic Trackpad models by Apple vendor/product ID
- Settings UI: enable toggle, gesture picker, mode picker
- **Disabled by default** — IOKit HID approach does not reliably detect force click yet; right-click gesture works

## Setup Wizard
- 6-step walkthrough: Welcome → Accessibility → Microphone → Model → Pedal → Ready
- Progress dots showing current step with back navigation
- Accessibility + microphone permission checks with direct System Settings links
- Model picker with 3 options (size, speed, quality comparison)
- Recommended model pre-selected with cached/not-cached badges
- Pedal setup step with auto-detection and skip option
- Restart button for permission changes
- Re-openable from menu bar

## Settings Panel
- Activation method cards: Caps Lock, mouse, keyboard, pedal — each with toggle/hold mode
- Audio settings (silence duration, silence threshold, sample rate, input device)
- Transcription model picker (active model, manage/download/delete models)
- Model memory (idle timeout): Never / 1hr / 4hr / 8hr / Custom presets
- Transcription history: enable/disable, menu bar display, max entries
- Overlay position: fixed or follow cursor
- Stream Deck Pedal toggle + position picker
- LLM configuration: engine toggle, model picker (6 curated), mode picker (4 modes), custom prompt editor, auto-paste toggle
- Dirty tracking with unsaved changes indicator
- Confirm dialog on close with unsaved changes

## In-App Help
- Accessible from menu bar → Help
- Getting Started, How to Dictate, Keyboard Shortcuts
- Stream Deck Pedal setup, Settings reference, Troubleshooting
- Model selection guide, LLM module instructions
- Embedded in binary — works offline

## Signed Distribution
- Developer ID code signing with hardened runtime
- Apple notarization via App Store Connect API key — no Gatekeeper warnings
- Sigstore build attestation for verifiable build provenance
- GitHub Actions release workflow — build, sign, notarize, publish on version tags
- Signed DMG available from GitHub Releases

## System Integration
- Autostart via launchd plist management
- Menu bar icon with daemon controls
- Log viewer (app logs)
- CGEventTap for global input monitoring (30s health check timer, auto-recreates if macOS invalidates mach port)
- Developer ID signed .app bundle (ad-hoc for dev builds)
- `rebuild.sh` — one-command pull + build + deploy + launch
- `uninstall.sh` — full cleanup (app, config, models, logs, permissions)
