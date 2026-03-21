# TextEcho

Voice-to-text dictation for macOS with native WhisperKit transcription on Apple Silicon. Hold a button, speak, release — your words appear as text. No cloud, no Python, fully offline after first model download.

**Author:** Braxton Bragg

```
┌─────────────────────────────────────────────────────┐
│ ╔══════════════════════════════════════════════════╗ │
│ ║  ● RECORDING              TEXT ECHO             ║ │
│ ║                                                  ║ │
│ ║  ▐█▌▐██▌▐█▌▐▌▐██▌▐███▌▐█▌▐██▌▐█▌▐▌▐██▌▐███▌  ║ │
│ ║                                                  ║ │
│ ║          WHISPER // LARGE V3 TURBO               ║ │
│ ╚══════════════════════════════════════════════════╝ │
│                                                     │
│  Pink recording → Purple processing → Green result  │
│  Cyberpunk overlay follows your cursor              │
└─────────────────────────────────────────────────────┘
```

## Features

- **Native WhisperKit** — transcription via Apple Neural Engine (Core ML), ~1.6GB RAM
- **Push-to-talk** — middle-click, Ctrl+D, or Stream Deck Pedal
- **Cyberpunk overlay** — pink→purple→neon green states, waveform visualization
- **Stream Deck Pedal** — center=dictate, left=paste, right=enter (auto-detect, no Elgato software)
- **Instant paste** — transcribed text goes straight to your cursor via clipboard
- **Fully offline** — no cloud, no accounts, audio never leaves your Mac
- **Fast model loading** — lazy load on first use, auto-unload after idle
- **Menu bar app** — settings, help, log viewer, setup wizard
- **Optional LLM** — local llama-cpp-python processing (build with `--with-llm`)

## Requirements

- macOS 14+ (Apple Silicon)
- Microphone + Accessibility permissions
- Internet for first model download (~1.6GB)

## Install from DMG (unsigned)

Download `TextEcho.dmg` and follow these steps:

1. **Open the DMG** — double-click `TextEcho.dmg`
2. **Drag TextEcho to Applications** — standard drag-and-drop install
3. **First launch — bypass Gatekeeper:**
   - Open **Finder → Applications**
   - **Right-click** (or Control-click) `TextEcho.app` → **Open**
   - Click **Open** on the warning dialog ("macOS cannot verify the developer")
   - You only need to do this once — after that it opens normally
4. **Grant permissions** when prompted:
   - **Accessibility** — System Settings → Privacy & Security → Accessibility → enable TextEcho
   - **Microphone** — System Settings → Privacy & Security → Microphone → enable TextEcho
5. **Choose a model** — the Setup Wizard will ask you to pick a transcription model on first launch. "Large V3 Turbo" (default, ~1.6GB download) is recommended.

> **If you get "app is damaged":** Open Terminal and run:
> ```bash
> xattr -cr /Applications/TextEcho.app
> ```
> Then right-click → Open again.

## Quick Start (build from source)

```bash
# Build
./build_native_app.sh

# Deploy + launch
./rebuild.sh
```

Or step by step:
```bash
./build_native_app.sh
cp -R dist/TextEcho.app /Applications/
open /Applications/TextEcho.app
```

Grant **Accessibility** and **Microphone** in System Settings when prompted. First launch downloads the transcription model.

## Scripts

| Script | What it does |
|--------|-------------|
| `./rebuild.sh` | Pull + build + deploy + launch (one command) |
| `./rebuild.sh --clean` | Full clean rebuild |
| `./rebuild.sh --uninstall` | Wipe everything, then fresh rebuild |
| `./uninstall.sh` | Remove app, config, models, logs, everything |
| `./build_native_app.sh` | Build only (no deploy) |
| `./build_native_app.sh --with-llm` | Build with optional LLM module |

## Usage

| Action | How |
|--------|-----|
| **Dictate (mouse)** | Middle-click hold → speak → release |
| **Dictate (keyboard)** | Ctrl+D hold → speak → release |
| **Dictate (pedal)** | Center pedal hold → speak → release |
| **Paste (pedal)** | Left pedal |
| **Enter (pedal)** | Right pedal |
| **LLM prompt** | Ctrl+Shift+D (requires `--with-llm` build) |
| **Save to register** | Cmd+Option+1-9 |
| **Clear registers** | Cmd+Option+0 |
| **Settings** | Cmd+Option+Space |
| **Cancel** | ESC |

## Architecture

