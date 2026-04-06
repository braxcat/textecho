# Architecture

## Overview

TextEcho is a native macOS menu bar application written in Swift. Transcription runs natively via **Parakeet TDT** (default, FluidAudio SDK) or **WhisperKit** (fallback) — both use Core ML / Apple Neural Engine. No Python process needed. Optional native LLM processing via **MLXLLMProcessor** (6 models, 4 modes) — also pure Swift, no external daemons.

## Component Diagram

```
┌──────────────────────────────────────────────────┐
│                TextEcho.app (Swift)               │
│                                                  │
│  AppMain ──► AppState (orchestrator)             │
│                │                                 │
│  ┌─────────────┼──────────────────────┐          │
│  │             │                      │          │
│  InputMonitor  AudioRecorder  TextInjector       │
│  (CGEventTap)  (AVAudioEngine) (Cmd+V)          │
│                │                                 │
│  TrackpadMonitor  StreamDeckPedalMonitor         │
│  (IOKit HID)      (IOKit HID)                   │
│                │                                 │
│  Overlay ◄─────┤                                 │
│  (SwiftUI)     │                                 │
│                │                                 │
│   ┌────────────┴──────────────────────────┐      │
│   │         Transcription path            │      │
│   │                                       │      │
│   │  streaming_enabled=false (default)    │      │
│   │  ─────────────────────────────────    │      │
│   │  Transcriber (protocol)               │      │
│   │  ├── ParakeetTranscriber              │      │
│   │  │   (FluidAudio TDT V3, default)     │      │
│   │  └── WhisperKitTranscriber            │      │
│   │      (WhisperKit, fallback)           │      │
│   │                                       │      │
│   │  streaming_enabled=true (opt-in)      │      │
│   │  ─────────────────────────────────    │      │
│   │  StreamingTranscriber (protocol)      │      │
│   │  └── StreamingEouAsrManager           │      │
│   │      (FluidAudio EOU 120M)            │      │
│   │      160ms chunk callbacks            │      │
│   │      → .streamingPartial overlay      │      │
│   └───────────────────────────────────────┘      │
│                │                                 │
│                MLXLLMProcessor                   │
│                (native MLX, optional)            │
│                6 models, 4 modes                │
└──────────────────────────────────────────────────┘
```

## Transcription Flow

### Batch mode (default, `streaming_enabled = false`)

1. `AudioRecorder` captures PCM Int16 audio via `AVAudioEngine`
2. User releases activation key → full audio buffer passed to `AppState.transcribe()`
3. **ParakeetTranscriber** (default) or **WhisperKitTranscriber** (fallback), both actors:
   - Converts Int16 PCM → Float32 array
   - Resamples to 16kHz if needed (linear interpolation)
   - Runs inference on Apple Neural Engine via Core ML (FluidAudio TDT V3 or WhisperKit)
   - Filters hallucinations (17 known phrases + repeated segment detection)
4. Result returned to `AppState` → `TextInjector.inject()` pastes via clipboard + Cmd+V

### Streaming mode (opt-in, `streaming_enabled = true`)

1. `AudioRecorder` fires `onAudioBuffer` callback with 160ms PCM chunks during recording
2. **`StreamingEouAsrManager`** feeds each chunk into the FluidAudio EOU 120M model
3. Partial transcription results delivered via callback → `AppState` updates overlay to `.streamingPartial` (ghost text)
4. User releases activation key → `StreamingEouAsrManager` finalises the transcript
5. Final result → `TextInjector.inject()` pastes via clipboard + Cmd+V

The two paths are mutually exclusive. When streaming is enabled, the TDT V3 model is not used. When streaming is disabled, EOU is not loaded.

No temp files, no IPC, no Python process involved in either path. Mode is persisted via `streaming_enabled` in `~/.textecho_config`.

### Overlay States

| State               | Visual            | When                                        |
| ------------------- | ----------------- | ------------------------------------------- |
| `.recording`        | Pink + waveform   | Active recording (both modes)               |
| `.streamingPartial` | Ghost text (dim)  | Streaming mode — partial result in progress |
| `.processing`       | Purple + spinner  | Batch mode — inference running post-release |
| `.result`           | Neon green + text | Transcription complete, pasting             |
| `.error`            | Red               | Transcription or injection failure          |

## LLM Flow (Optional)

1. User triggers LLM via Shift+Middle-click (mouse) or Ctrl+Shift+D (keyboard)
2. Audio is transcribed normally via Parakeet/WhisperKit
3. **MLXLLMProcessor** processes the transcription text with the selected mode:
   - `clean` — clean up transcription artifacts
   - `fix` — grammar and spelling corrections
   - `expand` — elaborate on the dictated content
   - `custom` — user-defined system prompt
