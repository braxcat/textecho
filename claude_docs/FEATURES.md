# Features

## Voice-to-Text Dictation
- Hold-to-record with automatic silence detection (configurable threshold + duration)
- Mouse trigger (middle-click) and keyboard trigger (Ctrl+D)
- Automatic text paste into active window via clipboard + Cmd+V
- Cancel recording with ESC

## Local MLX Whisper Transcription
- Apple Silicon native via mlx-whisper
- Default model: whisper-large-v3-turbo (809M params, ~1.6GB, near large-v3 quality at 8x speed)
- Accurate mode: whisper-large-v3 (1.55B params, ~3GB, highest quality)
- Models are HuggingFace repo IDs — downloaded and cached automatically on first use
- Lazy model loading — first use downloads/loads, subsequent uses instant
- Auto-unload after configurable idle timeout (default 1 hour) to free RAM
- Hallucination filtering (known phrases, repeated segments, silence detection)

## Local LLM Processing (Optional)
- llama-cpp-python with Metal acceleration
- 9-register clipboard context system for multi-snippet LLM prompts
- Auto-detection of prompt format (Gemma, Llama, Phi, ChatML)
- Streaming response display in overlay
- Configurable system prompt, temperature, repeat penalty, top-p/top-k
- Reasoning tag stripping (<think>/<reasoning> blocks)

## Native Swift Menu Bar UI
- Floating overlay follows cursor during recording
- Real-time waveform visualization (40-bar RMS display)
- Tokyo Night color theme
- Recording (red), Processing (yellow), Result (green/purple), Error states
- Auto-hide after result display

## Setup Wizard
- First-launch guided setup
- Accessibility permission check + direct link to System Settings
- Microphone permission check + request
- Model preload with progress indication
- Hotkey reference on completion

## Settings Panel
- Trigger button configuration (mouse button selection)
- Keyboard shortcut customization (key code + modifiers)
- Audio settings (silence duration, silence threshold, sample rate)
- LLM configuration (enable, model path, context length, threads)
- Python path and daemon scripts directory

## System Integration
- Autostart via launchd plist management
- Menu bar icon with daemon controls
- Log viewer (app + Python daemon logs)
- CGEventTap for global input monitoring
- Ad-hoc code signed .app bundle with embedded Python venv
