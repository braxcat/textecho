# Planning

## Future Feature Ideas

### High Priority (Picked for next phases)

- **Search across history** — Add `searchable()` to history window with substring/fuzzy match via `localizedStandardContains`. Effort: ~1 day. Value: High.
- **Custom vocabulary (post-processing dictionary)** — Regex/dictionary replacement after transcription for known terms (e.g., "eye gear" → "AIgir"). Effort: ~1 day. Value: High. Future: explore FluidAudio's CTC head for vocabulary injection (added in 0.13.4).
- **Homebrew cask** — Ruby formula pointing at signed DMG in GitHub releases. Prerequisite: notarized DMG attached to each release. Effort: ~half day. Value: Medium (distribution reach).
- **Streaming accuracy benchmarking** — CLI tool comparing EOU 120M (streaming) vs Parakeet TDT V3 (batch) WER on curated test audio. Effort: ~1 day plus test corpus curation. Value: Medium (confidence in defaults).

### Medium Priority

- **Shortcuts.app integration** — Expose App Intents so users can build automation (e.g., "Transcribe clipboard audio", Siri triggers). Effort: 3-5 days. Value: Medium.
- **Spotlight indexing of transcription history** — Surface past transcriptions in macOS Spotlight via Core Spotlight API. Effort: 2-3 days. Value: Medium.
- **iPhone app (keyboard extension)** — Port transcription stack via shared Swift package, build a custom keyboard with mic button that transcribes into any text field. WhisperKit + FluidAudio support iOS 17+ on A14+. Tighter LLM constraints due to RAM. Effort: 2-4 weeks for MVP. Value: High but significant lift.

### Distribution

- DMG signing and notarization for Gatekeeper (in progress)
- Sparkle-based auto-update mechanism
- Homebrew cask formula (see High Priority above)

### Transcription Enhancements

- Multi-language support with language selector
- Speaker diarization (identify different speakers) — Phase 13
- ~~Real-time streaming transcription (partial results while recording)~~ — **COMPLETE** (v2.5.0, EOU 120M model via FluidAudio, Settings → Streaming Beta)
- ~~Pre-transcription RMS silence gate~~ — **REMOVED** (v2.5.0 — quiet/whispered speech now reaches the model)
- **WhisperKit streaming** — extend streaming to WhisperKit backend (EOU path currently Parakeet-only)
- **Streaming accuracy benchmarking** — see High Priority above
- **Custom vocabulary** — see High Priority above

### LLM Improvements

- Conversation memory across sessions
- Multiple model profiles (fast vs. accurate)
- ~~Model management UI~~ — **DECLINED** (out of scope)
- ~~RAG integration for document-aware prompts~~ — **DECLINED** (out of scope)

### UI/UX

- Waveform frequency spectrum visualization
- Global search across past transcriptions — see High Priority above
- ~~Transcription history panel~~ — **COMPLETE** (shipped PR #8, 2026-03-20)
- ~~Configurable overlay themes~~ — **COMPLETE** (shipped PR #7, 2026-03-19 — 5 presets + full customization)

### System Integration

- Shortcuts.app integration — see Medium Priority above
- Spotlight indexing of transcription history — see Medium Priority above
- ~~AppleScript support~~ — **DECLINED** (App Intents/Shortcuts is the modern replacement)

### Mobile

- iPhone app via keyboard extension — see Medium Priority above
