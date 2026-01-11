# Dictation App

Voice-to-text dictation tool with automatic silence detection and text pasting.

## Features

- 🎤 Real-time audio recording with waveform visualization
- 🤖 Local Whisper transcription (CPU/NPU support)
- ⚡ Smart model loading: loads on first use, auto-unloads after idle time
- 💾 Memory efficient: frees RAM when not in use (configurable timeout)
- ✨ Auto-stop after configurable silence duration (default: 2.5s)
- 📋 Automatic text pasting into active window
- 🔧 Configurable audio device selection
- ⌨️ Hotkey activation

## Architecture

The app uses a **daemon + GUI architecture**:

1. **Transcription Daemon** - Manages Whisper model lifecycle:
   - Loads model on first transcription request
   - Keeps model in RAM for fast subsequent requests
   - Auto-unloads after configurable idle time (default: 1 hour) to free memory
   - Communicates via Unix socket (`/tmp/dictation_transcription.sock`)

2. **Recorder GUI** - Lightweight client that:
   - Records audio with waveform visualization
   - Sends audio to daemon for transcription
   - Pastes result automatically
   - Launched by your desktop environment's hotkey system

## Setup

1. Install dependencies:
   ```bash
   uv sync
   ```

2. Start the transcription daemon:
   ```bash
   ./daemon_control.sh start
   ```

3. Set up keyboard hotkey in your desktop environment:
   - **GNOME/Ubuntu**: Settings → Keyboard → Custom Shortcuts
   - **KDE**: System Settings → Shortcuts → Custom Shortcuts
   - Command: `/home/tyler/dictation/launch_recorder.sh`
   - Suggested hotkey: `Ctrl+Alt+Space`

4. Install text input tool (for pasting):
   ```bash
   # X11 users
   sudo apt install xdotool

   # Wayland users
   sudo apt install wtype
   # OR
   sudo apt install ydotool
   ```

## Usage

1. Press your configured hotkey to open the recorder
2. Speak into your microphone
3. Recording auto-stops after 2.5s of silence (or press "Stop & Transcribe")
4. Text is automatically transcribed and pasted at cursor position
5. Press `ESC` to cancel recording

**First use:** Model loads on demand (2-5 second delay)
**Subsequent uses:** Instant transcription (model already in RAM)
**After 1 hour idle:** Model auto-unloads to free RAM

## Configuration

Configuration is stored in `~/.dictation_config` as JSON.

Edit or create `~/.dictation_config`:

```json
{
  "silence_duration": 3.0,
  "model_idle_timeout": 1800,
  "transcription_device": "CPU",
  "model_path": "./whisper-base-cpu",
  "device_index": 5
}
```

### Configuration Options

- `silence_duration`: Seconds of silence before auto-stopping recording (default: 2.5)
- `model_idle_timeout`: Seconds before unloading model from RAM (default: 3600 = 1 hour)
  - Set to `1800` for 30 minutes
  - Set to `7200` for 2 hours
  - Set to `0` to disable auto-unload (keep model always loaded)
- `transcription_device`: Device for Whisper model (default: "CPU", options: "NPU")
- `model_path`: Path to Whisper model directory (default: "./whisper-base-cpu")
- `device_index`: Last used audio input device (auto-saved)

**Note:** Changes to `model_idle_timeout`, `transcription_device`, and `model_path` require restarting the transcription daemon:

```bash
./daemon_control.sh restart
```

## Daemon Management

```bash
# Start transcription daemon
./daemon_control.sh start

# Stop daemon
./daemon_control.sh stop

# Restart daemon
./daemon_control.sh restart

# Check status and view recent logs
./daemon_control.sh status

# Follow logs in real-time
./daemon_control.sh logs
```

## Troubleshooting

**GUI doesn't appear:**
- Check `~/.dictation_gui.log` for errors
- Verify hotkey is correctly configured

**Transcription daemon not running:**
- Check daemon status: `./daemon_control.sh status`
- View daemon logs: `cat ~/.dictation_transcription.log`
- Restart daemon: `./daemon_control.sh restart`

**"Daemon communication error":**
- Transcription daemon is not running
- Start it with: `./daemon_control.sh start`

**Model loading slow on first use:**
- Expected behavior! Model loads on-demand (~2-5 seconds)
- Subsequent uses will be instant
- To keep model always loaded, set `"model_idle_timeout": 0` in config

**Audio device issues:**
- Select correct device from dropdown before recording
- Your choice is saved for next time

**Paste not working:**
- Install `xdotool` (X11) or `wtype`/`ydotool` (Wayland)
- Check terminal output for "No text input tool found" message

**High memory usage:**
- Model uses ~500MB-1GB RAM when loaded
- Adjust `model_idle_timeout` to unload sooner
- Check if model is loaded: `./daemon_control.sh status`
