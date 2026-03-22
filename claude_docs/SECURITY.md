# Security

## Required Permissions

| Permission | Why | Granted To |
|------------|-----|------------|
| **Accessibility** | CGEventTap for global hotkeys, text injection via Cmd+V | TextEcho.app |
| **Microphone** | Audio recording for transcription | TextEcho.app |

Permissions are tied to the app's code signature. Re-building with a new binary requires re-granting in System Settings > Privacy & Security.

## Code Signing

- **Ad-hoc signed** (`codesign --force --deep --sign -`)
- Not notarized — not distributable via Gatekeeper without re-signing
- Binary hash caching in build script preserves existing permissions when only Python files change
- **App Store target:** Apple Developer license + signing planned for future distribution

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

## Attack Surface

- **Minimal** — no network listeners, no HTTP server, no external API calls
- Unix sockets at `/tmp/textecho_*.sock` are local-only (LLM mode only, filesystem permissions)
- CGEventTap requires Accessibility permission (user-granted)
- Python daemons run as user process (no elevated privileges, LLM mode only)

## Dependencies

- **Swift:** WhisperKit (Core ML transcription) — sole third-party dependency
- **Optional:** llama-cpp-python (for LLM features, build with `--with-llm`)
- Dependabot monitors for known CVEs in all dependencies