4. MLX model loaded on first use from HuggingFace, cached locally
5. Result pasted via TextInjector

LLM is fully native Swift (MLX framework) — no Python, no IPC, no external process. Requires building with `--with-llm` flag.

## Build Pipeline

`build_native_app.sh` produces `dist/TextEcho.app`:

1. `xcodebuild` — compile Swift + WhisperKit + MLX (Metal shaders require xcodebuild, not swift build)
2. Create .app bundle structure (Contents/MacOS, Contents/Resources)
3. Copy Swift binary to MacOS/TextEcho
4. Copy resource bundles (`.metallib` for MLX GPU operations)
5. Write Info.plist (LSMinimumSystemVersion: 14.0)
6. Ad-hoc code sign

Binary hash caching avoids re-signing when only resource files change (preserves macOS permissions).

## Process Lifecycle

1. **App launch:** AppMain creates NSApplication, menu bar, AppState
2. **AppState.start():** starts InputMonitor + AudioRecorder callbacks, pre-warms WhisperKit model via `Task(priority: .utility)`
3. **First transcription:** WhisperKit downloads Core ML model from HuggingFace (~1.6GB for large-v3-turbo), cached locally
4. **Recording:** AVAudioEngine tap → PCM buffer → WhisperKitTranscriber.transcribe() → TextInjector.inject()
5. **Idle:** WhisperKit model auto-unloads after configurable timeout (default: never — stays loaded) to free ~1.6GB RAM
6. **App quit:** AppState.stop() → InputMonitor.stop()

## CI/Release Pipeline

```
Tag push (v*) → GitHub Actions release.yml
  ├── Checkout + swift build -c release
  ├── Import Developer ID cert → ephemeral keychain
  ├── codesign --sign "Developer ID" --options runtime --entitlements TextEcho.entitlements
  ├── xcrun notarytool submit (App Store Connect API key)
  ├── xcrun stapler staple
  ├── build_native_dmg.sh --sign → signed DMG
  ├── gh release create → upload DMG
  └── Sigstore build attestation
```

- **Trigger:** version tags (`v*`)
- **Runner:** `macos-latest` (required for codesign + notarytool)
- **Security:** ephemeral keychain (destroyed after build), SHA-pinned actions, GitHub Environment with approval gate, CODEOWNERS on workflow files
- **Secrets:** `APPLE_CERTIFICATE_P12`, `APPLE_CERTIFICATE_PASSWORD`, `APPSTORE_CONNECT_API_KEY_ID`, `APPSTORE_CONNECT_ISSUER_ID`, `APPSTORE_CONNECT_API_KEY_P8`, `APPLE_TEAM_ID`

## Key Design Decisions

| Decision            | Choice                                         | Rationale                                                                         |
| ------------------- | ---------------------------------------------- | --------------------------------------------------------------------------------- |
| Batch transcription | Parakeet TDT (default) / WhisperKit (fallback) | Parakeet: 2.1% WER, 3-6x faster; both run on Neural Engine, no Python             |
| Streaming model     | FluidAudio EOU 120M                            | Lightweight model tuned for end-of-utterance detection; low latency on-device     |
| Streaming vs batch  | Either/or, not simultaneous                    | Avoids model contention on Neural Engine; user picks mode in Settings             |
| Silence gate        | Removed from pre-model path                    | RMS filter was discarding quiet/whispered speech; model handles low-energy audio  |
| Model loading       | Lazy (on first use)                            | Avoids startup delay; model cached after first download                           |
| RAM management      | Auto-unload after idle                         | Frees Neural Engine/RAM when not in use                                           |
| LLM                 | Native MLX (Swift)                             | On-device, 6 models, 4 modes, no Python/IPC overhead                              |
| Input monitoring    | CGEventTap                                     | System-wide hotkeys without extra frameworks; 30s health check auto-recreates tap |
| Trackpad input      | IOKit HID (TrackpadMonitor)                    | Matches Magic Trackpad by vendor/product ID; force click or right-click gestures  |
| Text injection      | Clipboard + Cmd+V                              | Most reliable cross-app method on macOS                                           |
| Concurrency         | Swift actor for transcriber                    | No shared mutable state, no data races                                            |
| Thread safety       | @MainActor on AppState                         | All UI state mutations on main thread; background work via Task.detached          |
| File safety         | Atomic writes for config/history               | Prevents corruption on crash; history has 0600 permissions                        |
