# Roadmap

## Current Status / Known Issues

- Python daemon sometimes crashes; latest crash showed `/opt/homebrew` Python 3.14 segfaults. We’re enforcing bundled venv usage and logging `Python executable:` in app logs to verify.
- No `python.log` in some runs (fixed by creating the file and forcing unbuffered output).

## Upcoming Features

- LLM responses should be copied to clipboard after showing on screen, and the on-screen result should remain visible until the user releases the dictation button.
