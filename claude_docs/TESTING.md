# Testing

## Current Test Strategy

TextEcho uses manual testing as primary verification. The app requires macOS permissions (Accessibility, Microphone) and Apple Silicon hardware, making automated CI impractical.

## Verification Checklist

After each code change:

1. **Build check:** `swift build -c release --package-path mac_app` — must compile clean
2. **Full build:** `PYTHON_BUNDLE_BIN=/opt/homebrew/bin/python3.12 ./build_native_app.sh` — must produce working .app
3. **Smoke test:** Launch app → record → transcribe → verify text injection
4. **Recovery test:** Kill daemon mid-transcription → verify app recovers
5. **Log check:** `~/Library/Logs/TextEcho/` for errors

## Test Utilities

Located in `tests/`:
- `test_keyboard.py` — keyboard input handling verification
- `test_mlx_transcription.py` — MLX Whisper transcription test
- `test_minimal_window.py` — minimal window creation test
- `test_pynput.py` — pynput input test (legacy, may be removed)

## Future Testing

- Unit tests for UnixSocket protocol serialization
- Integration tests for daemon IPC (mock socket server)
- Audio processing tests (silence detection, RMS calculation)
