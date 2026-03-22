# Features

## Voice-to-Text Dictation
- Multiple activation methods: Caps Lock, mouse button, keyboard shortcut, Stream Deck Pedal
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

## Native WhisperKit Transcription
- Apple Silicon native via WhisperKit (Core ML / Apple Neural Engine)
- No Python process — runs entirely in Swift
- Default model: large-v3-turbo (~1.6GB download, ~1.6GB RAM, near large-v3 quality)
- Available models: large-v3 (highest quality), base.en (fastest, smallest)
- Model selection in Setup Wizard and Settings
- Models cached locally after first download — fully offline after that
- Lazy model loading — first use downloads/loads, subsequent uses instant
- Configurable idle timeout: Never / 1hr / 4hr / 8hr / Custom (default: Never — stays loaded)
- Hallucination filtering (17 known phrases + repeated segment detection)
- RMS silence detection (skip transcription if audio too quiet)
- 30-second timeout on inference to prevent indefinite hangs

## Local LLM Processing (Optional)
- llama-cpp-python with Metal acceleration
- Must build with `--with-llm` flag (not included in default build)
- 9-register clipboard context system for multi-snippet LLM prompts
- Auto-detection of prompt format (Gemma, Llama, Phi, ChatML)
- Streaming response display in overlay
- Configurable system prompt, temperature, repeat penalty, top-p/top-k
- Reasoning tag stripping (<think>/<reasoning> blocks)

## Cyberpunk Overlay UI
- Floating overlay follows cursor during recording
- Real-time waveform visualization (40-bar RMS, magenta→neon green gradient)
- Cyberpunk color flow: Pink recording → Electric Purple processing → Neon Green result
- Silver TEXT + neon green ECHO logo
- Model badge: "WHISPER // LARGE V3 TURBO" at bottom
- Full transcription text visible (no line limit, auto-expands)
- Smart auto-hide: 1.5s base + scales with text length, max 4s
- Glassmorphic dark background with accent glow borders
- Animated scanner bar during processing
- Pulsing recording indicator

## Stream Deck Pedal
- Elgato Stream Deck Pedal via IOKit HID (shared mode, no Elgato software needed)
- Per-pedal actions: center=push-to-talk, left=paste (Cmd+V), right=enter
- 3-second auto-detect timer — no unplug/replug needed
- Auto-reconnect after disconnect
- Configurable push-to-talk pedal position (left/center/right)

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
- LLM configuration (enable, model path) — only visible when LLM module installed
- Dirty tracking with unsaved changes indicator
- Confirm dialog on close with unsaved changes

## In-App Help
- Accessible from menu bar → Help
- Getting Started, How to Dictate, Keyboard Shortcuts
- Stream Deck Pedal setup, Settings reference, Troubleshooting
- Model selection guide, LLM module instructions
- Embedded in binary — works offline

## System Integration
- Autostart via launchd plist management
- Menu bar icon with daemon controls
- Log viewer (app + Python daemon logs)
- CGEventTap for global input monitoring
- Ad-hoc code signed .app bundle
- `rebuild.sh` — one-command pull + build + deploy + launch
- `uninstall.sh` — full cleanup (app, config, models, logs, permissions)
