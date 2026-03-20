# Features

## Voice-to-Text Dictation
- Hold-to-record with automatic silence detection (configurable threshold + duration)
- Mouse trigger (middle-click) and keyboard trigger (Ctrl+D)
- Automatic text paste into active window via clipboard + Cmd+V
- Cancel recording with ESC

## Native WhisperKit Transcription
- Apple Silicon native via WhisperKit (Core ML / Apple Neural Engine)
- No Python process — runs entirely in Swift
- Default model: large-v3-turbo (~1.6GB download, ~1.6GB RAM, near large-v3 quality)
- Available models: large-v3 (highest quality), base.en (fastest, smallest)
- Model selection in Setup Wizard and Settings
- Models cached locally after first download — fully offline after that
- Lazy model loading — first use downloads/loads, subsequent uses instant
- Auto-unload after configurable idle timeout (default 1 hour) to free RAM
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

## Native Swift Menu Bar UI
- Floating overlay follows cursor during recording
- Real-time waveform visualization (40-bar RMS display)
- Tokyo Night color theme
- Recording (red), Processing (yellow), Downloading (blue), Result (green/purple), Error states
- Auto-hide after result display

## Setup Wizard
- First-launch guided setup
- Accessibility permission check + direct link to System Settings
- Microphone permission check + request
- Model picker with 3 options (size, speed, quality comparison)
- Recommended model pre-selected with badge
- Shows cached/not-cached status per model
- Hotkey reference on completion

## Settings Panel
- Trigger button configuration (mouse button selection)
- Keyboard shortcut customization (key code + modifiers)
- Audio settings (silence duration, silence threshold, sample rate)
- Transcription model picker (active model, manage models section)
- LLM configuration (enable, model path) — only visible when LLM module installed
- Python path and daemon scripts directory — only visible when LLM module installed

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
- Stream Deck Pedal push-to-talk (IOKit HID)
- Ad-hoc code signed .app bundle
