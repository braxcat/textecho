# TextEcho

Native macOS menu bar app for offline voice-to-text dictation. The app is written in Swift and uses two local transcription backends: **Parakeet TDT** via FluidAudio and **WhisperKit**. Optional local LLM processing is available only when building with `--with-llm`.

## Documentation

| Document | Purpose |
|----------|---------|
| [claude_docs/ARCHITECTURE.md](claude_docs/ARCHITECTURE.md) | System design, transcription flow, build pipeline |
| [claude_docs/TESTING.md](claude_docs/TESTING.md) | Test strategy |
| [docs/SIGNING.md](docs/SIGNING.md) | Code signing, notarization, secret rotation |

## Build Prerequisites

- macOS 14+
- Apple Silicon
- Xcode CLI tools
- Python 3.11 or 3.12 only if building with `--with-llm`

## Build Commands

| Command | Description |
|---------|-------------|
| `./build_native_app.sh` | Release build to `dist/TextEcho.app` |
| `./build_native_app.sh --debug` | Debug build to `dist/TextEcho.app` |
| `./build_native_app.sh --sign` | Developer ID signed release build |
| `./build_native_app.sh --with-llm` | Build with optional bundled LLM module |
| `./build_native_app.sh --clean` | Remove local build caches before building |
| `swift build -c release --package-path mac_app` | Build Swift target only |
| `./build_native_dmg.sh` | Create a distributable DMG |
| `./install_dev.sh` | Debug build and install the app for local dev testing |

## Architecture

```
TextEcho.app
├── AppMain → AppState (orchestrator)
├── InputMonitor (CGEventTap event handling)
├── AudioRecorder (AVAudioEngine → PCM)
├── Transcriber protocol
│   ├── ParakeetTranscriber (FluidAudio, default)
│   └── WhisperKitTranscriber (WhisperKit fallback)
├── StreamDeckPedalMonitor / TrackpadMonitor (IOKit HID input)
├── Overlay / SettingsWindow / HelpWindow / LogsWindow / HistoryWindow
├── TextInjector
└── PythonServiceManager (optional LLM only)

Optional (`--with-llm` build):
└── llm_daemon.py → Unix socket IPC
```

- Transcription is native Swift. No Python process is used unless the app is built with `--with-llm`.
- Transcription backends are actor-isolated behind `Transcriber`.

## Dev workflow

Break user requests into tracked tasks before starting work. All changes must be done on short-lived branches created from `dev` and merged back via PR, then deleted. Branch names must use one of: `feature/...`, `fix/...`, `refactor/...`, or `chore/...`, using lowercase kebab-case. Use GitHub CLI (`gh`) for issue, branch, and PR operations. Releases go from `dev` to `main`. Never create a PR until the user has explicitly approved creating it.