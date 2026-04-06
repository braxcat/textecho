# Planning

## Future Feature Ideas

### Distribution

- DMG signing and notarization for Gatekeeper
- Sparkle-based auto-update mechanism
- Homebrew cask formula

### Transcription Enhancements

- Multi-language support with language selector
- Speaker diarization (identify different speakers)
- ~~Real-time streaming transcription (partial results while recording)~~ — **COMPLETE** (v2.5.0, EOU 120M model via FluidAudio, Settings → Streaming Beta)
- ~~Pre-transcription RMS silence gate~~ — **REMOVED** (v2.5.0 — quiet/whispered speech now reaches the model)
- **WhisperKit streaming** — extend streaming to WhisperKit backend (EOU path currently Parakeet-only)
- **Streaming accuracy benchmarking** — compare EOU 120M streaming vs TDT V3 batch on real dictation
- Custom vocabulary / domain-specific fine-tuning

### LLM Improvements

- Conversation memory across sessions
- Model management UI (download, switch, delete models)
- RAG integration for document-aware prompts
- Multiple model profiles (fast vs. accurate)

### UI/UX

- Waveform frequency spectrum visualization
- ~~Transcription history panel~~ — **COMPLETE** (shipped PR #8, 2026-03-20)
- ~~Configurable overlay themes~~ — **COMPLETE** (shipped PR #7, 2026-03-19 — 5 presets + full customization)
- Global search across past transcriptions

### System Integration

- Shortcuts.app integration
- AppleScript support for automation
- Spotlight indexing of transcription history
