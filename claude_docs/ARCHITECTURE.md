# Architecture

## Overview

TextEcho is a native macOS menu bar application written in Swift that manages two Python daemon processes for ML inference. The Swift app handles all UI, input monitoring, and audio recording. Python daemons handle model loading and inference via Unix socket IPC.

## Component Diagram

```
┌─────────────────────────────────────────────┐
│              TextEcho.app (Swift)            │
│                                             │
│  AppMain ──► AppState (orchestrator)        │
│                │                            │
│  ┌─────────────┼──────────────────────┐     │
│  │             │                      │     │
│  InputMonitor  AudioRecorder  TextInjector  │
│  (CGEventTap)  (AVAudioEngine) (Cmd+V)     │
│                │                            │
│  Overlay ◄─────┤                            │
│  (SwiftUI)     │                            │
│                PythonServiceManager          │
│                │           │                │
└────────────────┼───────────┼────────────────┘
                 │           │
        Unix Socket IPC      │
                 │           │
┌────────────────┼───┐  ┌───┼────────────────┐
│  transcription     │  │   llm_daemon.py    │
│  _daemon_mlx.py    │  │                    │
│                    │  │  llama-cpp-python   │
│  mlx-whisper       │  │  Metal GPU accel   │
│  (large-v3-turbo)  │  │                    │
│  /tmp/textecho_    │  │  /tmp/textecho_    │
│  transcription.sock│  │  llm.sock          │
└────────────────────┘  └────────────────────┘
```

## IPC Protocol

Communication between Swift and Python uses Unix domain sockets with a JSON-over-newline protocol:

**Request format:**
```
{JSON header}\n[optional binary body]
```

**Response format:**
```
{JSON response}\n
```

### Transcription flow:
1. Swift sends: `{"command": "transcribe_raw", "sample_rate": 16000, "data_length": N}\n<PCM bytes>`
2. Python receives header, reads N bytes of audio data
3. Writes temp WAV file, runs MLX Whisper inference
4. Responds: `{"success": true, "transcription": "..."}\n`

### LLM flow:
1. Swift sends: `{"command": "generate", "prompt": "...", "context": "..."}\n`
2. Python loads model if needed, runs inference
3. Responds: `{"success": true, "response": "...", "tokens": N}\n`

## Build Pipeline

`build_native_app.sh` produces `dist/TextEcho.app`:

1. `swift build -c release --package-path mac_app` — compile Swift binary
2. Create .app bundle structure (Contents/MacOS, Contents/Resources)
3. Copy Swift binary to MacOS/TextEcho
4. Create/reuse cached Python venv (`.venv-bundle-cache`)
5. Copy venv + daemon scripts to Resources/
6. Write Info.plist
7. Ad-hoc code sign

Binary hash caching avoids re-signing when only Python files change (preserves macOS permissions).

## Process Lifecycle

1. **App launch:** AppMain creates NSApplication, menu bar, AppState
2. **AppState.start():** starts InputMonitor + AudioRecorder callbacks, registers event handlers
3. **First transcription:** PythonServiceManager.ensureTranscriptionDaemon() spawns Python process
4. **Recording:** AVAudioEngine tap → PCM buffer → UnixSocket → daemon → result → TextInjector.inject()
5. **App quit:** AppState.stop() → InputMonitor.stop(), PythonServiceManager.stopAll()

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| IPC | Unix sockets | Lower latency than HTTP, no port conflicts, local-only |
| Model loading | Lazy (on first use) | Avoids 2-5s startup delay |
| RAM management | Auto-unload after idle | Frees GPU/RAM when not in use |
| Python packaging | Embedded venv in .app | End users don't need Python installed |
| Input monitoring | CGEventTap | System-wide hotkeys without extra frameworks |
| Text injection | Clipboard + Cmd+V | Most reliable cross-app method on macOS |
