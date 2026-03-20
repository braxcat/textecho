# Architecture

## Overview

TextEcho is a native macOS menu bar application written in Swift. Transcription runs natively via **WhisperKit** (Core ML / Apple Neural Engine) — no Python process needed. An optional Python LLM daemon can be bundled for local LLM processing.

## Component Diagram

```
┌──────────────────────────────────────────────┐
│              TextEcho.app (Swift)             │
│                                              │
│  AppMain ──► AppState (orchestrator)         │
│                │                             │
│  ┌─────────────┼──────────────────────┐      │
│  │             │                      │      │
│  InputMonitor  AudioRecorder  TextInjector   │
│  (CGEventTap)  (AVAudioEngine) (Cmd+V)      │
│                │                             │
│  Overlay ◄─────┤                             │
│  (SwiftUI)     │                             │
│                WhisperKitTranscriber (actor)  │
│                │   ┌── Core ML ──┐           │
│                │   │ Neural Engine│           │
│                │   └─────────────┘           │
│                │                             │
│                PythonServiceManager           │
│                │ (LLM only, optional)        │
└────────────────┼─────────────────────────────┘
                 │
        Unix Socket IPC (optional)
                 │
        ┌────────┴─────────────┐
        │   llm_daemon.py      │
        │   (optional)         │
        │   llama-cpp-python   │
        │   /tmp/textecho_     │
        │   llm.sock           │
        └──────────────────────┘
```

## Transcription Flow

1. Swift `AudioRecorder` captures PCM Int16 audio via `AVAudioEngine`
2. `AppState.transcribe()` calls `WhisperKitTranscriber.transcribe()` via Swift async/await
3. `WhisperKitTranscriber` (actor):
   - Converts Int16 PCM → Float32 array
   - Checks RMS silence threshold (skips if too quiet)
   - Resamples to 16kHz if needed (linear interpolation)
   - Calls `WhisperKit.transcribe(audioArray:)` — runs on Apple Neural Engine via Core ML
   - Filters hallucinations (17 known phrases + repeated segment detection)
4. Result returned to `AppState` → `TextInjector.inject()` pastes via clipboard + Cmd+V

No temp files, no IPC, no Python process involved in transcription.

## LLM Flow (Optional)

1. Swift sends: `{"command": "generate", "prompt": "...", "context": "..."}\n` via Unix socket
2. Python loads model if needed, runs inference
3. Responds: `{"success": true, "response": "...", "tokens": N}\n`

LLM requires building with `--with-llm` flag. Not included in default builds.

## Build Pipeline

`build_native_app.sh` produces `dist/TextEcho.app`:

1. `swift build -c release --package-path mac_app` — compile Swift + WhisperKit
2. Create .app bundle structure (Contents/MacOS, Contents/Resources)
3. Copy Swift binary to MacOS/TextEcho
4. (Optional, `--with-llm`) Create Python venv with llama-cpp-python, copy to Resources/
5. Write Info.plist (LSMinimumSystemVersion: 14.0)
6. Ad-hoc code sign

Binary hash caching avoids re-signing when only resource files change (preserves macOS permissions).

## Process Lifecycle

1. **App launch:** AppMain creates NSApplication, menu bar, AppState
2. **AppState.start():** starts InputMonitor + AudioRecorder callbacks, pre-warms WhisperKit model via `Task(priority: .utility)`
3. **First transcription:** WhisperKit downloads Core ML model from HuggingFace (~1.6GB for large-v3-turbo), cached locally
4. **Recording:** AVAudioEngine tap → PCM buffer → WhisperKitTranscriber.transcribe() → TextInjector.inject()
5. **Idle:** WhisperKit model auto-unloads after configurable timeout (default 1 hour) to free ~1.6GB RAM
6. **App quit:** AppState.stop() → InputMonitor.stop(), PythonServiceManager.stopAll()

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Transcription | WhisperKit (native Swift) | Runs on Neural Engine, no Python process, ~1.6GB RAM vs ~3GB |
| Model loading | Lazy (on first use) | Avoids startup delay; model cached after first download |
| RAM management | Auto-unload after idle | Frees Neural Engine/RAM when not in use |
| LLM | Optional Python daemon | Not core feature, rarely used — keep simple |
| Input monitoring | CGEventTap | System-wide hotkeys without extra frameworks |
| Text injection | Clipboard + Cmd+V | Most reliable cross-app method on macOS |
| Concurrency | Swift actor for transcriber | No shared mutable state, no data races |
