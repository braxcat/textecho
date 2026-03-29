# TextEcho: Parakeet TDT Integration Plan

## Summary

Replace WhisperKit as the default transcription engine with NVIDIA Parakeet TDT via FluidAudio SDK. Keep WhisperKit as a fallback option.

**Why:** 3.7x better accuracy (2.1% vs 7.8% WER), 3-6x faster, runs on Neural Engine via Core ML.

## Verified Facts

- **FluidAudio SDK:** 1,763 stars, Apache 2.0, actively maintained (released today), Swift actor-isolated
- **Parakeet TDT v3 Core ML model:** 174K downloads on HuggingFace, ~6GB on disk, CC-BY-4.0 license
- **API match:** `transcribe([Float]) → ASRResult` — near drop-in for WhisperKit's pattern
- **Audio format:** 16kHz mono Float32 — exact match with TextEcho's recording format
- **Model download:** FluidAudio manages HuggingFace downloads with progress callbacks
- **Load/unload:** `initialize(models:)` / `cleanup()` — maps to TextEcho's preload/idle-timeout
- **Thread safety:** `AsrManager` is a Swift actor — matches existing `WhisperKitTranscriber` pattern
- **System requirements:** macOS 14+, any Apple Silicon (M1/M2/M3/M4), Neural Engine

## Model Options for Users

| Model | Size | Languages | WER | Speed | Best for |
|---|---|---|---|---|---|
| Parakeet TDT v3 | ~6GB | 25 European | 2.1% | 3-6x faster | Default — best accuracy |
| Parakeet TDT v2 | ~6GB | English only | 2.1% | Slightly faster | English-only users |
| Parakeet EOU 120M | ~1GB | English only | Higher | Fastest | Small Macs, streaming |
| Whisper large-v3-turbo | ~1.6GB | 99 languages | 7.8% | Baseline | Fallback, rare languages |
| Whisper large-v3 | ~3GB | 99 languages | 7.4% | 6x slower | Maximum Whisper accuracy |

## Architecture

### Existing `Transcriber` protocol (already supports swappable backends)

```swift
// Current: WhisperKitTranscriber conforms to this
// New: ParakeetTranscriber will also conform
protocol Transcriber {
    func preload() async throws
    func transcribe(audioData: Data, sampleRate: Double) async throws -> String
}
```

### New: `ParakeetTranscriber` (actor)

```swift
import FluidAudio

actor ParakeetTranscriber: Transcriber {
    private var asrManager: AsrManager?
    private let modelVersion: AsrModelVersion

    init(modelVersion: AsrModelVersion = .v3) {
        self.modelVersion = modelVersion
    }

    func preload() async throws {
        let models = try await AsrModels.downloadAndLoad(version: modelVersion)
        asrManager = AsrManager()
        try await asrManager?.initialize(models: models)
    }

    func transcribe(audioData: Data, sampleRate: Double) async throws -> String {
        guard let asr = asrManager else { throw ASRError.notInitialized }
        let floats = audioData.toFloat32Array() // existing helper
        let result = try await asr.transcribe(floats, source: .microphone)
        return result.text
    }

    func cleanup() {
        asrManager?.cleanup()
        asrManager = nil
    }
}
```

## Implementation Steps

### Phase 1: Add FluidAudio dependency + ParakeetTranscriber

1. Add FluidAudio to `Package.swift`:
   ```swift
   .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.13.0")
   ```
2. Create `ParakeetTranscriber.swift` conforming to `Transcriber` protocol
3. Wire up model download with progress callback (for setup wizard)
4. Add `isModelCached()` check (for preload-on-startup logic)
5. Handle `cleanup()` for idle timeout unloading

### Phase 2: Config + model selection UI

1. Add `transcription_engine` field to `AppConfig` (`"parakeet"` or `"whisper"`)
2. Add `parakeet_model` field (`"v3"`, `"v2"`, `"eou"`)
3. Update Setup Wizard: show engine choice (Parakeet recommended, Whisper fallback)
4. Update Settings: engine picker, model picker
5. Show model sizes in the picker so users with smaller Macs can choose wisely

### Phase 3: AppState integration

1. Update `AppState.init()` to create either `ParakeetTranscriber` or `WhisperKitTranscriber` based on config
2. Preload logic already works via `Transcriber` protocol
3. Idle timeout already works if `ParakeetTranscriber.cleanup()` is called
4. Test transcription flow end-to-end

### Phase 4: Polish + attribution

1. Add CC-BY-4.0 attribution for Parakeet model (required by license)
2. Add FluidAudio attribution in About/Help
3. Update README with new engine options
4. Update landing page with accuracy comparison
5. Benchmark on user's Mac: compare Whisper vs Parakeet speed/accuracy

## License Requirements

- **FluidAudio SDK:** Apache 2.0 — no restrictions
- **Parakeet model weights:** CC-BY-4.0 — **must include attribution**
  - Add to Help window / About section: "Speech recognition powered by NVIDIA Parakeet, licensed under CC-BY-4.0"
  - Add to README
- **TextEcho itself:** MIT — compatible with both

## Risk Assessment

| Risk | Likelihood | Mitigation |
|---|---|---|
| FluidAudio API changes | Low (active, versioned) | Pin SwiftPM version |
| 6GB download too large | Medium | Offer Parakeet EOU (1GB) + Whisper turbo (1.6GB) as alternatives |
| CoreML compilation slow on first run | Medium | Show progress in wizard, cache compiled model |
| Parakeet accuracy not as good as benchmarks | Low | Keep Whisper as fallback, let users A/B test |
| FluidAudio abandoned | Low (1,763 stars, active) | WhisperKit fallback always available |

## Files to Create/Modify

| File | Action | What |
|---|---|---|
| `mac_app/Package.swift` | Edit | Add FluidAudio dependency |
| `ParakeetTranscriber.swift` | **New** | FluidAudio-based transcriber actor |
| `AppConfig.swift` | Edit | Add engine + parakeet model fields |
| `AppState.swift` | Edit | Select transcriber based on config |
| `SetupWizard.swift` | Edit | Engine choice + model picker |
| `SettingsWindow.swift` | Edit | Engine/model selection UI |
| `HelpWindow.swift` | Edit | Add Parakeet attribution |
| `README.md` | Edit | Document engine options |
| `docs/index.html` | Edit | Accuracy comparison on landing page |

## Estimated Effort

- Phase 1: ~2 hours (core integration)
- Phase 2: ~1.5 hours (config + UI)
- Phase 3: ~1 hour (wiring + testing)
- Phase 4: ~1 hour (polish + attribution)
- **Total: ~1 session**
