# TextEcho: LLM UX Polish Plan (v2.5.0)

## Context

MLX LLM works but needs UX refinements before it feels polished for users.

## Items

### 1. Model download progress in Settings
- When user selects an MLX model, show download progress bar
- MLX's `LLMModelFactory.shared.loadContainer()` supports progress callbacks
- Show model size, download speed, estimated time
- Allow cancellation

### 2. LLM step in Setup Wizard
- Add an optional LLM setup step after the transcription model step
- "Would you like to enable AI text processing?" → Yes/No
- If yes: engine picker, model picker with download, mode picker
- If no: skip (can enable later in Settings)

### 3. Better LLM mode picker
- Current: dropdown in Settings (Grammar/Rephrase/Answer/Custom)
- Better: visual cards or segmented control with descriptions
- Show what each mode does with an example
- Maybe a quick-switch in the menu bar or overlay

### 4. LLM result display improvements
- When llmAutoPaste is off, show result in overlay longer
- Add "Copy" and "Paste" buttons on the overlay for LLM results
- Show both original transcription and LLM result for comparison

### 5. Memory/disk budget indicator
- Show how much RAM Parakeet + LLM model use
- Show disk space used by cached models
- Recommend model sizes based on available RAM

## Files to modify
- `SetupWizard.swift` — new LLM setup step
- `SettingsWindow.swift` — progress bar, better mode picker
- `Overlay.swift` — LLM result display improvements
- `MLXLLMProcessor.swift` — progress callbacks
- `AppState.swift` — overlay interaction for LLM results
