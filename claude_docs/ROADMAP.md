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
| 8 | PLANNED | Distribution — DMG signing, notarization, auto-update |
| 9 | PLANNED | Enhanced Transcription — multi-language, speaker diarization |

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

## Phase 8+: Future Work (TBD)

- DMG signing and notarization for distribution
- Auto-update mechanism
- Multi-language transcription support
- Speaker diarization
- LLM conversation memory across sessions

### Polish / Bug Fixes (Backlog)

- **DMG folder icon** — add a custom Applications folder icon to the DMG so the drag-to-install target is clearly visible
- **Accessibility permission UX** — ad-hoc code signing invalidates macOS accessibility grants on every rebuild; investigate smoother re-grant flow
- **Model download progress** — show download percentage in overlay during WhisperKit model download
