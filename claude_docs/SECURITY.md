# Security

## Required Permissions

| Permission | Why | Granted To |
|------------|-----|------------|
| **Accessibility** | CGEventTap for global hotkeys, text injection via Cmd+V | TextEcho.app |
| **Microphone** | Audio recording for transcription | TextEcho.app |

Permissions are tied to the app's code signature. Re-building with a new binary requires re-granting in System Settings > Privacy & Security.

## Code Signing

- **Ad-hoc signed** (`codesign --force --deep --sign -`)
- Not notarized — not distributable via Gatekeeper without re-signing
- Binary hash caching in build script preserves existing permissions when only Python files change

## Data Handling

- **Fully local** — no network calls, no cloud services, no telemetry
- **No credentials or API keys** — all models run locally on-device
- **Config file:** `~/.textecho_config` (plaintext JSON, no secrets)
- **Registers file:** `~/.textecho_registers.json` (plaintext, user clipboard snippets)
- **Logs:** `~/Library/Logs/TextEcho/` (app.log, python.log)
- **Temp audio files:** written to OS temp directory, deleted immediately after transcription
- **Model cache:** `~/Library/Caches/TextEcho/` (Hugging Face models, MLX cache)

## Attack Surface

- **Minimal** — no network listeners, no HTTP server, no external API calls
- Unix sockets at `/tmp/textecho_*.sock` are local-only (filesystem permissions)
- CGEventTap requires Accessibility permission (user-granted)
- Python daemons run as user process (no elevated privileges)

## Dependencies

- **Swift:** No third-party dependencies (stdlib + AppKit/SwiftUI/AVFoundation)
- **Python:** lightning-whisper-mlx, numpy, soundfile (all pip packages)
- **Optional:** llama-cpp-python (for LLM features)
- No dependency on PyObjC, pyaudio, or pynput (legacy deps removed)
