# Known Issues

## Model Management

### Curated model list is not device-aware
The curated model list in both the wizard and settings is a static hand-picked list. It is not filtered or reordered based on the current device's WhisperKit `ModelSupport` config. On M1, models like `openai_whisper-large-v3_turbo` are not in WhisperKit's M1 supported list and will show a "Not recommended for M1" tag even though they appear as top picks in the curated section. The curated list should be filtered and/or reordered at runtime based on the device's chip generation.

### Wizard model step lacks device-specific recommendation context
In the setup wizard, the curated model list shows no recommendation tags — users only see "Recommended for" / "Not recommended for" labels if they open the full model picker via "All models". The wizard model step should surface inline device-specific guidance so users can make an informed choice without leaving the step.
