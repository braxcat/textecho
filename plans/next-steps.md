# TextEcho — Next Steps (updated 2026-03-29)

## Completed (2026-03-22)

- **Steps 1-5 DONE:** Security fixes tested, theme branch created, themes tested on Mac, Dependabot #4/#5 merged, GitHub security features enabled
- **Theme wiring bug FIXED:** Overlay wasn't reading colors from config — patched and tested
- **PR #7 merged:** Theme customization (5 built-in presets, custom colors, save/delete user themes) + Swift CI workflow
- **CI workflow added:** `.github/workflows/swift-ci.yml` — runs `swift test` + `swift build -c release` on PRs to main

## Completed (continued)

- **Security fixes ALL APPLIED:** All 7 items from PR #2 review (2 HIGH + 5 MEDIUM) were already fixed on main. 8 security tests in place. No `fix/pr2-security` branch needed.
- **Menu bar hover bug:** PR #8 — long transcriptions now open a submenu instead of a tooltip. Preview bumped 40→80 chars.

## Completed (continued)

- **PR #8 merged** — menu bar hover fix (120-char preview, click to copy)
- **PR #9 merged** — help window (themes + idle timeout sections), double privacy prompt fix, wizard Customize step (theme picker with color swatches, silence slider, model memory), Settings silence slider
- **README updated** — contributor credit for Lochie, setup wizard description

## Completed (2026-03-29)

- **Signed release pipeline:** Developer ID signing, notarization, GitHub Actions release workflow (v\* tags), Sigstore attestation
- **Parakeet TDT v3 (v2.2.0):** Default transcription engine. Evaluated all major local STT models (Whisper, Distil-Whisper, Moonshine, NVIDIA Canary/Parakeet, Apple SpeechAnalyzer, MLX Whisper). Parakeet won on accuracy (2.1% WER, 3.7x better than Whisper), speed (3-6x faster), and Swift support (FluidAudio SDK, Core ML). WhisperKit kept as fallback for 99 languages vs Parakeet's 25.

## Completed (2026-04-06)

- **Streaming transcription (PR #41):** Opt-in real-time transcription via FluidAudio EOU 120M model. 160ms chunks, ghost text in overlay during recording, finalises on release. Settings → Streaming (Beta). `streaming_enabled` config key.
- **Silence skip removal (PR #40):** Removed pre-model RMS silence gate from ParakeetTranscriber and WhisperKitTranscriber. Quiet/whispered speech now reaches the transcription model.

## Next

- [ ] **WhisperKit streaming** — extend streaming path to WhisperKit backend (currently EOU/Parakeet only)
- [ ] **Streaming accuracy benchmarking** — compare EOU 120M streaming vs TDT V3 batch on real-world dictation
- [ ] **Auto-update mechanism** — Sparkle or similar for in-app updates
- [ ] **Apple SpeechAnalyzer** — Evaluate as third engine option when macOS 26 ships
- [ ] **App Store distribution** — Sandbox entitlements, App Store Connect setup
- [ ] **Multi-language improvements** — Parakeet supports 25 European languages; test and document language switching
- [ ] **Speaker diarization** — Identify different speakers in multi-person dictation
