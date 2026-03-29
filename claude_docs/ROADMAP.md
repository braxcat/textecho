# Roadmap

## Phase Summary

| Phase | Status | Description |
|-------|--------|-------------|
| 1 | COMPLETE | Documentation Alignment — chippy methodology |
| 2 | COMPLETE | Critical Stability Fixes — process lifecycle, socket timeouts, thread safety |
| 3 | COMPLETE | Resource Management Hardening — log rotation, graceful shutdown, thread safety |
| 4 | COMPLETE | Dead Code Removal — 4,500+ lines of legacy Python UI, stale files |
| 5 | COMPLETE | Code Quality — user-friendly errors, final docs |
| 6 | COMPLETE | MLX Whisper Upgrade — mlx-whisper + large-v3-turbo |
| 7 | COMPLETE | Native WhisperKit Migration — replace Python daemon with Swift WhisperKit |
| 8 | COMPLETE | UX Polish — pedal actions, auto-detect, cyberpunk overlay, wizard redesign |
| 9 | COMPLETE | Signed Release Pipeline — Developer ID signing, notarization, GitHub Actions |
| 10 | COMPLETE | Parakeet TDT Integration — dual-engine transcription, Parakeet default |
| 11 | PLANNED | Enhanced Transcription — multi-language, speaker diarization |

## Phase 10: Parakeet TDT Integration (v2.2.0)
**Status:** COMPLETE

- Evaluated all major local STT models (Whisper, Distil-Whisper, Moonshine, NVIDIA Canary/Parakeet, Apple SpeechAnalyzer, MLX Whisper)
- Parakeet TDT v3 selected: 2.1% WER (3.7x more accurate than Whisper), 3-6x faster, 600M params
- ParakeetTranscriber actor via FluidAudio SDK, conforms to existing Transcriber protocol
- WhisperKit retained as fallback (99 languages vs Parakeet's 25)
- Engine selection in Setup Wizard and Settings, no rebuild needed
- CC-BY-4.0 attribution for NVIDIA Parakeet model weights

## Phase 9: Signed Release Pipeline
**Status:** COMPLETE

- Developer ID signing with hardened runtime
- Apple notarization via App Store Connect API key
- GitHub Actions release workflow (triggered by v* tags)
- Sigstore build attestation for verifiable provenance
- Tag protection and CODEOWNERS for workflow/signing files

## Phase 8: UX Polish & Cyberpunk Overlay
**Status:** COMPLETE

- Per-pedal actions: center=push-to-talk, left=paste, right=enter
- 3-second auto-detect timer for pedal (no unplug/replug)
- Cyberpunk overlay: pink→purple→neon green, matrix green waveform, silver+green logo
- 6-step setup wizard with progress dots, back buttons, pedal detection
- Pedal toggle + position in Settings UI (no more config resetting)
- rebuild.sh one-command deploy, uninstall.sh cleanup
- Fixed audio capture from pedal (deferred engine start)
- Fixed model cache detection and name resolution

## Phase 7: Native WhisperKit Migration
**Status:** COMPLETE

- Replaced Python MLX Whisper daemon with native Swift WhisperKit (Core ML / Neural Engine)
- Deleted transcription_daemon_mlx.py — zero Python required for transcription
- Memory: ~1.6GB (down from ~3GB), no GPU contention (Neural Engine offloads)
- New Transcriber protocol + WhisperKitTranscriber actor
- Model picker in Setup Wizard and Settings (large-v3-turbo, large-v3, base.en)
- LLM module made fully optional (--with-llm build flag)
- In-app Help window with embedded user documentation
- macOS 14+ minimum (required by WhisperKit)

## Phase 11+: Future Work (TBD)

- **Apple SpeechAnalyzer (macOS 26)** — Apple's on-device speech framework, potential third engine option when macOS 26 ships
- Auto-update mechanism (Sparkle or similar)
- Multi-language transcription support
- Speaker diarization
- LLM conversation memory across sessions

### Polish / Bug Fixes (Backlog)

- **DMG folder icon** — add a custom Applications folder icon to the DMG so the drag-to-install target is clearly visible
- **Accessibility permission UX** — ad-hoc code signing invalidates macOS accessibility grants on every rebuild; investigate smoother re-grant flow
- **Model download progress** — show download percentage in overlay during WhisperKit model download
