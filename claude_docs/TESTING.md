# Testing

## Current Test Strategy

TextEcho uses manual testing as primary verification. The app requires macOS permissions (Accessibility, Microphone) and Apple Silicon hardware, making automated CI impractical.

## Verification Checklist

After each code change:

1. **Build check:** `./build_native_app.sh --debug` — must compile clean (uses xcodebuild for Metal shaders)
2. **Full build:** `./build_native_app.sh` — must produce working .app
3. **Smoke test:** Launch app → record → transcribe → verify text injection
4. **LLM test:** Shift+Middle-click → transcribe → verify LLM response in overlay
5. **Log check:** `~/Library/Logs/TextEcho/` for errors

## Test Utilities

Located in `tests/`:

- `test_keyboard.py` — keyboard input handling verification
- `test_mlx_transcription.py` — MLX Whisper transcription test
- `test_minimal_window.py` — minimal window creation test
- `test_pynput.py` — pynput input test (legacy, may be removed)

## CI

- **`swift-ci.yml`** — GitHub Actions workflow that runs `swift test` and `swift build -c release` on every PR targeting `main`. Uses macOS runners with Xcode.

## Future Testing

- Unit tests for UnixSocket protocol serialization
- Integration tests for daemon IPC (mock socket server)
- Audio processing tests (silence detection, RMS calculation)