```
                    ┌─────────────────────────────────────┐
                    │         TextEcho.app (Swift)         │
                    │                                     │
  Hotkey/Mouse/     │  AppMain → AppState (orchestrator)  │
  Pedal input  ───► │      │         │          │         │
                    │  InputMonitor  │    StreamDeck       │
                    │  (CGEventTap)  │    PedalMonitor     │
                    │                │    (IOKit HID)      │
                    │         AudioRecorder                │
                    │         (AVAudioEngine)              │
                    │                │                     │
                    │                ▼                     │
                    │    WhisperKitTranscriber (actor)     │
                    │    ┌────────────────────────┐       │
                    │    │  Core ML / Neural Engine│       │
                    │    │  Whisper large-v3-turbo │       │
                    │    └────────────────────────┘       │
                    │                │                     │
                    │                ▼                     │
                    │         TextInjector                 │
  Text pasted  ◄─── │    (clipboard + Cmd+V paste)        │
  into app          │                                     │
                    │         Overlay (SwiftUI)            │
                    │    ┌────────────────────────┐       │
                    │    │ ● RECORDING   TEXTECHO │       │
                    │    │ ▐█▌▐██▌▐█▌▐▌▐██▌▐███▌ │       │
                    │    │   WHISPER // LG V3 TURBO│      │
                    │    └────────────────────────┘       │
                    │                                     │
                    │    Optional: llm_daemon.py           │
                    │    (Unix socket IPC, --with-llm)     │
                    └─────────────────────────────────────┘
```

### Data Flow

1. **Input** — CGEventTap (keyboard/mouse) or IOKit HID (pedal) triggers recording
2. **Capture** — AVAudioEngine records PCM Int16 audio via tap callback
3. **Transcribe** — WhisperKitTranscriber actor converts to Float32, resamples to 16kHz, runs inference on Neural Engine
4. **Filter** — RMS silence check, hallucination filter (17 known phrases + repeat detection)
5. **Paste** — TextInjector writes to clipboard, sends Cmd+V keystroke to active app
6. **Display** — Cyberpunk overlay shows state: pink recording → purple processing → neon green result

### Key Design Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Transcription | WhisperKit (native Swift) | Neural Engine, no Python, ~1.6GB vs ~3GB RAM |
| Concurrency | Swift actor | No shared mutable state, no data races |
| Audio start | DispatchQueue.main.async | IOKit HID callbacks block AVAudioEngine if started synchronously |
| Text injection | Clipboard + Cmd+V | Most reliable cross-app method on macOS |
| LLM | Optional Python daemon | Rarely used, not worth native port complexity |
| Pedal | IOKit HID (shared mode) | No kernel extension, no Elgato software needed |

## Transcription Models

| Model | Download | RAM | Speed | Quality |
|-------|----------|-----|-------|---------|
| **Large V3 Turbo** (default) | ~1.6GB | ~1.6GB | Fast | Near-best |
| Large V3 | ~3GB | ~3.5GB | Slower | Best |
| Base (English) | ~140MB | ~180MB | Very fast | Good for clear speech |

Models download from HuggingFace on first use and cache at `~/Documents/huggingface/models/`. Select in Setup Wizard or Settings.

## Configuration

`~/.textecho_config` (JSON):

| Option | Default | Description |
|--------|---------|-------------|
| `trigger_button` | `2` | Mouse button (0=left, 1=right, 2=middle) |
| `dictation_keycode` | `2` | Keyboard trigger (2=D key) |
| `silence_duration` | `2.5` | Seconds of silence before auto-stop |
| `silence_threshold` | `0.015` | Audio level for silence detection |
| `whisper_model` | `openai_whisper-large-v3_turbo` | WhisperKit model name |
| `whisper_idle_timeout` | `3600` | Seconds before model unloads from RAM |
| `pedal_enabled` | `false` | Enable Stream Deck Pedal |
| `pedal_position` | `1` | Push-to-talk pedal (0=left, 1=center, 2=right) |

## Stream Deck Pedal

Elgato Stream Deck Pedal works out of the box via IOKit HID — no Elgato software needed (actually, quit it first).

| Pedal | Action |
|-------|--------|
| Left | Paste (Cmd+V) |
| Center | Push-to-talk (hold to record) |
| Right | Enter |

Enable in Settings or `~/.textecho_config`. Auto-detects within 3 seconds, auto-reconnects on unplug/replug.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| No transcription | Check Accessibility + Microphone in System Settings |
| Audio too quiet (RMS=0) | Reset mic permission: `tccutil reset Microphone com.textecho.app`, relaunch |
| Pedal not detected | Quit Elgato Stream Deck app, unplug/replug pedal |
| Permissions lost after rebuild | Re-grant in System Settings (ad-hoc signing changes signature) |
| Model not downloading | Check internet, try `./rebuild.sh --clean` |

## Documentation

| Document | Purpose |
|----------|---------|
| [claude_docs/ARCHITECTURE.md](claude_docs/ARCHITECTURE.md) | System design and data flow |
| [claude_docs/CHANGELOG.md](claude_docs/CHANGELOG.md) | Release history |
| [claude_docs/FEATURES.md](claude_docs/FEATURES.md) | Feature inventory |
| [claude_docs/ROADMAP.md](claude_docs/ROADMAP.md) | Phase plan and future work |
| [claude_docs/SECURITY.md](claude_docs/SECURITY.md) | Security and permissions |

## License

MIT
