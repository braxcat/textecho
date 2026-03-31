# Security

## Required Permissions

| Permission | Why | Granted To |
|------------|-----|------------|
| **Accessibility** | CGEventTap for global hotkeys, text injection via Cmd+V | TextEcho.app |
| **Microphone** | Audio recording for transcription | TextEcho.app |

Permissions are tied to the app's code signature. Re-building with a new binary requires re-granting in System Settings > Privacy & Security.

## Code Signing

- **Developer ID signed** with hardened runtime (`--options runtime`)
- **Apple notarized** via App Store Connect API key — no Gatekeeper warnings
- **Sigstore build attestation** — verifiable build provenance on GitHub Releases
- **Entitlements:** `mac_app/TextEcho.entitlements` — non-sandboxed (CGEventTap + IOKit HID require it), `audio-input` (microphone), `network.client` (WhisperKit model download from HuggingFace)
- **Dev builds:** ad-hoc signed (`codesign --force --deep --sign -`) when `--sign` flag is not used
- Binary hash caching in build script preserves existing permissions when only resource files change

### Release Workflow Security

- **GitHub Environment** with required approval before release jobs run
- **Tag protection** — only authorized users can push `v*` tags
- **CODEOWNERS** — PRs to workflows and signing files require review
- **Ephemeral keychain** — signing certificate imported into a temporary keychain, destroyed after build
- **SHA-pinned actions** — all third-party GitHub Actions pinned to specific commit SHAs
- **Secrets:** Developer ID certificate (P12), App Store Connect API key, stored as GitHub repository secrets

## Automated Security Scanning

### CodeQL (SAST)
- **Workflow:** `.github/workflows/codeql.yml`
- **Runs:** On PRs to main + weekly Monday 9am UTC
- **Scans:** Swift source for injection, path traversal, data races, etc.
- **Runner:** `macos-latest` (required for Swift compilation)

### Dependabot
- **Config:** `.github/dependabot.yml`
- **Monitors:** SwiftPM dependencies (WhisperKit etc.) + GitHub Actions versions
- **Schedule:** Weekly Monday checks
- **Action:** Creates PRs automatically when fixes are available

## Data Handling

- **Fully local** — no network calls after model download, no cloud services, no telemetry
- **No credentials or API keys** — all models run locally on-device
- **Config file:** `~/.textecho_config` (plaintext JSON, no secrets, atomic writes)
- **History file:** `~/.textecho_history.json` (0600 permissions, atomic writes)
- **Registers file:** `~/.textecho_registers.json` (plaintext, user clipboard snippets)
- **Logs:** `~/Library/Logs/TextEcho/` (app.log, python.log)
- **Model cache:** `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`

## Hardening Measures

- **Shell injection prevention:** `restartApp()` uses `Process` directly with arguments array — no bash `-c` string interpolation
- **Thread safety:** `AppState` is `@MainActor`; `WhisperKitTranscriber` is an actor; background work via `Task.detached`
- **Path traversal prevention:** `deleteModel()` rejects names containing `..` or `/`
- **Model name validation:** `switchModel()` validates against allowed character set
- **Atomic writes:** Config and history files use `.atomic` option to prevent corruption
- **File permissions:** History file set to 0600 (owner read/write only)
- **Observer cleanup:** NotificationCenter observers stored and removed in `deinit`
- **Memory cleanup:** WhisperKitTranscriber instances explicitly released after wizard/download use

## MLX LLM Security Controls

- **maxTokens=2048** — hard limit on LLM output to prevent runaway generation
- **Model ID validation** — only curated models from the approved list can be loaded
- **Config file permissions** — `~/.textecho_config` written with 0o600 (owner-only)
- **Custom prompt length cap** — prevents excessively long custom prompts
- **No network after download** — models cached locally at `~/.cache/huggingface/`, inference is fully offline
- **Actor isolation** — MLXLLMProcessor is a Swift actor (no shared mutable state)

## Attack Surface

- **Minimal** — no network listeners, no HTTP server, no external API calls
- CGEventTap requires Accessibility permission (user-granted)
- LLM runs as native Swift actor in-process (no separate daemon, no IPC)

## Dependencies

- **Swift:** FluidAudio (Parakeet TDT transcription, Apache 2.0) and WhisperKit (Whisper transcription) — two third-party Swift dependencies
- **Model weights:** Parakeet TDT models are licensed CC-BY-4.0 (NVIDIA) — attribution required in distribution
- **LLM:** MLXLLM + MLXLMCommon (native MLX Swift, GPU inference)
- Dependabot monitors for known CVEs in all dependencies
