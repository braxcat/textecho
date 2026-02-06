# Dictation Project Notes

## Development Guidelines

- Do NOT auto-install dependencies (no sudo, no pip install, no downloads)
- Let the user manually test features and install dependencies themselves
- User has Intel Meteor Lake CPU with NPU, ~20GB RAM available

## LLM Integration

### Architecture
- Uses llama-cpp-python for local inference
- Daemon architecture mirrors transcription_daemon.py
- Ctrl+Mouse4 triggers LLM mode (vs Mouse4 alone for transcription)
- Streaming responses displayed in overlay

### Hotkeys
| Action | Hotkey |
|--------|--------|
| Transcribe & paste | Mouse 4 (hold to record, release to transcribe) |
| LLM prompt | Ctrl + Mouse 4 (hold to record prompt, release to send to LLM) |
| Capture clipboard to register | Ctrl+Alt+[1-9] |
| Clear all registers | Ctrl+Alt+0 |
| Settings dialog | Ctrl+Alt+Space |

### Register System
- 9 registers (1-9) for storing clipboard snippets
- Registers clear on session restart (or manually with Ctrl+Alt+0)
- **All registers + primary clipboard are automatically included as context** in every LLM prompt
- No need to say "clipboard" - just speak your prompt naturally
- Workflow: copy snippets → Ctrl+Alt+1/2/3 to save → Ctrl+Mouse4 "fix this error"

### LLM Prompt Flow
1. Copy code/text to clipboard
2. Optionally save to registers with Ctrl+Alt+[1-9]
3. Ctrl+Mouse4 and speak your prompt (e.g., "summarize this", "fix the bug")
4. All context (clipboard + registers) automatically included
5. Response streams in overlay
6. Left-click to paste, right-click to cancel

### Setup
1. Install: `pip install llama-cpp-python`
2. Download model: Llama 3.2 3B GGUF recommended
3. Configure ~/.dictation_config:
   ```json
   {
     "llm_enabled": true,
     "llm_model_path": "/path/to/model.gguf"
   }
   ```
4. Start: `./daemon_control.sh start`
