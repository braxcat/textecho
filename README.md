# TextEcho

Voice-to-text dictation tool for macOS with automatic silence detection and native WhisperKit transcription. Runs entirely on Apple Silicon — no cloud, no Python, fully offline after first model download.

**Author:** Braxton Bragg

## Features

- Native WhisperKit transcription (Apple Neural Engine via Core ML)
- Real-time audio recording with waveform visualization
- Fast model loading with auto-unload after idle
- Automatic text pasting into active window
- Middle-click or Ctrl+D trigger (hold to record, release to transcribe)
- Floating overlay with recording status and waveform
- Menu bar app with settings, help, and log viewer
- Stream Deck Pedal push-to-talk support
- Auto-start on login via launchd
- Optional local LLM processing (build with `--with-llm`)

## Requirements

- macOS 14+ (Apple Silicon)
- Microphone access
- Accessibility permissions
- Internet connection for first-time model download (~1.6GB)

## Installation

### Build from source

```bash
./build_native_app.sh
```

Run directly:
```bash
open dist/TextEcho.app
```

Or deploy to Applications:
```bash
cp -R dist/TextEcho.app /Applications/ && open /Applications/TextEcho.app
```

### Build with LLM support (optional)

```bash
PYTHON_BUNDLE_BIN=/opt/homebrew/bin/python3.12 ./build_native_app.sh --with-llm
```

Requires Python 3.12 (NOT 3.13+). Adds local LLM processing via llama-cpp-python.

### Create DMG (optional)

```bash
./build_native_dmg.sh
# Creates TextEcho.dmg — drag to Applications to install
```

### Grant macOS permissions

Go to **System Settings > Privacy & Security** and grant:

| Permission | What to add | Why |
|------------|-------------|-----|
| **Accessibility** | `TextEcho.app` | Input monitoring + paste |
| **Microphone** | Allow when prompted | Audio recording |

## Usage

| Action | How |
|--------|-----|
| **Transcribe** | Middle-click and hold > speak > release |
| **Transcribe (keyboard)** | Ctrl+D (hold to record) |
| **LLM prompt (keyboard)** | Ctrl+Shift+D (requires LLM build) |
| **Save to register** | Cmd+Option+1-9 |
| **Clear registers** | Cmd+Option+0 |
| **Settings** | Cmd+Option+Space |
| **Cancel recording** | ESC |

**First use:** Model downloads (~1.6GB) and loads on first launch. Subsequent uses are instant.

## Architecture

```
TextEcho.app (Swift)
├── InputMonitor (CGEventTap → hotkeys)
├── AudioRecorder (AVAudioEngine → PCM)
├── WhisperKitTranscriber (Core ML → Neural Engine)
├── Overlay (SwiftUI floating window)
└── TextInjector (clipboard + Cmd+V paste)

Optional (--with-llm):
└── llm_daemon.py (llama-cpp-python, Unix socket IPC)
```

Transcription is fully native — no Python, no IPC, no temp files. Audio goes directly from AVAudioEngine to WhisperKit as a float array.

## Transcription Models

| Model | Download | RAM | Speed | Quality |
|-------|----------|-----|-------|---------|
| **large-v3-turbo** (default) | ~1.6GB | ~1.6GB | Fast | Near-best |
| large-v3 | ~3GB | ~3.5GB | Slower | Best |
| base.en | ~140MB | ~180MB | Very fast | Good for clear speech |

Select your model during first-launch setup or change it anytime in Settings.

## Configuration

Edit `~/.textecho_config` (JSON):

| Option | Description | Default |
|--------|-------------|---------|
| `trigger_button` | Mouse button (0=left, 1=right, 2=middle) | `2` |
| `dictation_keycode` | Keyboard trigger keycode (2=D) | `2` |
| `silence_duration` | Seconds of silence before auto-stop | `2.5` |
| `silence_threshold` | Audio level threshold for silence detection | `0.015` |
| `sample_rate` | Audio sample rate in Hz | `16000` |
| `whisper_model` | WhisperKit model name | `large-v3-turbo` |
| `whisper_idle_timeout` | Seconds before model unloads from RAM | `3600` |
| `llm_enabled` | Enable LLM processing (requires --with-llm build) | `false` |
| `llm_model_path` | Path to GGUF model file | `""` |
| `show_menu_bar_icon` | Show icon in menu bar | `true` |

## Troubleshooting

### Transcription not working
1. Check that Accessibility + Microphone permissions are granted
2. Open **Logs** from the menu bar and check for errors
3. Restart the app after changing permissions

### Model not downloading
- Check internet connection — the first launch downloads the Core ML model
- Models are cached at `~/Library/Caches/com.argmaxinc.WhisperKit/`

### Auto-paste not working
- Ensure `TextEcho.app` is in **Accessibility** permissions
- Restart the app after adding permissions

### Two mic icons in menu bar
- Kill duplicates: `pkill -f TextEcho`
- Relaunch the app

### Permissions lost after rebuild
- Ad-hoc code signing changes every rebuild — re-grant Accessibility in System Settings

## LLM Setup (Optional)

1. Build with LLM support:
   ```bash
   PYTHON_BUNDLE_BIN=/opt/homebrew/bin/python3.12 ./build_native_app.sh --with-llm
   ```

2. Download a GGUF model (Llama 3.2 3B recommended)

3. Configure in Settings or `~/.textecho_config`:
   ```json
   {
     "llm_enabled": true,
     "llm_model_path": "/path/to/model.gguf"
   }
   ```

4. Restart TextEcho. Use Ctrl+Shift+D to record with LLM processing.

## Documentation

| Document | Purpose |
|----------|---------|
| [claude_docs/ARCHITECTURE.md](claude_docs/ARCHITECTURE.md) | System design and transcription flow |
| [claude_docs/CHANGELOG.md](claude_docs/CHANGELOG.md) | Release history |
| [claude_docs/FEATURES.md](claude_docs/FEATURES.md) | Feature inventory |
| [claude_docs/ROADMAP.md](claude_docs/ROADMAP.md) | Phase plan and future work |
| [claude_docs/SECURITY.md](claude_docs/SECURITY.md) | Security and permissions |
| [claude_docs/TESTING.md](claude_docs/TESTING.md) | Test strategy |

## License

MIT
