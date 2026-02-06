# TextEcho

Voice-to-text dictation tool for macOS with automatic silence detection, local MLX Whisper transcription, and optional LLM processing. Optimized for Apple Silicon.

**Author:** Braxton Bragg

## Features

- Real-time audio recording with waveform visualization
- Local Whisper transcription via MLX (Apple Silicon native)
- Fast model loading with auto-unload after idle
- Automatic text pasting into active window
- Middle-click trigger (hold to record, release to transcribe)
- Overlay UI follows cursor with Tokyo Night theme
- Menu bar app with daemon controls
- Auto-start on login via launchd

## Requirements

- macOS (Apple Silicon recommended)
- Microphone access
- Accessibility permissions

## Installation

## Native App (Swift + Bundled Python ML)

TextEcho ships as a native macOS menu bar app written in Swift.  
The ML daemon runs from a **bundled Python venv** inside the app so end users do not need to install Python or deps.

### Build the native app

```bash
./build_native_app.sh
```

### Run

```bash
open dist/TextEcho.app
```

### Create DMG

```bash
./build_native_dmg.sh
```

### 1. Clone and set up Python environment (dev only)

```bash
git clone https://github.com/braxcat/textecho.git
cd textecho

# Create virtual environment (for local dev tools only)
python3.12 -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install lightning-whisper-mlx pyobjc pyaudio numpy soundfile pynput
```

### 2. Grant macOS permissions

Go to **System Settings → Privacy & Security** and grant:

| Permission | What to add | Why |
|------------|-------------|-----|
| **Accessibility** | `TextEcho.app` | Input monitoring + paste |
| **Microphone** | Allow when prompted | Audio recording |

To add TextEcho to Accessibility:
1. Click the `+` button
2. Select `TextEcho.app`
3. Click Open

### 3. Start the app

**Option A: Manual start (two terminals, dev only)**

Terminal 1 — Transcription daemon:
```bash
source .venv/bin/activate
python transcription_daemon_mlx.py
```

Terminal 2 — Main app:
```bash
source .venv/bin/activate
python textecho_app_mac.py
```

**Option B: launchd services (auto-start on login, legacy)**

```bash
./daemon_control_mac.sh install    # one-time setup
./daemon_control_mac.sh start
./daemon_control_mac.sh status     # verify everything is running
```

> **Note:** The native app embeds the daemon and is the preferred path. The legacy launchd scripts remain for dev/back-compat.

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
│  (Swift)        │     │ (MLX Whisper, Py)    │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Swift Overlay  │
│  (waveform UI)  │
└─────────────────┘
```

- **Menu Bar App**: Input monitoring, audio recording, orchestration
- **Transcription Daemon**: MLX Whisper model, Unix socket IPC (bundled venv)
- **Swift Overlay**: Native macOS overlay with waveform visualization

## Configuration

Edit `~/.textecho_config`:

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
| `trigger_button` | Mouse button (0=left, 1=right, 2=middle) | 2 |
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

- Add TextEcho to Accessibility permissions (see Installation step 2)

### Python crashes (segfaults) on some Macs

- Ensure the **bundled venv** is being used (check `Logs → App` for `Python executable:` line).
- Avoid Python 3.13+ for daemon builds; use 3.12/3.11 when creating the bundled venv.

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

4. Restart: `./daemon_control_mac.sh restart`

## License

MIT
