#!/usr/bin/env python3
"""
GTK4 overlay for dictation recording.
Features Tokyo Night theme, bar waveform visualization.
"""

import gi
gi.require_version('Gtk', '4.0')

from gi.repository import Gtk, Gdk, GLib, Pango
import math
import struct
import subprocess

# Try to load layer-shell (works on wlroots compositors like Sway/Hyprland)
LAYER_SHELL_AVAILABLE = False
try:
    from ctypes import CDLL
    CDLL('/usr/local/lib/x86_64-linux-gnu/libgtk4-layer-shell.so')
    gi.require_version('Gtk4LayerShell', '1.0')
    from gi.repository import Gtk4LayerShell as LayerShell
    LAYER_SHELL_AVAILABLE = True
except:
    LayerShell = None

# Try to load GNOME extension for window positioning (works on GNOME/Wayland)
GNOME_EXTENSION_AVAILABLE = False
try:
    from window_positioner import (
        position_window_at_mouse,
        get_mouse_position as extension_get_mouse_position,
        start_following as extension_start_following,
        stop_following as extension_stop_following,
        is_extension_available
    )
    GNOME_EXTENSION_AVAILABLE = is_extension_available()
except ImportError:
    pass


# =============================================================================
# Tokyo Night Theme Colors
# =============================================================================
class TokyoNight:
    # Backgrounds
    BG = (0.102, 0.106, 0.149, 0.90)         # #1a1b26 with 90% opacity
    BG_DARK = (0.067, 0.071, 0.106, 0.95)    # #11121a with 95% opacity

    # Foregrounds
    FG = (0.663, 0.694, 0.839, 1.0)          # #a9b1d6
    FG_DARK = (0.337, 0.369, 0.482, 1.0)     # #565f89

    # Accents
    BLUE = (0.478, 0.635, 0.969, 1.0)        # #7aa2f7
    CYAN = (0.490, 0.812, 1.0, 1.0)          # #7dcfff
    PURPLE = (0.733, 0.604, 0.969, 1.0)      # #bb9af7
    RED = (0.969, 0.463, 0.557, 1.0)         # #f7768e
    GREEN = (0.616, 0.808, 0.416, 1.0)       # #9ece6a
    ORANGE = (1.0, 0.620, 0.392, 1.0)        # #ff9e64


# =============================================================================
# ROUNDED CORNERS - Set to 0 to disable rounded corners
# =============================================================================
CORNER_RADIUS = 16  # Set to 0 for sharp corners


def get_mouse_position():
    """Get current mouse position."""
    # Try GNOME extension first (works on Wayland/GNOME)
    if GNOME_EXTENSION_AVAILABLE:
        pos = extension_get_mouse_position()
        if pos:
            return pos

    # Fallback to xdotool (works on X11)
    try:
        result = subprocess.run(
            ["xdotool", "getmouselocation", "--shell"],
            capture_output=True, text=True, timeout=1
        )
        if result.returncode == 0:
            x, y = 960, 540  # defaults
            for line in result.stdout.strip().split('\n'):
                if line.startswith('X='):
                    x = int(line.split('=')[1])
                elif line.startswith('Y='):
                    y = int(line.split('=')[1])
            return x, y
    except Exception as e:
        pass
    return 960, 540


