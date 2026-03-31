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

## CI

- **`swift-ci.yml`** — GitHub Actions workflow that runs `swift test` and `swift build -c release` on every PR targeting `main`. Uses macOS runners with Xcode.

## MLX LLM Test Scenarios

After LLM changes, verify:

1. **Model loading:** Select each of the 6 curated models in Settings — verify download + load succeeds
2. **Mode selection:** Test each mode (Grammar Fix, Rephrase, Answer, Custom) — verify correct prompt sent
3. **Shift+Middle-click:** Hold Shift + middle-click → record → release → verify LLM processes result
4. **Ctrl+Shift+D:** Same flow via keyboard shortcut
5. **Auto-paste toggle:** With llmAutoPaste=false, verify result displays in overlay without pasting
6. **Custom prompt:** Enter a custom prompt in Settings → verify it is used in Custom mode
7. **Token limit:** Verify long responses are capped at 2048 tokens
8. **Invalid model ID:** Attempt to set an unlisted model ID — verify rejection
9. **Offline inference:** Disconnect network after model download — verify LLM still works

## Future Testing

- Audio processing tests (silence detection, RMS calculation)
