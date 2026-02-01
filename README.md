# Dictation-Mac

Voice-to-text dictation tool for macOS with automatic silence detection, local MLX Whisper transcription, and optional LLM processing. Optimized for Apple Silicon.

## Features

- 🎤 Real-time audio recording with waveform visualization
- 🤖 Local Whisper transcription via MLX (Apple Silicon native)
- ⚡ Fast model loading with auto-unload after idle
- 📋 Automatic text pasting into active window
- 🖱️ Middle-click trigger (hold to record, release to transcribe)
- 🎯 Overlay UI follows cursor with Tokyo Night theme
- 🚀 Menu bar app with daemon controls
- 🔄 Auto-start on login via launchd

## Requirements

- macOS (Apple Silicon recommended)
- Python 3.12 (via Homebrew)
- Microphone access
- Accessibility permissions

## Installation

### 1. Clone and set up Python environment

```bash
git clone https://github.com/braxcat/dictation-mac.git
cd dictation-mac

# Create virtual environment with Homebrew Python
/opt/homebrew/bin/python3.12 -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install lightning-whisper-mlx pyobjc pyaudio numpy soundfile pynput
```

### 2. Grant macOS permissions

Go to **System Settings → Privacy & Security** and grant:

| Permission | What to add | Why |
|------------|-------------|-----|
| **Accessibility** | `.venv/bin/python3.12` | Auto-paste and input monitoring |
| **Microphone** | Allow when prompted | Audio recording |

To add Python to Accessibility:
1. Click the `+` button
2. Press `Cmd+Shift+G` and paste: `/Users/YOUR_USERNAME/Documents/Projects/dictation-mac/.venv/bin/python3.12`
3. Click Open

### 3. Start the app

**Option A: Manual start (two terminals)**

Terminal 1 — Transcription daemon:
```bash
source .venv/bin/activate
python transcription_daemon_mlx.py
```

Terminal 2 — Main app:
```bash
source .venv/bin/activate
python dictation_app_mac.py
```

**Option B: launchd services (auto-start on login)**

```bash
./daemon_control_mac.sh install    # one-time setup
./daemon_control_mac.sh start
./daemon_control_mac.sh status     # verify everything is running
```

> **Note:** If launchd-managed processes aren't responding to input, fall back to Option A. The venv packages may not load correctly under launchd.

## Usage

| Action | How |
|--------|-----|
| **Transcribe** | Middle-click and hold → speak → release |
| **LLM prompt** | Ctrl + middle-click (requires LLM setup) |
| **Save to register** | Cmd+Option+1-9 |
| **Clear registers** | Cmd+Option+0 |
| **Cancel recording** | ESC |

**First use:** Model downloads and loads (~2-5 seconds)
**Subsequent uses:** Instant transcription

## Architecture

```
┌─────────────────┐     ┌──────────────────────┐
│  Menu Bar App   │────▶│ Transcription Daemon │
│  (dictation_    │     │ (MLX Whisper)        │
│   app_mac.py)   │     └──────────────────────┘
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Swift Overlay  │
│  (waveform UI)  │
└─────────────────┘
```

- **Menu Bar App**: Input monitoring, audio recording, orchestration
- **Transcription Daemon**: MLX Whisper model, Unix socket IPC
- **Swift Overlay**: Native macOS overlay with waveform visualization

## Configuration

Edit `~/.dictation_config`:

```json
{
  "trigger_button": 2,
  "silence_duration": 2.5,
  "llm_enabled": false,
  "llm_model_path": "/path/to/model.gguf"
}
```

| Option | Description | Default |
|--------|-------------|---------|
| `trigger_button` | Mouse button (2=middle, 3=back, 4=forward) | 2 |
| `silence_duration` | Seconds before auto-stop | 2.5 |
| `llm_enabled` | Enable LLM processing | false |
| `llm_model_path` | Path to GGUF model | - |

## Daemon Management

```bash
./daemon_control_mac.sh install    # Install auto-start
./daemon_control_mac.sh uninstall  # Remove auto-start
./daemon_control_mac.sh start      # Start services
./daemon_control_mac.sh stop       # Stop services
./daemon_control_mac.sh restart    # Restart services
./daemon_control_mac.sh status     # Show status
./daemon_control_mac.sh logs       # View logs
```

## Troubleshooting

### Transcription not working

1. Check daemon status: `./daemon_control_mac.sh status`
2. View logs: `cat ~/.dictation_transcription.log`
3. Restart: `./daemon_control_mac.sh restart`

### Auto-paste not working

- Ensure `.venv/bin/python3.12` is in **Accessibility** permissions
- Restart the app after adding permissions

### Two mic icons in menu bar

- Kill duplicates: `pkill -f dictation_app_mac.py`
- Restart: `./daemon_control_mac.sh start`

### "This process is not trusted" in logs

- Add Python to Accessibility permissions (see Installation step 2)

## LLM Setup (Optional)

1. Install llama-cpp-python:
   ```bash
   pip install llama-cpp-python
   ```

2. Download a GGUF model (Llama 3.2 3B recommended)

3. Configure `~/.dictation_config`:
   ```json
   {
     "llm_enabled": true,
     "llm_model_path": "/path/to/model.gguf"
   }
   ```

4. Restart: `./daemon_control_mac.sh restart`

## License

MIT