class WaveformDrawingArea(Gtk.DrawingArea):
    """Custom drawing area for bar-style waveform visualization."""

    def __init__(self):
        super().__init__()
        self.audio_data = []
        self.num_bars = 32
        self.set_draw_func(self.on_draw)

    def update_audio(self, data):
        """Update with new audio data (list of amplitudes 0.0-1.0)."""
        self.audio_data = data
        self.queue_draw()

    def on_draw(self, area, ctx, width, height):
        """Draw the bar waveform using Gtk.Snapshot."""
        if not self.audio_data:
            self._draw_idle_bars(ctx, width, height)
        else:
            self._draw_waveform_bars(ctx, width, height)

    def _draw_idle_bars(self, cr, width, height):
        """Draw subtle idle bars when not recording."""
        bar_width = width / self.num_bars
        padding = 2

        for i in range(self.num_bars):
            x = i * bar_width + padding
            bar_h = height * 0.1
            y = (height - bar_h) / 2

            cr.set_source_rgba(*TokyoNight.FG_DARK)
            self._draw_rounded_bar(cr, x, y, bar_width - padding * 2, bar_h)
            cr.fill()

    def _draw_waveform_bars(self, cr, width, height):
        """Draw active waveform bars."""
        bar_width = width / self.num_bars
        padding = 2
        min_height = 4

        samples_per_bar = max(1, len(self.audio_data) // self.num_bars)

        for i in range(self.num_bars):
            start_idx = i * samples_per_bar
            end_idx = min(start_idx + samples_per_bar, len(self.audio_data))

            if start_idx < len(self.audio_data):
                amplitude = sum(self.audio_data[start_idx:end_idx]) / max(1, end_idx - start_idx)
            else:
                amplitude = 0.0

            bar_h = max(min_height, amplitude * height * 0.9)
            x = i * bar_width + padding
            y = (height - bar_h) / 2

            if amplitude > 0.6:
                color = TokyoNight.CYAN
            elif amplitude > 0.3:
                t = (amplitude - 0.3) / 0.3
                color = self._blend_colors(TokyoNight.BLUE, TokyoNight.CYAN, t)
            else:
                color = TokyoNight.BLUE

            if amplitude > 0.7:
                cr.set_source_rgba(color[0], color[1], color[2], 0.3)
                self._draw_rounded_bar(cr, x - 2, y - 2, bar_width - padding * 2 + 4, bar_h + 4)
                cr.fill()

            cr.set_source_rgba(*color)
            self._draw_rounded_bar(cr, x, y, bar_width - padding * 2, bar_h)
            cr.fill()

    def _draw_rounded_bar(self, cr, x, y, width, height):
        """Draw a bar with rounded ends."""
        if width <= 0 or height <= 0:
            return
        radius = min(width / 2, height / 2, 4)

        cr.new_path()
        cr.arc(x + radius, y + radius, radius, math.pi, 1.5 * math.pi)
        cr.arc(x + width - radius, y + radius, radius, 1.5 * math.pi, 2 * math.pi)
        cr.arc(x + width - radius, y + height - radius, radius, 0, 0.5 * math.pi)
        cr.arc(x + radius, y + height - radius, radius, 0.5 * math.pi, math.pi)
        cr.close_path()

    def _blend_colors(self, c1, c2, t):
        """Blend two colors by factor t (0.0-1.0)."""
        return tuple(c1[i] + (c2[i] - c1[i]) * t for i in range(4))


class DictationOverlay:
    """GTK4 overlay window for dictation."""

    # WM_CLASS used by GNOME extension to find this window
    WM_CLASS = "dictation-overlay"

    def __init__(self):
        self.app = None
        self.window = None
        self.waveform = None
        self.waveform_frame = None
        self.middle_box = None
        self.status_label = None
        self.interim_label = None
        self.info_label = None
        self.transcription_label = None
        self.is_visible = False
        self.follow_mouse_id = None
        self.use_layer_shell = False
        self.use_gnome_extension = False

        # Confirmation mode state
        self.awaiting_confirmation = False
        self.on_confirm_callback = None
        self.on_cancel_callback = None

        # Flash mode state (for mode indicator)
        self.is_flashing = False
        self.flash_timeout_id = None

        # Window dimensions
        self.width = 400
        self.height_compact = 200
        self.height_expanded = 280
        self.height_confirmation = 120  # Smaller for confirmation (just text + instructions)
        self.height_flash = 80  # Small for mode indicator flash
        self.width_flash = 180  # Narrower for mode indicator flash
        self.height = self.height_compact
        self.target_height = self.height_compact
        self.resize_timeout_id = None

    def create_window(self, app):
        """Create the overlay window."""
        self.app = app

        # Get screen center for positioning hint
        display = Gdk.Display.get_default()
        monitors = display.get_monitors()
        if monitors.get_n_items() > 0:
            monitor = monitors.get_item(0)
            geom = monitor.get_geometry()
            self.screen_width = geom.width
            self.screen_height = geom.height
        else:
            self.screen_width = 1920
            self.screen_height = 1080

        # Check if we're on GNOME
        import os
        session = os.environ.get('XDG_CURRENT_DESKTOP', '').lower()
        self.is_gnome = 'gnome' in session or 'ubuntu' in session

        self.window = Gtk.Window(application=app)
        self.window.set_default_size(self.width, self.height)
        self.window.set_decorated(False)
        self.window.set_resizable(False)

        # Set WM_CLASS so GNOME extension can find this window
        self.window.set_title(self.WM_CLASS)

        # Try layer-shell if available (works on Sway/Hyprland, NOT GNOME)
        if LAYER_SHELL_AVAILABLE and LayerShell and not self.is_gnome:
            try:
                LayerShell.init_for_window(self.window)
                LayerShell.set_layer(self.window, LayerShell.Layer.OVERLAY)
                LayerShell.set_keyboard_mode(self.window, LayerShell.KeyboardMode.NONE)
                # Center it on screen using layer-shell margins
                center_x = (self.screen_width - self.width) // 2
                center_y = (self.screen_height - self.height) // 2
                LayerShell.set_anchor(self.window, LayerShell.Edge.TOP, True)
                LayerShell.set_anchor(self.window, LayerShell.Edge.LEFT, True)
                LayerShell.set_margin(self.window, LayerShell.Edge.TOP, center_y)
                LayerShell.set_margin(self.window, LayerShell.Edge.LEFT, center_x)
                self.use_layer_shell = True
            except Exception:
                pass

        # Use GNOME extension for positioning if on GNOME and extension is available
        if self.is_gnome and GNOME_EXTENSION_AVAILABLE:
            self.use_gnome_extension = True

        # Apply CSS for styling
        self._apply_css()

        # Create content
        self._create_content()

        # Add keyboard event controller for Escape to cancel
        key_controller = Gtk.EventControllerKey()
        key_controller.connect('key-pressed', self._on_key_pressed)
        self.window.add_controller(key_controller)

        # Start hidden
        self.window.set_visible(False)

    def _on_key_pressed(self, controller, keyval, keycode, state):
        """Handle keyboard events on the overlay window."""
        if self.awaiting_confirmation and keyval == Gdk.KEY_Escape:
            print("Escape pressed - canceling")
            self.handle_click(False)
            return True  # Event handled
        return False

    def _apply_css(self):
        """Apply CSS styling for Tokyo Night theme."""
        css = f"""
        window {{
            background-color: rgba(26, 27, 38, 0.90);
            border-radius: {CORNER_RADIUS}px;
        }}

        .status-recording {{
            color: #f7768e;
            font-size: 18px;
            font-weight: bold;
        }}

        .status-transcribing {{
            color: #bb9af7;
            font-size: 18px;
            font-weight: bold;
        }}

        .status-thinking {{
            color: #7dcfff;
            font-size: 18px;
            font-weight: bold;
        }}

        .prompt-text {{
            color: #565f89;
            font-size: 12px;
            font-style: italic;
            padding: 4px 10px;
            margin-bottom: 4px;
        }}

        .register-box {{
            padding: 4px 8px;
            margin-bottom: 6px;
        }}

        .register-indicator {{
            font-size: 11px;
            font-weight: bold;
            padding: 2px 6px;
            margin: 0 2px;
            border-radius: 4px;
        }}

        .register-filled {{
            background-color: rgba(122, 162, 247, 0.3);
            color: #7aa2f7;
        }}

        .register-empty {{
            background-color: rgba(86, 95, 137, 0.2);
            color: #565f89;
        }}

        .register-clipboard {{
            background-color: rgba(158, 206, 106, 0.3);
            color: #9ece6a;
        }}

        .status-info {{
            color: #a9b1d6;
            font-size: 12px;
        }}

        .waveform-container {{
            background-color: rgba(17, 18, 26, 0.95);
            border-radius: {max(0, CORNER_RADIUS - 4)}px;
            padding: 10px;
        }}

        .interim-text {{
            color: #9ece6a;
            font-size: 13px;
            font-style: italic;
            padding: 6px 10px;
            background-color: rgba(17, 18, 26, 0.8);
            border-radius: 6px;
        }}

        .status-confirmation {{
            color: #7aa2f7;
            font-size: 18px;
            font-weight: bold;
        }}

        .transcription-text {{
            color: #c0caf5;
            font-size: 14px;
            padding: 8px 10px;
            background-color: rgba(17, 18, 26, 0.95);
            border-radius: 8px;
            margin-bottom: 6px;
        }}

        .info-confirm {{
            color: #9ece6a;
        }}

        .info-cancel {{
            color: #f7768e;
        }}
        """

        css_provider = Gtk.CssProvider()
        css_provider.load_from_string(css)

        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

    def _create_content(self):
        """Create the window content."""
        # Main container with padding
        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        main_box.set_margin_top(15)
        main_box.set_margin_bottom(15)
        main_box.set_margin_start(15)
        main_box.set_margin_end(15)

        # Status label
        self.status_label = Gtk.Label(label="Recording...")
        self.status_label.add_css_class("status-recording")
        main_box.append(self.status_label)

        # Waveform container (hidden during confirmation)
        self.waveform_frame = Gtk.Frame()
        self.waveform_frame.add_css_class("waveform-container")

        self.waveform = WaveformDrawingArea()
        self.waveform.set_size_request(self.width - 50, 100)
        self.waveform_frame.set_child(self.waveform)
        main_box.append(self.waveform_frame)

        # Register indicators (shows which registers have content during LLM mode)
        self.register_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=2)
        self.register_box.add_css_class("register-box")
        self.register_box.set_halign(Gtk.Align.CENTER)
        self.register_box.set_visible(False)

        # Clipboard indicator
        self.clipboard_indicator = Gtk.Label(label="CB")
        self.clipboard_indicator.add_css_class("register-indicator")
        self.clipboard_indicator.add_css_class("register-empty")
        self.register_box.append(self.clipboard_indicator)

        # Register 1-9 indicators
        self.register_indicators = {}
        for i in range(1, 10):
            indicator = Gtk.Label(label=str(i))
            indicator.add_css_class("register-indicator")
            indicator.add_css_class("register-empty")
            self.register_indicators[i] = indicator
            self.register_box.append(indicator)

        main_box.append(self.register_box)

        # Prompt label (shows spoken prompt during LLM streaming)
        self.prompt_label = Gtk.Label(label="")
        self.prompt_label.add_css_class("prompt-text")
        self.prompt_label.set_wrap(True)
        self.prompt_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
        self.prompt_label.set_max_width_chars(45)
        self.prompt_label.set_visible(False)
        main_box.append(self.prompt_label)

        # Transcription display label (shown during confirmation, hidden otherwise)
        self.transcription_label = Gtk.Label(label="")
        self.transcription_label.add_css_class("transcription-text")
        self.transcription_label.set_wrap(True)
        self.transcription_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
        self.transcription_label.set_max_width_chars(45)
        self.transcription_label.set_visible(False)
        self.transcription_label.set_selectable(True)
        main_box.append(self.transcription_label)

        # Middle spacer box - always expands to fill available space
        # This keeps info_label anchored to the bottom
        self.middle_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.middle_box.set_vexpand(True)  # Always absorbs extra vertical space
        self.middle_box.set_valign(Gtk.Align.FILL)

        # Interim transcription label (hidden until we have text)
        self.interim_label = Gtk.Label(label="")
        self.interim_label.add_css_class("interim-text")
        self.interim_label.set_wrap(True)
        self.interim_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
        self.interim_label.set_max_width_chars(45)
        self.interim_label.set_visible(False)
        self.interim_label.set_valign(Gtk.Align.START)  # Align to top of middle_box
        self.middle_box.append(self.interim_label)

        main_box.append(self.middle_box)

        # Info label - stays at bottom (no vexpand, so it takes only its natural size)
        self.info_label = Gtk.Label(label="Release mouse button to transcribe")
        self.info_label.add_css_class("status-info")
        main_box.append(self.info_label)

        self.window.set_child(main_box)

    def _position_window(self, x, y):
        """Position the window centered above the given point."""
        # Use GNOME extension for positioning (works on Wayland/GNOME)
        if self.use_gnome_extension:
            # Extension positions at mouse, so just call it
            # The window title is used as WM_CLASS match
            position_window_at_mouse(self.WM_CLASS)
            return

        # Use layer-shell for positioning (works on Sway/Hyprland)
        pos_x = x - self.width // 2
        pos_y = y - self.height - 20  # 20px above cursor

        if self.use_layer_shell and LayerShell:
            try:
                LayerShell.set_margin(self.window, LayerShell.Edge.LEFT, max(0, pos_x))
                LayerShell.set_margin(self.window, LayerShell.Edge.TOP, max(0, pos_y))
                LayerShell.set_anchor(self.window, LayerShell.Edge.TOP, True)
                LayerShell.set_anchor(self.window, LayerShell.Edge.LEFT, True)
            except Exception as e:
                pass

    def show(self, x, y):
        """Show the overlay at position (centered above the given point)."""

        # Cancel any pending flash
        if self.flash_timeout_id:
            GLib.source_remove(self.flash_timeout_id)
            self.flash_timeout_id = None
        self.is_flashing = False

        # Restore normal window size (in case we were showing flash)
        self.window.set_default_size(self.width, self.height_compact)
        self.height = self.height_compact

        # Restore info label visibility (in case we were showing flash)
        self.info_label.set_visible(True)

        # Position the window
        self._position_window(x, y)

        self.window.set_visible(True)
        self.is_visible = True

        # Start following mouse
        self.start_following_mouse()

        # Reset status
        self.set_status("recording")

    def hide(self):
        """Hide the overlay."""
        self.stop_following_mouse()
        # Cancel any resize animation
        if self.resize_timeout_id:
            GLib.source_remove(self.resize_timeout_id)
            self.resize_timeout_id = None
        # Cancel any pending flash
        if self.flash_timeout_id:
            GLib.source_remove(self.flash_timeout_id)
            self.flash_timeout_id = None
        self.is_flashing = False
        self.window.set_visible(False)
        self.is_visible = False

    def start_following_mouse(self):
        """Start updating position to follow mouse."""
        # Use GNOME extension's internal tracking (smoother, no D-Bus per-frame)
        if self.use_gnome_extension:
            extension_start_following(self.WM_CLASS)
            return

        # Follow mouse if layer-shell is available
        if not self.use_layer_shell:
            return
        if self.follow_mouse_id:
            return
        self.follow_mouse_id = GLib.timeout_add(16, self._update_position)  # ~60 FPS

    def stop_following_mouse(self):
        """Stop following mouse."""
        # Stop GNOME extension tracking
        if self.use_gnome_extension:
            extension_stop_following()

        if self.follow_mouse_id:
            GLib.source_remove(self.follow_mouse_id)
            self.follow_mouse_id = None

    def _update_position(self):
        """Update window position to follow mouse."""
        if not self.is_visible:
            return False

        # Get current mouse position using xdotool
        x, y = get_mouse_position()
        self._position_window(x, y)

        return True  # Continue calling

    def set_status(self, status):
        """Set the status display."""
        if status == "recording":
            self.awaiting_confirmation = False
            self.status_label.set_visible(True)
            self.status_label.set_text("Recording...")
            self.status_label.remove_css_class("status-transcribing")
            self.status_label.remove_css_class("status-confirmation")
            self.status_label.add_css_class("status-recording")
            self.info_label.set_text("Release mouse button to transcribe")
            self.info_label.remove_css_class("info-confirm")
            self.info_label.remove_css_class("info-cancel")
            # Show waveform and spacer, hide transcription, prompt, and registers
            self.waveform_frame.set_visible(True)
            self.middle_box.set_visible(True)
            self.middle_box.set_vexpand(True)  # Re-enable expand for recording mode
            self.transcription_label.set_visible(False)
            self.prompt_label.set_visible(False)
            self.register_box.set_visible(False)
            # Clear interim text and reset to compact size
            if self.interim_label:
                self.interim_label.set_text("")
                self.interim_label.set_visible(False)
            self.height = self.height_compact
            self.target_height = self.height_compact
            self.window.set_default_size(self.width, self.height)
        elif status == "transcribing":
            self.awaiting_confirmation = False
            self.status_label.set_visible(True)
            self.status_label.set_text("Transcribing...")
            self.status_label.remove_css_class("status-recording")
            self.status_label.remove_css_class("status-confirmation")
            self.status_label.remove_css_class("status-thinking")
            self.status_label.add_css_class("status-transcribing")
            self.info_label.set_text("Please wait...")
            self.info_label.remove_css_class("info-confirm")
            self.info_label.remove_css_class("info-cancel")
            # Hide interim text and reset to compact size
            if self.interim_label:
                self.interim_label.set_text("")
                self.interim_label.set_visible(False)
            self._animate_to_height(self.height_compact)
        elif status == "thinking":
            self.awaiting_confirmation = False
            self.status_label.set_visible(True)
            self.status_label.set_text("Thinking...")
            self.status_label.remove_css_class("status-recording")
            self.status_label.remove_css_class("status-confirmation")
            self.status_label.remove_css_class("status-transcribing")
            self.status_label.add_css_class("status-thinking")
            self.info_label.set_text("Processing with LLM...")
            self.info_label.remove_css_class("info-confirm")
            self.info_label.remove_css_class("info-cancel")
            # Hide waveform, show streaming text area
            self.waveform_frame.set_visible(False)
            self.middle_box.set_visible(False)
            self.transcription_label.set_text("")
            self.transcription_label.set_visible(True)
            self._animate_to_height(self.height_compact)

    def update_register_indicators(self, has_clipboard=False, filled_registers=None):
        """Update which register indicators are shown as filled.

        Args:
            has_clipboard: True if primary clipboard has content
            filled_registers: Set or list of register numbers (1-9) that have content
        """
        if filled_registers is None:
            filled_registers = set()

        # Update clipboard indicator
        self.clipboard_indicator.remove_css_class("register-empty")
        self.clipboard_indicator.remove_css_class("register-clipboard")
        if has_clipboard:
            self.clipboard_indicator.add_css_class("register-clipboard")
        else:
            self.clipboard_indicator.add_css_class("register-empty")

        # Update register indicators
        for i in range(1, 10):
            indicator = self.register_indicators[i]
            indicator.remove_css_class("register-empty")
            indicator.remove_css_class("register-filled")
            if i in filled_registers:
                indicator.add_css_class("register-filled")
            else:
                indicator.add_css_class("register-empty")

    def show_llm_recording(self, has_clipboard=False, filled_registers=None):
        """Show LLM recording mode with register indicators."""
        self.set_status("recording")
        self.status_label.set_text("Recording prompt...")
        self.info_label.set_text("Release to send to LLM")
        # Show register indicators
        self.update_register_indicators(has_clipboard, filled_registers)
        self.register_box.set_visible(True)

    def start_streaming(self, prompt=""):
        """Initialize streaming mode - hide waveform, show prompt, prepare for response."""
        self.set_status("thinking")
        self.streaming_text = ""
        # Hide register indicators during streaming
        self.register_box.set_visible(False)
        # Show the prompt above the response
        if prompt:
            self.prompt_label.set_text(f'"{prompt}"')
            self.prompt_label.set_visible(True)
        else:
            self.prompt_label.set_visible(False)
        self.transcription_label.set_text("")

    def append_streaming_token(self, token):
        """Append a token to the streaming display."""
        if not hasattr(self, 'streaming_text'):
            self.streaming_text = ""
        self.streaming_text += token
        self.transcription_label.set_text(self.streaming_text)
        # Adjust height based on content
        num_lines = max(1, (len(self.streaming_text) + 39) // 40)
        text_height = 50 + (num_lines * 18)
        target = min(text_height + 80, 400)  # Cap at 400px
        if target > self.height:
            self._animate_to_height(target)

    def show_confirmation(self, text, on_confirm, on_cancel):
        """Show confirmation mode with transcribed text.

        Args:
            text: The transcribed text to display
            on_confirm: Callback to call when user left-clicks (paste)
            on_cancel: Callback to call when user right-clicks (dismiss)
        """
        self.on_confirm_callback = on_confirm
        self.on_cancel_callback = on_cancel

        # Cancel any pending resize animation
        if self.resize_timeout_id:
            GLib.source_remove(self.resize_timeout_id)
            self.resize_timeout_id = None

        # Hide status label entirely in confirmation mode
        self.status_label.set_visible(False)

        # Hide waveform and spacer, show transcription
        self.waveform_frame.set_visible(False)
        self.middle_box.set_visible(False)
        self.middle_box.set_vexpand(False)  # Disable expand so it doesn't take space when hidden
        self.interim_label.set_visible(False)
        self.transcription_label.set_text(text)
        self.transcription_label.set_visible(True)

        # Update info label with instructions
        self.info_label.set_text("Left-click to paste  •  Right-click/Esc to cancel")

        # Calculate target height based on text content
        # ~40 chars per line at current width, ~18px per line
        num_lines = max(1, (len(text) + 39) // 40)
        text_height = 16 + (num_lines * 18) + 16  # padding + lines + padding
        info_height = 30  # info label height
        margins = 30  # top + bottom margins
        target_height = text_height + info_height + margins

        # Animate to the calculated height
        self._animate_to_height(target_height)

        # Enable confirmation mode immediately
        self.awaiting_confirmation = True

    def handle_click(self, is_left_click):
        """Handle mouse click during confirmation mode.

        Args:
            is_left_click: True for left-click (paste), False for right-click (cancel)
        """
        if not self.awaiting_confirmation:
            return False

        self.awaiting_confirmation = False

        if is_left_click and self.on_confirm_callback:
            self.on_confirm_callback()
        elif not is_left_click and self.on_cancel_callback:
            self.on_cancel_callback()

        # Clear callbacks
        self.on_confirm_callback = None
        self.on_cancel_callback = None

        return True

    def flash_mode_indicator(self, mode_text):
        """Flash a mode indicator above the mouse cursor.

        Args:
            mode_text: Text to display (e.g., "FAST" or "ACCURATE")
        """
        # Don't flash if we're currently recording or transcribing
        if self.is_visible and not self.is_flashing:
            return

        # Cancel any existing flash timeout
        if self.flash_timeout_id:
            GLib.source_remove(self.flash_timeout_id)
            self.flash_timeout_id = None

        # Get fresh mouse position
        try:
            x, y = get_mouse_position()
        except:
            x, y = 960, 540  # Fallback to screen center

        print(f"[DEBUG] Flashing mode indicator at mouse position: ({x}, {y})")

        # Set the status label to show the mode
        self.status_label.set_text(mode_text)
        self.status_label.remove_css_class("status-recording")
        self.status_label.remove_css_class("status-transcribing")
        self.status_label.add_css_class("status-transcribing")  # Use cyan color
        self.status_label.set_visible(True)

        # Hide everything else
        self.waveform_frame.set_visible(False)
        self.middle_box.set_visible(False)
        self.transcription_label.set_visible(False)
        self.interim_label.set_visible(False)
        self.register_box.set_visible(False)
        self.prompt_label.set_visible(False)
        self.info_label.set_visible(False)  # Hide the info label too

        # Resize window to smaller flash size
        self.window.set_default_size(self.width_flash, self.height_flash)
        self.height = self.height_flash

        # Show window first
        self.window.set_visible(True)
        self.is_visible = True
        self.is_flashing = True

        # THEN position it at mouse (GNOME extension needs window to be visible first)
        self._position_window(x, y)

        # Start following mouse briefly to trigger positioning
        if self.use_gnome_extension:
            self.start_following_mouse()

        # Auto-hide after 1 second
        def hide_flash():
            if self.is_flashing:  # Only hide if still in flash mode
                self.stop_following_mouse()  # Stop following before hiding
                self.window.set_visible(False)
                self.is_visible = False
                self.is_flashing = False
                self.flash_timeout_id = None
                # Restore normal window size
                self.window.set_default_size(self.width, self.height_compact)
                self.height = self.height_compact
                # Restore info label visibility (will be set by next show/set_status)
                self.info_label.set_visible(True)
            return False

        self.flash_timeout_id = GLib.timeout_add(1000, hide_flash)

    def set_interim_text(self, text):
        """Update the interim transcription display."""
        if self.interim_label:
            if text:
                self.interim_label.set_text(text)
                self.interim_label.set_visible(True)
                # Calculate height: 13px font, 6px padding top/bottom
                # ~40 chars per line at current width
                num_lines = max(1, (len(text) + 39) // 40)
                line_height = 17  # 13px font + line spacing
                extra_height = 12 + (num_lines * line_height)  # 12px padding + lines
                target = self.height_compact + extra_height
                self._animate_to_height(min(target, self.height_expanded))
            else:
                self.interim_label.set_text("")
                self.interim_label.set_visible(False)
                self._animate_to_height(self.height_compact)

    def _animate_to_height(self, target):
        """Smoothly animate window height to target."""
        if self.height == target:
            return

        self.target_height = target

        # Cancel any existing animation
        if self.resize_timeout_id:
            GLib.source_remove(self.resize_timeout_id)

        # Start animation
        self.resize_timeout_id = GLib.timeout_add(16, self._resize_step)  # ~60fps

    def _resize_step(self):
        """Single step of height animation."""
        step = 8  # Pixels per frame

        if self.height < self.target_height:
            self.height = min(self.height + step, self.target_height)
        elif self.height > self.target_height:
            self.height = max(self.height - step, self.target_height)

        self.window.set_default_size(self.width, self.height)

        if self.height == self.target_height:
            self.resize_timeout_id = None
            return False  # Stop animation

        return True  # Continue animation

    def update_waveform(self, audio_chunk):
        """Update waveform with new audio data."""
        if audio_chunk and self.waveform:
            # Convert bytes to normalized amplitudes with increased sensitivity
            samples = struct.unpack(f'{len(audio_chunk)//2}h', audio_chunk)
            # Apply gain and clamp to 0-1
            gain = 12.0
            normalized = [min(1.0, abs(s) / 32768.0 * gain) for s in samples]
            self.waveform.update_audio(normalized)


def test_overlay():
    """Test the overlay standalone."""
    def on_activate(app):
        overlay = DictationOverlay()
        overlay.create_window(app)

        # Show at current mouse position
        x, y = get_mouse_position()
        overlay.show(x, y)

        # Simulate some audio data
        import random
        def update_test_audio():
            if overlay.is_visible:
                # Generate fake audio data
                fake_data = bytes([random.randint(0, 255) for _ in range(2048)])
                overlay.update_waveform(fake_data)
                return True
            return False

        GLib.timeout_add(50, update_test_audio)

        # Auto-hide after 5 seconds
        GLib.timeout_add(5000, lambda: (overlay.hide(), False)[1])
        GLib.timeout_add(6000, lambda: (app.quit(), False)[1])

    app = Gtk.Application(application_id='com.dictation.overlay.test')
    app.connect('activate', on_activate)
    app.run(None)


if __name__ == "__main__":
    test_overlay()
