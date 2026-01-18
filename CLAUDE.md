# CLAUDE.MD

> **Template Version:** 1.0.0 | **Last Updated:** 2026-01-18

**Purpose**: This is a master preference template for Claude Code agents. Copy this file to individual projects and customize the "Project-Specific Overrides" section with project details.

## Quick Navigation
- [About the Developer](#about-the-developer)
- [Communication Preferences](#communication-preferences)
- [Technical Environment](#technical-environment)
- [Code Quality Standards](#code-quality-standards)
- [Development Workflow](#development-workflow)
- [Decision-Making & Architecture](#decision-making--architecture)
- [Testing Philosophy](#testing-philosophy)
- [Documentation Practices](#documentation-practices)
- [Project-Specific Overrides](#project-specific-overrides)

---

## About the Developer

**Role & Perspective**: Product Manager & Developer with a dual perspective on software development.

**Experience Level**: Relatively new to coding but well-seasoned in product ownership and project management. This combination brings:
- **Product thinking**: Connect technical decisions to user impact and business value
- **Technical execution**: Growing skills in full-stack development
- **Strategic mindset**: Understand how code changes affect user experience, maintainability, and team velocity

**Primary Focus**: Full-stack web development with emphasis on practical, user-centered solutions.

---

## Communication Preferences

### Core Communication Style
**Balanced approach with context-dependent detail level**:
- **For architectural decisions**: Provide high-level summaries with clear trade-offs
- **For complex implementations**: Offer detailed explanations of the approach and reasoning
- **For routine changes**: Keep updates concise and focused

### Critical Guidelines

**Always explain trade-offs before implementation**:
- Present the costs and benefits of different approaches
- Discuss implications for performance, maintainability, complexity, and user experience
- Help connect technical decisions to product outcomes

**Ask clarifying questions when uncertain**:
- Never make assumptions when requirements are ambiguous
- Confirm understanding before proceeding with significant work
- Default to asking rather than assuming

**Proactively communicate potential issues**:
- Flag problems, blockers, or concerns early
- Suggest alternatives when encountering obstacles
- Provide context about risks or technical debt being introduced

**Leverage product management background**:
- Frame technical decisions in terms of user impact and business value
- Explain "why" behind technical choices, not just "what" or "how"
- Trust developer to understand implementation details once the reasoning is clear

---

## Technical Environment

### Primary Tech Stack
- **Frontend**: JavaScript/TypeScript (frameworks specified per project)
- **Backend**: Python, JavaScript/TypeScript (frameworks specified per project)
- **DevOps/Cloud**: Various platforms (specified per project)

### Preferences
- **TypeScript over JavaScript**: Prefer TypeScript for type safety
- **Modern language features**: Use current idioms and patterns
- **Project-specific versions**: See individual project CLAUDE.MD files for exact framework versions and dependencies

### Development Tools
- Git for version control
- Package managers (npm, pip, etc.)
- Testing frameworks (specified per project)
- Linters and formatters (let tools handle style)

---

## Code Quality Standards

### Core Principles

**Simplicity first - avoid over-engineering**:
- Choose straightforward solutions over clever ones
- Don't add complexity for hypothetical future needs
- Three similar lines of code is better than a premature abstraction
- Build for current requirements, refactor when patterns emerge

**Type safety**:
- Use TypeScript for JavaScript projects
- Add type hints in Python code
- Validate data at system boundaries (user input, external APIs)
- Trust internal code and framework guarantees

**Testing coverage**:
- Write tests alongside code, not after (see Testing Philosophy section)
- Cover main paths and critical edge cases
- Test behavior, not implementation details

**Documentation**:
- Comments explain WHY, not WHAT (code should be self-documenting)
- Document complex algorithms and business logic
- Add context for non-obvious decisions or trade-offs

### Quality Checklist
Before considering code complete, verify:
- [ ] Code is simple and readable
- [ ] Types are properly defined
- [ ] Tests cover main paths and edge cases
- [ ] Documentation explains intent and trade-offs
- [ ] No unnecessary complexity or abstraction

---

## Development Workflow

### Testing Approach
- **Write tests proactively**: Alongside implementation, not after
- **Test main paths and edge cases**: Focus on critical scenarios
- **Run tests before committing**: Ensure nothing is broken
- **Fix failures immediately**: Don't move forward with failing tests

### Commit Strategy
**Commit early and often** - frequent commits enable easy rollbacks:
- Push changes frequently so we can roll back if needed
- Each commit should be a logical unit of work
- Format: `<type>: <description>`
  - Examples: `feat: add user authentication`, `fix: resolve login redirect issue`, `docs: update API documentation`
- Reference issue numbers when applicable (e.g., `fix: resolve #123`)

### Code Changes
- **Start with smallest possible change** to achieve the goal
- **Refactor incrementally**, not in big bang rewrites
- **Keep changes focused and reviewable**
- **Avoid backwards-compatibility hacks**: If something is unused, delete it completely

---

## Decision-Making & Architecture

### When to Ask Before Proceeding
**Always ask before**:
- Major architectural decisions (new patterns, frameworks, dependencies)
- Breaking changes or API modifications
- Significant refactoring that touches multiple files
- Trade-offs that impact performance, security, or maintainability
- Uncertainty about requirements or approach

### When to Proceed Independently
**Go ahead without asking when**:
- Following established patterns in the codebase
- Implementing bug fixes with clear scope
- Adding tests or documentation
- Making routine updates or minor improvements

### Architecture Principles
- **Simplicity over cleverness**: Choose boring, proven solutions
- **Incremental improvement**: Take small steps, validate often
- **Defer premature decisions**: Don't add complexity for hypothetical future needs
- **Follow existing patterns**: Consistency over novelty (unless pattern is problematic)

---

## Testing Philosophy

### Testing Approach
- **Unit tests**: For core logic and utilities
- **Integration tests**: For API endpoints and database interactions
- **E2E tests**: For critical user flows (when applicable)
- **Test behavior, not implementation**: Focus on what code does, not how it does it

### Test Writing Guidelines

**Write tests alongside features** (Test-Driven or Test-Alongside Development):
- Don't wait until after implementation
- Tests help clarify requirements and edge cases
- Tests serve as living documentation

**Descriptive test names that explain the scenario**:
- Good: `test_user_login_fails_with_invalid_password`
- Poor: `test_login_2`

**Arrange-Act-Assert pattern**:
1. **Arrange**: Set up test data and conditions
2. **Act**: Execute the code being tested
3. **Assert**: Verify the expected outcome

**Mock external dependencies**:
- Mock APIs, databases, and third-party services
- Test your code in isolation
- Focus on edge cases and error handling

---

## Documentation Practices

### Code Documentation

**Comments explain WHY, not WHAT**:
- Good: `// Use exponential backoff to avoid overwhelming the API during recovery`
- Poor: `// Retry the request`

**Document complex logic and business rules**:
- Explain algorithms that aren't immediately obvious
- Document business constraints and validation rules
- Provide context for unusual approaches or workarounds

**Add JSDoc/docstrings for public APIs**:
- Document function parameters, return values, and exceptions
- Include usage examples for complex interfaces
- Keep documentation in sync with code changes

### Project Documentation
- **Keep README files current**: Installation, setup, common tasks
- **Update as you go**: Don't defer documentation to the end
- **Reference external docs**: Link to official documentation rather than duplicating it

### Inline Comments
- **Explain non-obvious decisions or trade-offs**
- **Reference issues, tickets, or external documentation** when relevant
- **Mark TODOs with context and owner**: `// TODO(username): Add caching after performance testing`

---

## Project-Specific Overrides

### Project Information
- **Project Name**: Dictation-Mac
- **Description**: Voice-to-text dictation tool with automatic silence detection, local Whisper transcription, and optional LLM processing. Features daemon architecture for fast response times and GTK4 overlay UI.
- **Repository**: https://github.com/braxcat/dictation-mac

### Development Guidelines

**CRITICAL**:
- Do NOT auto-install dependencies (no sudo, no pip install, no downloads)
- Let the user manually test features and install dependencies themselves

### Target Platform

**Current State**: Originally built for Linux (GNOME/Wayland)
**Migration Target**: macOS

**Hardware**:
- MacBook Pro M4 Max
- 36GB unified memory
- Apple Silicon (ARM64)

**Migration Decisions** (see `MIGRATION_PLAN.md` for full details):
- **Whisper**: MLX Whisper (Apple Silicon native)
- **UI**: PyObjC + AppKit (menu bar app with overlay)
- **Input monitoring**: CGEventTap via PyObjC (keyboard + mouse)
- **Text injection**: Accessibility API (AXUIElement)
- **Audio**: PyAudio (keep current)
- **LLM**: llama-cpp-python with Metal (keep current)
- **Architecture**: Keep daemon model
- **Goal**: macOS-only, no Linux compatibility needed

### Technical Stack Details
- **Language**: Python 3.12+
- **UI Framework**: GTK4 with PyGObject (Tokyo Night theme)
- **Speech Recognition**: OpenVINO + openvino-genai (WhisperPipeline)
- **LLM Integration**: llama-cpp-python for local inference
- **Audio**: PyAudio for recording, soundfile for WAV handling
- **Input Handling**: evdev for mouse button monitoring
- **Text Input**: ydotool (Wayland), xdotool (X11), wtype (alternative)
- **Package Manager**: uv (see pyproject.toml)

### Key Dependencies
```
evdev          - Input device monitoring
numpy          - Audio processing
openvino       - Whisper inference (CPU/NPU)
openvino-genai - GenAI pipelines
pyaudio        - Audio I/O
soundfile      - Audio file handling
PyGObject      - GTK4 bindings
pycairo        - Drawing primitives
pynput         - Keyboard/mouse input
pillow         - Image processing
llama-cpp-python - LLM support (optional)
```

### Project Structure
```
dictation-mac/
├── dictation_app_gtk.py      - Main app: GTK4 overlay + evdev + orchestration
├── transcription_daemon.py   - Whisper model daemon (keeps model loaded)
├── llm_daemon.py             - Local LLM daemon (llama-cpp)
├── dictation_overlay.py      - GTK4 overlay window component
├── recorder_gui.py           - Alternative Tkinter-based GUI
├── daemon_control.sh         - Start/stop/status for all daemons
├── window_positioner.py      - Window positioning utilities
├── transcribe.py             - Quick CLI transcription tool
├── gnome-extension/          - GNOME Shell extension for Wayland positioning
├── test_evdev.py             - Input device debugging
├── test_keyboard.py          - Keyboard input testing
├── export_whisper_*.py/sh    - Model export utilities (NPU/quantized)
└── pyproject.toml            - Dependencies and project config
```

### Important Files & Patterns

**Entry Points**:
- `dictation_app_gtk.py` - Main application
- `daemon_control.sh start` - Start all daemons

**Daemon Architecture**:
- `transcription_daemon.py` - Listens on `/tmp/dictation_transcription.sock`
- `llm_daemon.py` - Listens on `/tmp/dictation_llm.sock`
- JSON-over-socket protocol with newline delimiters
- Lazy model loading, auto-unload after idle timeout

**Configuration**: `~/.dictation_config` (JSON)
- `silence_duration`: Seconds before auto-stop (default: 2.5)
- `model_idle_timeout`: Model unload timer (default: 3600s)
- `transcription_device`: "CPU" or "NPU"
- `model_path`: Path to Whisper model
- `llm_enabled`: Enable LLM processing
- `llm_model_path`: Path to GGUF model

**Logs & PIDs**:
- `~/.dictation_transcription.log`, `~/.dictation_app.log`, `~/.dictation_llm.log`
- `~/.dictation_transcription.pid`, `~/.dictation_app.pid`, `~/.dictation_llm.pid`

### Hotkeys

| Action | Hotkey |
|--------|--------|
| Transcribe & paste | Mouse 4 (hold to record, release to transcribe) |
| LLM prompt | Ctrl + Mouse 4 (hold to record, release to send to LLM) |
| Toggle fast/accurate mode | Shift/Alt + Mouse 4 |
| Capture clipboard to register | Ctrl+Alt+[1-9] |
| Clear all registers | Ctrl+Alt+0 |
| Settings dialog | Ctrl+Alt+Space |
| Cancel recording | ESC |

### Register System (LLM Context)
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

### Running the Application
```bash
# Install dependencies
uv sync

# Start all daemons
./daemon_control.sh start

# Check status
./daemon_control.sh status

# View logs
./daemon_control.sh logs

# Stop everything
./daemon_control.sh stop
```

### LLM Setup (Optional)
1. Install: `pip install llama-cpp-python`
2. Download model: Llama 3.2 3B GGUF recommended
3. Configure `~/.dictation_config`:
   ```json
   {
     "llm_enabled": true,
     "llm_model_path": "/path/to/model.gguf"
   }
   ```
4. Start: `./daemon_control.sh start`

### Testing Utilities
- `test_evdev.py` - Debug input devices and find Mouse Button 4
- `test_keyboard.py` - Test keyboard input handling
- `uv run python transcribe.py audio.wav` - Quick transcription test

### Project-Specific Conventions
- Unix sockets for IPC (not HTTP)
- JSON protocol with newline delimiters
- Lazy model loading to minimize startup time
- Auto-unload models after idle to free RAM
- Tokyo Night color theme for UI
- Support both Wayland (layer-shell, GNOME extension) and X11 (xdotool)

---

**Template created**: 2026-01-18 | **For**: Claude Code Agents | **Maintained by**: braxcat
