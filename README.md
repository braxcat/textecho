# TextEcho

Voice-to-text dictation tool for macOS with automatic silence detection, local MLX Whisper transcription, and optional LLM processing. Optimized for Apple Silicon.

**Author:** Braxton Bragg

## Features

- Real-time audio recording with waveform visualization
- Local Whisper transcription via MLX (Apple Silicon native)
- Fast model loading with auto-unload after idle
- Automatic text pasting into active window
- Middle-click trigger (hold to record, release to transcribe)
- Floating overlay with waveform visualization
- Menu bar app with daemon controls and settings UI
- Auto-start on login via launchd

## Requirements

- macOS 13+ (Apple Silicon recommended)
- Microphone access
- Accessibility permissions

## Installation

### Build from source

```bash
PYTHON_BUNDLE_BIN=/opt/homebrew/bin/python3.12 ./build_native_app.sh
```

Run directly:
```bash
open dist/TextEcho.app
```

Or deploy to Applications:
```bash
cp -R dist/TextEcho.app /Applications/ && open /Applications/TextEcho.app
```

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
| **LLM prompt** | Ctrl + middle-click (requires LLM setup) |
| **Transcribe (keyboard)** | Ctrl+D (hold to record) |
| **LLM prompt (keyboard)** | Ctrl+Shift+D (hold to record) |
| **Save to register** | Cmd+Option+1-9 |
| **Clear registers** | Cmd+Option+0 |
| **Settings** | Cmd+Option+Space |
| **Cancel recording** | ESC |

**First use:** Model downloads and loads (~2-5 seconds)
**Subsequent uses:** Instant transcription

## Architecture

```
┌───────────────────────┐     ┌──────────────────────┐
│  TextEcho.app (Swift) │────>│ Transcription Daemon  │
│  Menu bar + overlay   │     │ (MLX Whisper, Python) │
│  Input + audio + paste│     │ /tmp/textecho_transcription.sock
└───────────────────────┘     └──────────────────────┘
         │
         └──────────────────>┌──────────────────────┐
                             │ LLM Daemon (optional) │
                             │ (llama-cpp, Python)   │
                             │ /tmp/textecho_llm.sock │
                             └──────────────────────┘
```

- **TextEcho.app** (Swift): Input monitoring, audio recording, overlay UI, text injection
- **Transcription Daemon** (Python): MLX Whisper model, Unix socket IPC, bundled in app venv
- **LLM Daemon** (Python, optional): Local LLM processing via llama-cpp-python

## Configuration

Edit `~/.textecho_config` (JSON):

| Option | Description | Default |
|--------|-------------|---------|
| `trigger_button` | Mouse button (0=left, 1=right, 2=middle) | `2` |
| `dictation_keycode` | Keyboard trigger keycode (2=D) | `2` |
| `silence_duration` | Seconds of silence before auto-stop | `2.5` |
| `silence_threshold` | Audio level threshold for silence detection | `0.015` |
| `sample_rate` | Audio sample rate in Hz | `16000` |
| `llm_enabled` | Enable LLM processing | `false` |
| `llm_model_path` | Path to GGUF model file | `""` |
| `show_menu_bar_icon` | Show icon in menu bar | `true` |
| `python_path` | Python 3.12 executable (auto-detected) | auto |
| `daemon_scripts_dir` | Directory containing daemon scripts (auto-detected) | auto |

## Troubleshooting

### Transcription not working

1. Open **Logs** from the menu bar and check **Python** log
2. Ensure Accessibility + Microphone permissions are granted
3. Restart the app after changing permissions

### Auto-paste not working

- Ensure `TextEcho.app` is in **Accessibility** permissions
- Restart the app after adding permissions

### Two mic icons in menu bar

- Kill duplicates: `pkill -f TextEcho`
- Relaunch the app

### "This process is not trusted" in logs

- Add TextEcho to Accessibility permissions (see Installation)

### Python crashes (segfaults)

- Ensure the **bundled venv** uses Python 3.12 (NOT 3.13+)
- Rebuild with: `PYTHON_BUNDLE_BIN=/opt/homebrew/bin/python3.12 ./build_native_app.sh`
- Delete `.venv-bundle-cache` to force venv rebuild

## LLM Setup (Optional)

1. Install llama-cpp-python:
   ```bash
   pip install llama-cpp-python
   ```

2. Download a GGUF model (Llama 3.2 3B recommended)

3. Configure `~/.textecho_config`:
   ```json
   {
     "llm_enabled": true,
     "llm_model_path": "/path/to/model.gguf"
   }
   ```

4. Restart TextEcho

## Documentation

| Document | Purpose |
|----------|---------|
| [claude_docs/ARCHITECTURE.md](claude_docs/ARCHITECTURE.md) | System design and IPC protocol |
| [claude_docs/CHANGELOG.md](claude_docs/CHANGELOG.md) | Release history |
| [claude_docs/FEATURES.md](claude_docs/FEATURES.md) | Feature inventory |
| [claude_docs/ROADMAP.md](claude_docs/ROADMAP.md) | Phase plan and future work |
| [claude_docs/SECURITY.md](claude_docs/SECURITY.md) | Security and permissions |
| [claude_docs/TESTING.md](claude_docs/TESTING.md) | Test strategy |

## License

MIT
