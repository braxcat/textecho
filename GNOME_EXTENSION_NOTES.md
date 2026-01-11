# GNOME Shell Extension Approach

## Why Consider This
- Full control over overlay positioning (mouse-following works)
- Transparent overlays work properly
- Global input event capture built-in
- Runs inside the compositor

## Architecture

```
GNOME Shell Extension (JavaScript)
├── UI overlay (Clutter/St toolkit)
├── Mouse button detection
├── Mouse position tracking
└── Communicates via D-Bus or socket
           ↓
Transcription Daemon (Python) - keep as-is
           ↓
Audio Recording Helper (Python or GStreamer)
```

## Components to Rewrite

| Component | Current | Extension |
|-----------|---------|-----------|
| Overlay UI | Python/GTK4/Cairo | JavaScript/Clutter/St |
| Mouse detection | Python/evdev | JS (built-in to Shell) |
| Audio recording | Python/PyAudio | GStreamer via GJS, or external helper |
| Transcription | Python/OpenVINO | Keep as daemon |
| Text paste | ydotool | Same, or use IBus |

## Extension Structure

```
dictation@example.com/
├── extension.js      # Main entry point
├── overlay.js        # UI overlay with waveform
├── audioHelper.js    # GStreamer pipeline or subprocess
├── metadata.json     # Extension metadata
├── stylesheet.css    # Tokyo Night theme
└── schemas/          # GSettings if needed
```

## Key APIs

- `Clutter.Actor` - Base for UI elements
- `St.Widget` - Shell toolkit widgets
- `St.DrawingArea` - For custom drawing (waveform)
- `global.display.connect('button-press-event')` - Mouse events
- `global.get_pointer()` - Mouse position
- `Gio.Subprocess` - For calling Python helpers

## Complexity

Medium-Hard. Main challenges:
1. Learning GJS and GNOME Shell APIs
2. Audio recording in GJS (GStreamer pipeline or Python helper)
3. Extension review if distributing

Time estimate: Few days if familiar with GJS, week+ if learning.

## Resources

- https://gjs.guide/
- https://gjs-docs.gnome.org/
- https://wiki.gnome.org/Projects/GnomeShell/Extensions
