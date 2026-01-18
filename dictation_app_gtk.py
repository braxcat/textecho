#!/usr/bin/env python3
"""
Unified dictation app with GTK4 overlay.
Combines evdev mouse monitoring, audio recording, and GTK4 overlay GUI.
"""

import os
import sys

# Set up environment for GTK4 layer-shell before any imports
os.environ['GI_TYPELIB_PATH'] = '/usr/local/lib/x86_64-linux-gnu/girepository-1.0'

import gi
gi.require_version('Gtk', '4.0')

from gi.repository import Gtk, Gdk, GLib
import json
import select
import signal
import socket
import struct
import subprocess
import threading
import time

import numpy as np
import pyaudio
from evdev import InputDevice, categorize, ecodes, list_devices

# Import our overlay
from dictation_overlay import DictationOverlay, LAYER_SHELL_AVAILABLE, GNOME_EXTENSION_AVAILABLE

# Import window positioner for Wayland support
try:
    from window_positioner import get_mouse_position as extension_get_mouse_position
except ImportError:
    extension_get_mouse_position = None

# Configuration
PID_FILE = os.path.expanduser("~/.dictation_app.pid")
CONFIG_FILE = os.path.expanduser("~/.dictation_config")
DAEMON_SOCKET = "/tmp/dictation_transcription.sock"
DAEMON_SOCKET_FAST = "/tmp/dictation_transcription_fast.sock"
DAEMON_SOCKET_ACCURATE = "/tmp/dictation_transcription_accurate.sock"
LLM_DAEMON_SOCKET = "/tmp/dictation_llm.sock"
MOUSE_BUTTON = ecodes.BTN_EXTRA  # Mouse 4 (first side button)


class DictationApp:
    def __init__(self, app):
        self.gtk_app = app
        self.overlay = DictationOverlay()

        # State
        self.is_recording = False
        self.frames = []
        self.stream = None
        self.record_thread = None
        self.mouse_devices = []
        self.running = True
        self.mouse_x = 960  # Track mouse position
        self.mouse_y = 540

        # Confirmation mode state
        self.pending_transcription = None
        self.old_clipboard = None

        # Early click detection during transcription
        self.is_transcribing = False
        self.early_left_click = False
        self.early_right_click = False

        # Modifier key state for hotkeys
        self.ctrl_pressed = False
        self.alt_pressed = False
        self.shift_pressed = False
        self.settings_dialog = None

        # LLM mode state (Ctrl+Mouse4 triggers LLM instead of paste)
        self.llm_mode = False

        # Clipboard registers (1-9) for multi-context LLM prompts
        self.registers = {}

        # Transcription mode state (for dual-daemon mode)
        self.transcription_mode_active = None  # Will be set from config

        # Load config
        self.config = self.load_config()

        # Initialize transcription mode from config (for dual-daemon mode)
        self.transcription_mode_active = self.config.get("transcription_mode_active", "fast")

        # Audio settings
        self.CHUNK = 1024
        self.FORMAT = pyaudio.paInt16
        self.CHANNELS = 1
        self.RATE = 16000
        self.actual_rate = self.RATE

        # Interim transcription settings (from config)
        self.pause_threshold = self.config.get("pause_threshold", 1.5)
        self.silence_amplitude = self.config.get("silence_amplitude", 0.02)
        self.transcription_mode = self.config.get("transcription_mode", "full")
        self.interim_enabled = self.config.get("interim_enabled", True)

        # Calculate pause detection threshold in chunks
        # CHUNK=1024 at 16kHz = ~64ms per chunk, 1.5s = ~23 chunks
        self.pause_chunks_threshold = int(self.pause_threshold * self.RATE / self.CHUNK)

        # Interim transcription state
        self.interim_transcriptions = []
        self.interim_pending = False
        self.last_interim_frame = 0

        # Initialize PyAudio
        self.audio = pyaudio.PyAudio()
        self.devices = self.get_input_devices()
        self.selected_device_index = self.get_default_device_index()

        # Create overlay window
        self.overlay.create_window(app)

        # Find mouse devices
        self.mouse_devices = self.find_mouse_devices()
        if not self.mouse_devices:
            print("ERROR: No mouse devices with side buttons found!")
            print("Make sure you're in the 'input' group: sudo usermod -aG input $USER")
            sys.exit(1)

        # Find keyboard devices for Escape key
        self.keyboard_devices = self.find_keyboard_devices()

        print(f"Monitoring {len(self.mouse_devices)} mouse device(s):")
        for dev in self.mouse_devices:
            print(f"  - {dev.name}")
        print(f"\nUsing audio device: {self.get_device_name(self.selected_device_index)}")
        if GNOME_EXTENSION_AVAILABLE:
            print("Window positioning: GNOME extension (Wayland)")
        elif LAYER_SHELL_AVAILABLE:
            print("Window positioning: Layer-shell (Sway/Hyprland)")
        else:
            print("Window positioning: Fallback (may not work on Wayland)")
        if self.interim_enabled:
            print(f"Interim transcription: enabled (pause={self.pause_threshold}s, mode={self.transcription_mode})")
        else:
            print("Interim transcription: disabled")
        print(f"Press Mouse 4 (BTN_EXTRA) to record, release to transcribe")
        print(f"Press Ctrl+Mouse4 for LLM mode")
        if self.config.get("dual_daemon_enabled", False):
            print(f"Press Ctrl+Alt+Mouse4 to toggle between fast/accurate modes")
        print(f"Press Ctrl+Alt+Space to open settings")
        print(f"Press Ctrl+C to quit\n")

        # Start evdev monitoring in a thread
        self.evdev_thread = threading.Thread(target=self.monitor_mouse, daemon=True)
        self.evdev_thread.start()

    def load_config(self):
        """Load configuration from file with defaults."""
        defaults = {
            "pause_threshold": 1.5,
            "silence_amplitude": 0.02,
            "transcription_mode": "full",  # "full" or "concatenate"
            "interim_enabled": True,
            "volume_dimming_enabled": False,
            "dimmed_volume": 0.10,  # 10% volume while recording
            "volume_fade_enabled": False,  # Gradual fade to avoid pops (may not help with Bluetooth)
            "input_gain": 1.0,  # Input gain multiplier (0.5 - 4.0)
            # LLM integration settings
            "llm_enabled": True,  # Enable Ctrl+Mouse4 for LLM mode
            # Logging settings
            "logging_enabled": True,  # Enable logging to ~/.dictation_*.log files
            # Dual-daemon mode settings
            "dual_daemon_enabled": False,  # Enable fast/accurate model switching
            "transcription_model_fast": "./whisper-base-npu",
            "transcription_device_fast": "NPU",
            "transcription_model_accurate": "./whisper-small-npu",
            "transcription_device_accurate": "NPU",
            "transcription_mode_active": "fast",  # "fast" or "accurate"
        }

        if os.path.exists(CONFIG_FILE):
            try:
                with open(CONFIG_FILE, "r") as f:
                    config = json.load(f)
                    if isinstance(config, dict):
                        return {**defaults, **config}
            except:
                pass
        return defaults

    def get_active_daemon_socket(self):
        """Get the socket path for the currently active transcription daemon."""
        if not self.config.get("dual_daemon_enabled", False):
            # Single daemon mode - use legacy socket
            return DAEMON_SOCKET

        # Dual daemon mode - use appropriate socket based on active mode
        if self.transcription_mode_active == "accurate":
            return DAEMON_SOCKET_ACCURATE
        else:
            return DAEMON_SOCKET_FAST

    def toggle_transcription_mode(self):
        """Toggle between fast and accurate transcription modes."""
        if not self.config.get("dual_daemon_enabled", False):
            print("Dual-daemon mode not enabled")
            return

        # Toggle mode
        if self.transcription_mode_active == "fast":
            self.transcription_mode_active = "accurate"
            mode_text = "ACCURATE"
            print("Switched to ACCURATE mode")
        else:
            self.transcription_mode_active = "fast"
            mode_text = "FAST"
            print("Switched to FAST mode")

        # Save preference to config
        self.config["transcription_mode_active"] = self.transcription_mode_active
        self.save_config()

        # Flash mode indicator at mouse position
        GLib.idle_add(self.overlay.flash_mode_indicator, mode_text)

    def get_system_volume(self):
        """Get current system volume using wpctl (PipeWire)."""
        try:
            result = subprocess.run(
                ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"],
                capture_output=True, text=True, timeout=1
            )
            if result.returncode == 0:
                # Output format: "Volume: 0.50" or "Volume: 0.50 [MUTED]"
                parts = result.stdout.strip().split()
                if len(parts) >= 2:
                    return float(parts[1])
        except Exception as e:
            print(f"Error getting volume: {e}")
        return None

    def set_system_volume(self, level):
        """Set system volume using wpctl (PipeWire)."""
        try:
            subprocess.run(
                ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", str(level)],
                timeout=1
            )
            return True
        except Exception as e:
            print(f"Error setting volume: {e}")
            return False

    def fade_volume(self, start, end, steps=8, duration_ms=60):
        """Gradually change volume to avoid audio pops, or instant if fade disabled."""
        if not self.config.get("volume_fade_enabled", False):
            self.set_system_volume(end)
            return
        import time
        if steps < 2:
            self.set_system_volume(end)
            return
        step_delay = duration_ms / 1000.0 / steps
        for i in range(1, steps + 1):
            level = start + (end - start) * (i / steps)
            self.set_system_volume(level)
            if i < steps:
                time.sleep(step_delay)

    def dim_volume(self):
        """Dim system volume for recording (relative - multiply by dim_factor)."""
        if not self.config.get("volume_dimming_enabled", False):
            return

        current = self.get_system_volume()
        if current is not None:
            dim_factor = self.config.get("dimmed_volume", 0.10)
            dimmed = current * dim_factor
            print(f"Volume dimming: {current:.0%} -> {dimmed:.0%}")
            self.fade_volume(current, dimmed)

    def restore_volume(self):
        """Restore system volume after recording (relative - divide by dim_factor)."""
        if not self.config.get("volume_dimming_enabled", False):
            return

        current = self.get_system_volume()
        if current is not None:
            dim_factor = self.config.get("dimmed_volume", 0.10)
            restored = min(current / dim_factor, 1.0)  # Cap at 100%
            print(f"Volume restoring: {current:.0%} -> {restored:.0%}")
            self.fade_volume(current, restored)

    def get_input_devices(self):
        """Get list of input devices."""
        devices = []
        for i in range(self.audio.get_device_count()):
            info = self.audio.get_device_info_by_index(i)
            if info["maxInputChannels"] > 0:
                devices.append({"index": i, "name": info["name"]})
        return devices

    def get_device_name(self, index):
        """Get device name by index."""
        for d in self.devices:
            if d["index"] == index:
                return d["name"]
        return f"Device {index}"

    def get_default_device_index(self):
        """Get the default input device index."""
        if "device_index" in self.config:
            saved_index = int(self.config["device_index"])
            if any(d["index"] == saved_index for d in self.devices):
                return saved_index
        try:
            default_device = self.audio.get_default_input_device_info()
            return default_device["index"]
        except:
            return self.devices[0]["index"] if self.devices else 0

    def find_mouse_devices(self):
        """Find mouse devices with side buttons."""
        devices = []
        for path in list_devices():
            try:
                device = InputDevice(path)
                if 'virtual' in device.name.lower():
                    continue
                if ecodes.EV_KEY in device.capabilities():
                    keys = device.capabilities()[ecodes.EV_KEY]
                    if MOUSE_BUTTON in keys:
                        devices.append(device)
            except:
                continue
        return devices

    def find_keyboard_devices(self):
        """Find keyboard devices for Escape key monitoring."""
        devices = []
        for path in list_devices():
            try:
                device = InputDevice(path)
                if 'virtual' in device.name.lower():
                    continue
                if ecodes.EV_KEY in device.capabilities():
                    keys = device.capabilities()[ecodes.EV_KEY]
                    # Look for devices with Escape key (keyboards)
                    if ecodes.KEY_ESC in keys and ecodes.KEY_A in keys:
                        devices.append(device)
            except:
                continue
        return devices

    def monitor_mouse(self):
        """Monitor mouse and keyboard devices for button events (runs in background thread)."""
        # Combine mouse and keyboard devices
        device_map = {dev.fd: ('mouse', dev) for dev in self.mouse_devices}
        device_map.update({dev.fd: ('keyboard', dev) for dev in self.keyboard_devices})

        while self.running:
            try:
                r, _, _ = select.select(list(device_map.keys()), [], [], 0.1)

                for fd in r:
                    dev_type, device = device_map[fd]
                    for event in device.read():
                        # Handle button press/release
                        if event.type == ecodes.EV_KEY:
                            key_event = categorize(event)

                            # Side button for recording (mouse only)
                            # Ctrl+Mouse4 = LLM mode, Mouse4 alone = transcription mode
                            if dev_type == 'mouse' and event.code == MOUSE_BUTTON:
                                if key_event.keystate == key_event.key_down:
                                    # Get mouse position right when button is pressed
                                    x, y = self.get_mouse_position()
                                    # Check if Ctrl+Alt is held for mode toggle
                                    if self.ctrl_pressed and self.alt_pressed and self.config.get("dual_daemon_enabled", False):
                                        print(f"Ctrl+Alt+Mouse4 pressed - toggling transcription mode")
                                        GLib.idle_add(self.toggle_transcription_mode)
                                    # Check if Ctrl is held for LLM mode
                                    elif self.ctrl_pressed and self.config.get("llm_enabled", True):
                                        self.llm_mode = True
                                        print(f"Ctrl+Mouse4 pressed at ({x}, {y}) - LLM mode")
                                        GLib.idle_add(self.start_recording_at_mouse)
                                    else:
                                        self.llm_mode = False
                                        print(f"Mouse button pressed at ({x}, {y}) - Transcription mode")
                                        GLib.idle_add(self.start_recording_at_mouse)
                                elif key_event.keystate == key_event.key_up:
                                    if self.llm_mode:
                                        print("Mouse button released - sending to LLM")
                                        GLib.idle_add(self.stop_and_process_llm)
                                    else:
                                        print("Mouse button released - stopping recording")
                                        GLib.idle_add(self.stop_and_transcribe)

                            # Left/Right click during transcription OR confirmation mode
                            elif dev_type == 'mouse' and key_event.keystate == key_event.key_down and (self.is_transcribing or self.overlay.awaiting_confirmation):
                                if event.code == ecodes.BTN_LEFT:
                                    if self.overlay.awaiting_confirmation:
                                        # Confirmation is active - handle as confirmation click
                                        print("Left-click detected - confirming paste")
                                        GLib.idle_add(lambda: self.overlay.handle_click(True))
                                    else:
                                        # Still transcribing - set early click flag
                                        print("Early left-click detected during transcription")
                                        self.early_left_click = True
                                elif event.code == ecodes.BTN_RIGHT:
                                    if self.overlay.awaiting_confirmation:
                                        print("Right-click detected - canceling")
                                        GLib.idle_add(lambda: self.overlay.handle_click(False))
                                    else:
                                        print("Early right-click detected during transcription")
                                        self.early_right_click = True

                            # Fallback: Left/Right click during confirmation mode only (shouldn't reach here)
                            elif dev_type == 'mouse' and self.overlay.awaiting_confirmation and key_event.keystate == key_event.key_down:
                                if event.code == ecodes.BTN_LEFT:
                                    print("Left-click detected - confirming paste")
                                    GLib.idle_add(lambda: self.overlay.handle_click(True))
                                elif event.code == ecodes.BTN_RIGHT:
                                    print("Right-click detected - canceling")
                                    GLib.idle_add(lambda: self.overlay.handle_click(False))

                            # Track modifier keys for hotkeys (always track, not an elif)
                            if dev_type == 'keyboard':
                                if event.code in (ecodes.KEY_LEFTCTRL, ecodes.KEY_RIGHTCTRL):
                                    self.ctrl_pressed = key_event.keystate in (key_event.key_down, key_event.key_hold)
                                elif event.code in (ecodes.KEY_LEFTALT, ecodes.KEY_RIGHTALT):
                                    self.alt_pressed = key_event.keystate in (key_event.key_down, key_event.key_hold)
                                elif event.code in (ecodes.KEY_LEFTSHIFT, ecodes.KEY_RIGHTSHIFT):
                                    self.shift_pressed = key_event.keystate in (key_event.key_down, key_event.key_hold)
                                elif event.code == ecodes.KEY_SPACE and key_event.keystate == key_event.key_down:
                                    if self.ctrl_pressed and self.alt_pressed:
                                        print("Ctrl+Alt+Space pressed - opening settings")
                                        GLib.idle_add(self.show_settings_dialog)

                                # Ctrl+Alt+[0-9] for register management
                                elif key_event.keystate == key_event.key_down and self.ctrl_pressed and self.alt_pressed:
                                    # Ctrl+Alt+0 clears all registers
                                    if event.code == ecodes.KEY_0:
                                        GLib.idle_add(self.clear_all_registers)
                                    else:
                                        # Ctrl+Alt+[1-9] captures clipboard to register
                                        key_to_register = {
                                            ecodes.KEY_1: 1, ecodes.KEY_2: 2, ecodes.KEY_3: 3,
                                            ecodes.KEY_4: 4, ecodes.KEY_5: 5, ecodes.KEY_6: 6,
                                            ecodes.KEY_7: 7, ecodes.KEY_8: 8, ecodes.KEY_9: 9,
                                        }
                                        if event.code in key_to_register:
                                            reg_num = key_to_register[event.code]
                                            GLib.idle_add(self.capture_to_register, reg_num)

                            # Escape key during transcription (early cancel)
                            if dev_type == 'keyboard' and self.is_transcribing and key_event.keystate == key_event.key_down:
                                if event.code == ecodes.KEY_ESC:
                                    print("Early escape detected during transcription")
                                    self.early_right_click = True

                            # Escape key during confirmation mode (keyboard only)
                            elif dev_type == 'keyboard' and self.overlay.awaiting_confirmation and key_event.keystate == key_event.key_down:
                                if event.code == ecodes.KEY_ESC:
                                    print("Escape pressed - canceling")
                                    GLib.idle_add(lambda: self.overlay.handle_click(False))
            except Exception as e:
                if self.running:
                    print(f"Error in input monitoring: {e}")

    def get_mouse_position(self):
        """Get current mouse position."""
        # Try GNOME extension first (works on Wayland/GNOME)
        if GNOME_EXTENSION_AVAILABLE and extension_get_mouse_position:
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

        # Fallback to stored position
        return self.mouse_x, self.mouse_y

    def start_recording_at_mouse(self):
        """Start recording and show overlay at mouse position."""
        if self.is_recording:
            return

        # Get mouse position
        x, y = self.get_mouse_position()

        # Show overlay
        self.overlay.show(x, y)

        # If LLM mode, show register indicators
        if self.llm_mode:
            has_clipboard = self.check_clipboard_has_content()
            filled_registers = set(self.registers.keys())
            self.overlay.show_llm_recording(has_clipboard, filled_registers)

        # Start recording
        self.start_recording()

    def check_clipboard_has_content(self):
        """Check if the primary clipboard has content."""
        try:
            result = subprocess.run(
                ["wl-paste", "-n"],
                capture_output=True,
                text=True,
                timeout=0.5
            )
            return result.returncode == 0 and bool(result.stdout.strip())
        except:
            return False

    def start_recording(self):
        """Start audio recording."""
        self.is_recording = True
        self.frames = []

        # Dim system volume if enabled
        self.dim_volume()

        # Reset early click detection
        self.early_left_click = False
        self.early_right_click = False
        self.is_transcribing = False

        # Reset interim transcription state
        self.interim_transcriptions = []
        self.interim_pending = False
        self.last_interim_frame = 0

        device_index = self.selected_device_index

        try:
            if self.audio.is_format_supported(
                self.RATE,
                input_device=device_index,
                input_channels=self.CHANNELS,
                input_format=self.FORMAT
            ):
                sample_rate = self.RATE
            else:
                device_info = self.audio.get_device_info_by_index(device_index)
                sample_rate = int(device_info['defaultSampleRate'])
        except:
            sample_rate = self.RATE

        self.actual_rate = sample_rate

        try:
            self.stream = self.audio.open(
                format=self.FORMAT,
                channels=self.CHANNELS,
                rate=sample_rate,
                input=True,
                input_device_index=device_index,
                frames_per_buffer=self.CHUNK,
            )
        except Exception as e:
            print(f"Error opening audio stream: {e}")
            self.is_recording = False
            self.restore_volume()  # Restore volume on error
            self.overlay.hide()
            return

        # Start recording thread
        self.record_thread = threading.Thread(target=self.record_audio, daemon=True)
        self.record_thread.start()

        # Start waveform updates
        GLib.timeout_add(50, self.update_waveform)

    def apply_gain(self, data):
        """Apply input gain to audio data."""
        gain = self.config.get("input_gain", 1.0)
        if gain == 1.0:
            return data
        # Convert to numpy, apply gain, clip, convert back
        samples = np.frombuffer(data, dtype=np.int16).astype(np.float32)
        samples *= gain
        samples = np.clip(samples, -32768, 32767).astype(np.int16)
        return samples.tobytes()

    def record_audio(self):
        """Record audio in background thread with pause detection."""
        consecutive_silent_chunks = 0
        last_speech_frame = 0  # Track where speech ended
        MIN_FRAMES_BEFORE_INTERIM = int(0.5 * self.RATE / self.CHUNK)  # 0.5s minimum

        while self.is_recording and self.stream:
            try:
                data = self.stream.read(self.CHUNK, exception_on_overflow=False)
                data = self.apply_gain(data)  # Apply input gain
                self.frames.append(data)

                # Pause detection for interim transcription
                if self.interim_enabled:
                    amplitude = self._calculate_chunk_amplitude(data)

                    if amplitude < self.silence_amplitude:
                        consecutive_silent_chunks += 1

                        # Check if we've hit the pause threshold
                        if (consecutive_silent_chunks >= self.pause_chunks_threshold
                            and not self.interim_pending
                            and last_speech_frame > self.last_interim_frame
                            and last_speech_frame >= MIN_FRAMES_BEFORE_INTERIM):
                            # Trigger interim transcription up to where speech ended (exclude silence)
                            self._trigger_interim_transcription(last_speech_frame)
                    else:
                        consecutive_silent_chunks = 0
                        last_speech_frame = len(self.frames)  # Update speech end marker

            except Exception as e:
                if self.is_recording:
                    print(f"Recording error: {e}")
                break

        # Clean up stream in this thread
        if self.stream:
            try:
                self.stream.stop_stream()
                self.stream.close()
            except:
                pass
            self.stream = None

    def _calculate_chunk_amplitude(self, data):
        """Calculate RMS amplitude for a single audio chunk."""
        samples = np.frombuffer(data, dtype=np.int16)
        if len(samples) == 0:
            return 0.0
        rms = np.sqrt(np.mean(samples.astype(np.float64) ** 2))
        return rms / 32768.0  # Normalize to 0-1

    def _trigger_interim_transcription(self, end_frame=None):
        """Trigger async transcription of audio recorded so far."""
        if self.interim_pending or not self.frames:
            return

        self.interim_pending = True

        # Use provided end_frame (where speech ended) or current length
        frame_end_index = end_frame if end_frame else len(self.frames)
        frames_to_transcribe = self.frames[self.last_interim_frame:frame_end_index]

        print(f"[Interim] Triggered: frames {self.last_interim_frame}-{frame_end_index} ({len(frames_to_transcribe)} frames)")

        # Launch transcription in separate thread
        threading.Thread(
            target=self._perform_interim_transcription,
            args=(frames_to_transcribe, frame_end_index),
            daemon=True
        ).start()

    def _perform_interim_transcription(self, frames, end_index):
        """Perform interim transcription asynchronously."""
        try:
            # Send to daemon (in-RAM, no disk I/O)
            result = self.send_to_daemon(frames, self.actual_rate)

            if result.get("success"):
                transcription = result.get("transcription", "").strip()

                # Filter Whisper hallucinations (common on silence)
                hallucinations = [
                    "thanks for watching",
                    "thank you for watching",
                    "please subscribe",
                    "like and subscribe",
                    "see you next time",
                    "bye",
                    "[music]",
                    "(music)",
                    "you",
                ]
                if transcription.lower() in hallucinations:
                    print(f"[Interim] Filtered hallucination: {transcription}")
                    transcription = ""

                if transcription and len(transcription) >= 2:
                    self.interim_transcriptions.append(transcription)
                    self.last_interim_frame = end_index

                    # Update UI (must use GLib.idle_add from background thread)
                    interim_text = " ".join(self.interim_transcriptions)
                    GLib.idle_add(self.overlay.set_interim_text, interim_text)
                    print(f"[Interim] Result: {transcription}")

        except Exception as e:
            print(f"[Interim] Error: {e}")
        finally:
            self.interim_pending = False

    def update_waveform(self):
        """Update waveform visualization."""
        if not self.is_recording:
            return False

        if self.frames:
            # Send latest audio chunk to overlay
            self.overlay.update_waveform(self.frames[-1])

        return self.is_recording  # Continue if still recording

    def stop_and_transcribe(self):
        """Stop recording and transcribe."""
        if not self.is_recording:
            return

        self.is_recording = False

        # Wait for recording thread
        if self.record_thread and self.record_thread.is_alive():
            self.record_thread.join(timeout=1.0)

        # Restore system volume if it was dimmed
        self.restore_volume()

        # Wait for any pending interim transcription (with timeout)
        import time
        wait_start = time.time()
        while self.interim_pending and (time.time() - wait_start) < 2.0:
            time.sleep(0.1)

        # Check if we have enough audio
        if len(self.frames) < 10:
            print(f"Too short ({len(self.frames)} frames), skipping")
            self.overlay.hide()
            return

        # Update status and start transcription phase
        self.overlay.set_status("transcribing")
        self.is_transcribing = True

        # Transcribe in background
        threading.Thread(target=self.save_and_transcribe, daemon=True).start()

    def calculate_audio_rms(self):
        """Calculate RMS (root mean square) amplitude of recorded audio."""
        if not self.frames:
            return 0.0

        # Combine all frames and convert to numpy array
        audio_data = b"".join(self.frames)
        samples = np.frombuffer(audio_data, dtype=np.int16)

        if len(samples) == 0:
            return 0.0

        # Calculate RMS
        rms = np.sqrt(np.mean(samples.astype(np.float64) ** 2))
        # Normalize to 0-1 range (16-bit audio max is 32768)
        return rms / 32768.0

    def save_and_transcribe(self):
        """Save audio and send to transcription daemon."""
        import time

        try:
            # Check audio level - reject if too quiet (likely silence/noise)
            rms = self.calculate_audio_rms()
            silence_threshold = 0.01

            if rms < silence_threshold:
                print(f"Audio too quiet (RMS={rms:.4f}), skipping transcription")
                self.is_transcribing = False
                GLib.idle_add(self.overlay.hide)
                return

            final_transcription = ""

            if self.transcription_mode == "concatenate" and self.interim_transcriptions:
                # Concatenate mode: only transcribe remaining audio, append to interim
                remaining_frames = self.frames[self.last_interim_frame:]

                if remaining_frames:
                    print(f"[Concatenate] Transcribing {len(remaining_frames)} remaining frames")
                    result = self.send_to_daemon(remaining_frames, self.actual_rate)

                    if result.get("success"):
                        remaining_text = result.get("transcription", "").strip()
                        if remaining_text and len(remaining_text) >= 2:
                            self.interim_transcriptions.append(remaining_text)

                # Combine all interim transcriptions
                final_transcription = " ".join(self.interim_transcriptions)
                print(f"[Concatenate] Final: {final_transcription}")

            else:
                # Full mode (default): transcribe entire recording
                print(f"[Full] Transcribing {len(self.frames)} frames (RMS={rms:.4f})")
                result = self.send_to_daemon(self.frames, self.actual_rate)

                if result.get("success"):
                    final_transcription = result.get("transcription", "").strip()

            # Reset interim state
            self.interim_transcriptions = []
            self.last_interim_frame = 0

            # Filter if too short (likely noise)
            if len(final_transcription) < 2:
                print(f"Filtered: too short ({len(final_transcription)} chars)")
                final_transcription = ""

            if final_transcription:
                print(f"Transcription: {final_transcription}")

                # Check for early click detection
                if self.early_right_click:
                    print("Early cancel detected - skipping paste")
                    self.is_transcribing = False
                    self.early_right_click = False
                    self.early_left_click = False
                    GLib.idle_add(self.overlay.hide)
                elif self.early_left_click:
                    print("Early confirm detected - pasting immediately")
                    self.is_transcribing = False
                    self.early_right_click = False
                    self.early_left_click = False
                    self.pending_transcription = final_transcription
                    self.prepare_clipboard_for_confirmation(final_transcription)
                    GLib.idle_add(self.overlay.hide)
                    time.sleep(0.1)
                    self._do_paste()
                else:
                    # No early click - show confirmation dialog
                    # Keep is_transcribing=True until awaiting_confirmation is set
                    self.pending_transcription = final_transcription
                    self.prepare_clipboard_for_confirmation(final_transcription)
                    GLib.idle_add(
                        self.overlay.show_confirmation,
                        final_transcription,
                        self.on_confirm_paste,
                        self.on_cancel_paste
                    )
            else:
                print("No transcription")
                self.is_transcribing = False
                GLib.idle_add(self.overlay.hide)

        except Exception as e:
            print(f"Error in transcription: {e}")
            self.is_transcribing = False
            GLib.idle_add(self.overlay.hide)

    def send_to_daemon(self, audio_frames, sample_rate):
        """Send transcription request to daemon (in-RAM, no disk I/O)."""
        try:
            # Combine all frames into single bytes object
            audio_data = b"".join(audio_frames)

            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(30)
            client.connect(self.get_active_daemon_socket())

            # Send JSON header with metadata
            request = {
                "command": "transcribe_raw",
                "sample_rate": sample_rate,
                "data_length": len(audio_data)
            }
            client.sendall((json.dumps(request) + "\n").encode())

            # Send raw audio data
            client.sendall(audio_data)

            # Receive response
            response_data = b""
            while True:
                chunk = client.recv(4096)
                if not chunk:
                    break
                response_data += chunk
                if b"\n" in chunk:
                    break

            client.close()
            return json.loads(response_data.decode())

        except FileNotFoundError:
            return {"success": False, "error": "Transcription daemon not running"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def capture_to_register(self, reg_num):
        """Copy current selection directly to a numbered register (without affecting clipboard)."""
        try:
            # Try primary selection first (automatically set when text is selected on Wayland)
            result = subprocess.run(
                ["wl-paste", "--primary", "-n"],
                capture_output=True,
                text=True,
                timeout=1
            )

            if result.returncode == 0 and result.stdout.strip():
                self.registers[reg_num] = result.stdout.strip()
                preview = self.registers[reg_num][:50].replace('\n', ' ')
                print(f"[Register {reg_num}] Captured selection: {preview}...")
                return

            # Fallback: try regular clipboard
            result = subprocess.run(
                ["wl-paste", "-n"],
                capture_output=True,
                text=True,
                timeout=1
            )

            if result.returncode == 0 and result.stdout.strip():
                self.registers[reg_num] = result.stdout.strip()
                preview = self.registers[reg_num][:50].replace('\n', ' ')
                print(f"[Register {reg_num}] Captured from clipboard: {preview}...")
            else:
                print(f"[Register {reg_num}] No selection or clipboard content")

        except Exception as e:
            print(f"[Register {reg_num}] Error capturing: {e}")

    def clear_all_registers(self):
        """Clear all clipboard registers."""
        count = len(self.registers)
        self.registers = {}
        print(f"[Registers] Cleared all ({count} registers)")

    def build_register_context(self):
        """Build context from all registers and primary clipboard.

        Returns context string with all stored registers plus primary clipboard.
        All registers are automatically included - no hotword detection needed.
        """
        context_parts = []

        # Include primary clipboard first
        try:
            result = subprocess.run(
                ["wl-paste", "-n"],
                capture_output=True,
                text=True,
                timeout=1
            )
            if result.returncode == 0 and result.stdout.strip():
                context_parts.append(f"[Current Clipboard]:\n{result.stdout.strip()}")
                print(f"[LLM] Including primary clipboard")
        except Exception as e:
            print(f"[LLM] Error getting primary clipboard: {e}")

        # Include all stored registers
        for reg_num in sorted(self.registers.keys()):
            content = self.registers[reg_num]
            if content:
                context_parts.append(f"[Register {reg_num}]:\n{content}")
                print(f"[LLM] Including register {reg_num}")

        # Combine context
        context = '\n\n'.join(context_parts) if context_parts else ""

        return context

    def stop_and_process_llm(self):
        """Stop recording and process through LLM (Ctrl+Mouse4 flow)."""
        if not self.is_recording:
            return

        self.is_recording = False

        # Wait for recording thread
        if self.record_thread and self.record_thread.is_alive():
            self.record_thread.join(timeout=1.0)

        # Restore system volume if it was dimmed
        self.restore_volume()

        # Check if we have enough audio
        if len(self.frames) < 10:
            print(f"Too short ({len(self.frames)} frames), skipping")
            self.overlay.hide()
            return

        # Update status
        self.overlay.set_status("transcribing")
        self.is_transcribing = True

        # Process in background
        threading.Thread(target=self._process_llm_prompt, daemon=True).start()

    def _process_llm_prompt(self):
        """Transcribe audio and send to LLM (runs in background thread)."""
        import time

        try:
            # Check audio level
            rms = self.calculate_audio_rms()
            silence_threshold = 0.01

            if rms < silence_threshold:
                print(f"Audio too quiet (RMS={rms:.4f}), skipping")
                self.is_transcribing = False
                GLib.idle_add(self.overlay.hide)
                return

            # Transcribe audio (in-RAM, no disk I/O)
            print(f"[LLM] Transcribing {len(self.frames)} frames...")
            result = self.send_to_daemon(self.frames, self.actual_rate)

            if not result.get("success"):
                print(f"[LLM] Transcription failed: {result.get('error')}")
                self.is_transcribing = False
                GLib.idle_add(self.overlay.hide)
                return

            spoken_prompt = result.get("transcription", "").strip()
            print(f"[LLM] Spoken prompt: {spoken_prompt}")

            if len(spoken_prompt) < 2:
                print("[LLM] Prompt too short, skipping")
                self.is_transcribing = False
                GLib.idle_add(self.overlay.hide)
                return

            # Check for early cancel
            if self.early_right_click:
                print("[LLM] Early cancel detected")
                self.is_transcribing = False
                self.early_right_click = False
                self.early_left_click = False
                GLib.idle_add(self.overlay.hide)
                return

            # Build context from all registers and primary clipboard
            context = self.build_register_context()

            print(f"[LLM] Prompt: {spoken_prompt}")
            if context:
                print(f"[LLM] Context length: {len(context)} chars")

            # Send to LLM daemon with streaming, show original spoken prompt
            llm_response = self.send_to_llm_daemon_streaming(spoken_prompt, context, display_prompt=spoken_prompt)

            # Check if cancelled during streaming
            if llm_response is None:
                print("[LLM] Cancelled during streaming")
                self.is_transcribing = False
                self.early_right_click = False
                self.early_left_click = False
                GLib.idle_add(self.overlay.hide)
                return

            print(f"[LLM] Response: {llm_response[:100]}...")

            # Check for early cancel again
            if self.early_right_click:
                print("[LLM] Early cancel detected after LLM")
                self.is_transcribing = False
                self.early_right_click = False
                self.early_left_click = False
                GLib.idle_add(self.overlay.hide)
                return

            # Handle early confirm
            if self.early_left_click:
                print("[LLM] Early confirm detected - pasting immediately")
                self.is_transcribing = False
                self.early_right_click = False
                self.early_left_click = False
                self.pending_transcription = llm_response
                self.prepare_clipboard_for_confirmation(llm_response)
                GLib.idle_add(self.overlay.hide)
                time.sleep(0.1)
                self._do_paste()
            else:
                # Show confirmation with LLM response
                self.pending_transcription = llm_response
                self.prepare_clipboard_for_confirmation(llm_response)
                GLib.idle_add(
                    self.overlay.show_confirmation,
                    llm_response,
                    self.on_confirm_paste,
                    self.on_cancel_paste
                )

        except Exception as e:
            print(f"[LLM] Error: {e}")
            self.is_transcribing = False
            GLib.idle_add(self.overlay.hide)

    def send_to_llm_daemon(self, prompt, context=""):
        """Send prompt to LLM daemon, return response."""
        try:
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(180)  # LLM can take longer (especially cold start)
            client.connect(LLM_DAEMON_SOCKET)

            request = {
                "command": "generate",
                "prompt": prompt,
                "context": context,
            }
            client.sendall((json.dumps(request) + "\n").encode())

            response_data = b""
            while True:
                chunk = client.recv(4096)
                if not chunk:
                    break
                response_data += chunk
                if b"\n" in chunk:
                    break

            client.close()
            result = json.loads(response_data.decode())

            if result.get("success"):
                return result.get("response", "")
            else:
                error = result.get("error", "Unknown error")
                print(f"[LLM] Error: {error}")
                return f"[LLM Error: {error}]"

        except FileNotFoundError:
            print("[LLM] Daemon not running")
            return "[LLM daemon not running. Start it with: ./daemon_control.sh start]"
        except socket.timeout:
            print("[LLM] Request timed out")
            return "[LLM request timed out]"
        except Exception as e:
            print(f"[LLM] Connection error: {e}")
            return f"[LLM connection error: {e}]"

    def send_to_llm_daemon_streaming(self, prompt, context="", display_prompt=""):
        """Send prompt to LLM daemon with streaming, updating overlay as tokens arrive."""
        try:
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(180)
            client.connect(LLM_DAEMON_SOCKET)

            request = {
                "command": "generate_stream",
                "prompt": prompt,
                "context": context,
            }
            client.sendall((json.dumps(request) + "\n").encode())

            # Initialize streaming display with the spoken prompt
            GLib.idle_add(self.overlay.start_streaming, display_prompt or prompt)

            # Set short timeout for cancellation checking
            client.settimeout(0.1)

            full_response = ""
            buffer = ""

            while True:
                # Check for cancel request (right-click)
                if self.early_right_click:
                    print("[LLM] Streaming cancelled by user")
                    client.close()
                    self.early_right_click = False
                    return None  # Signal cancellation

                try:
                    chunk = client.recv(4096)
                    if not chunk:
                        break
                except socket.timeout:
                    continue  # No data yet, loop back to check cancellation

                buffer += chunk.decode()

                # Process complete JSON lines
                while "\n" in buffer:
                    line, buffer = buffer.split("\n", 1)
                    if not line.strip():
                        continue

                    try:
                        data = json.loads(line)

                        if "token" in data:
                            token = data["token"]
                            full_response += token
                            # Update overlay with new token
                            GLib.idle_add(self.overlay.append_streaming_token, token)

                        elif "done" in data:
                            full_response = data.get("full_response", full_response.strip())
                            client.close()
                            return full_response

                        elif "error" in data:
                            error = data["error"]
                            print(f"[LLM] Stream error: {error}")
                            client.close()
                            return f"[LLM Error: {error}]"

                    except json.JSONDecodeError:
                        continue

            client.close()
            return full_response.strip() if full_response else "[LLM: No response]"

        except FileNotFoundError:
            print("[LLM] Daemon not running")
            return "[LLM daemon not running. Start it with: ./daemon_control.sh start]"
        except socket.timeout:
            print("[LLM] Request timed out")
            return "[LLM request timed out]"
        except Exception as e:
            print(f"[LLM] Connection error: {e}")
            return f"[LLM connection error: {e}]"

    def prepare_clipboard_for_confirmation(self, text):
        """Save current clipboard. Don't set transcription yet - do that only when pasting."""
        # Save current clipboard so we can restore it after paste
        try:
            result = subprocess.run(["wl-paste", "-n"], capture_output=True, timeout=0.5)
            if result.returncode == 0 and result.stdout:
                self.old_clipboard = result.stdout
                print(f"[DEBUG] Saved clipboard: {len(self.old_clipboard)} bytes")
            else:
                self.old_clipboard = None
                print(f"[DEBUG] No clipboard to save (returncode={result.returncode})")
        except subprocess.TimeoutExpired:
            print(f"[DEBUG] wl-paste timed out - skipping clipboard save")
            self.old_clipboard = None
        except Exception as e:
            print(f"[DEBUG] Error saving clipboard: {e}")
            self.old_clipboard = None
        # NOTE: We no longer set the clipboard here - it's set in _do_paste right before pasting
        # This means canceling doesn't need to restore anything

    def on_confirm_paste(self):
        """Handle user confirmation to paste the transcription."""
        self.is_transcribing = False
        # Hide overlay first
        self.overlay.hide()

        # Run paste operation in background thread (don't block GTK main thread)
        threading.Thread(target=self._do_paste, daemon=True).start()

    def _do_paste(self):
        """Perform the actual paste operation (runs in background thread)."""
        import time
        env = os.environ.copy()
        env['YDOTOOL_SOCKET'] = '/tmp/.ydotool_socket'

        # Debug: check what we have saved
        if self.old_clipboard is not None:
            print(f"[DEBUG] _do_paste: old_clipboard = {len(self.old_clipboard)} bytes")
        else:
            print(f"[DEBUG] _do_paste: old_clipboard = None")

        try:
            # Delay to let window/focus events settle (terminals need more time)
            time.sleep(0.15)

            # Set clipboard to transcription right before pasting
            text = self.pending_transcription
            if text:
                try:
                    subprocess.run(["wl-copy", "--", text], check=True, timeout=0.5)
                    subprocess.run(["wl-copy", "--primary", "--", text], timeout=0.5)
                    print("[DEBUG] Set clipboard to transcription")
                    time.sleep(0.05)
                except subprocess.TimeoutExpired:
                    print("[DEBUG] wl-copy timed out - trying paste anyway")
                except Exception as e:
                    print(f"[DEBUG] Error setting clipboard: {e}")

            # Paste with Shift+Insert
            subprocess.run(["ydotool", "key", "shift+insert"], env=env, check=True, timeout=5)

            print(f"Pasted: {self.pending_transcription}")

            # Restore clipboard immediately (minimal delay for paste to complete)
            time.sleep(0.05)
            if self.old_clipboard is not None and len(self.old_clipboard) > 0:
                try:
                    print(f"[DEBUG] Restoring clipboard: {len(self.old_clipboard)} bytes")
                    # Decode bytes to string and pass as argument (stdin times out)
                    text = self.old_clipboard.decode('utf-8', errors='replace')
                    subprocess.run(["wl-copy", "--", text], timeout=0.5)
                    print("[DEBUG] Clipboard restored")
                except subprocess.TimeoutExpired:
                    print("[DEBUG] wl-copy timed out during restore")
                except Exception as e:
                    print(f"[DEBUG] Failed to restore clipboard: {e}")
            else:
                # Clear clipboard if there was nothing before
                try:
                    subprocess.run(["wl-copy", "--clear"], timeout=2)
                    print("[DEBUG] Clipboard cleared")
                except:
                    pass

        except Exception as e:
            print(f"Paste error: {e}")
        finally:
            self.old_clipboard = None
            self.pending_transcription = None

    def on_cancel_paste(self):
        """Handle user cancellation - clipboard was never changed, so just clean up."""
        self.is_transcribing = False
        print("Cancelled - clipboard unchanged")
        self.old_clipboard = None
        self.pending_transcription = None
        self.overlay.hide()

    def show_settings_dialog(self):
        """Show the settings dialog."""
        # Don't open if already open or recording
        if self.settings_dialog and self.settings_dialog.get_visible():
            self.settings_dialog.present()
            return
        if self.is_recording:
            print("Cannot open settings while recording")
            return

        # Create dialog window
        dialog = Gtk.Window(title="Dictation Settings")
        dialog.set_default_size(520, 820)
        dialog.set_modal(False)
        dialog.set_resizable(True)
        self.settings_dialog = dialog

        # Scrolled window for content
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scrolled.set_vexpand(True)

        # Main container with padding
        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        main_box.set_margin_top(20)
        main_box.set_margin_bottom(20)
        main_box.set_margin_start(20)
        main_box.set_margin_end(20)

        # --- Input Device Section ---
        device_label = Gtk.Label(label="Input Device")
        device_label.set_halign(Gtk.Align.START)
        device_label.add_css_class("heading")
        main_box.append(device_label)

        # Create device dropdown
        device_strings = Gtk.StringList()
        selected_idx = 0
        for i, dev in enumerate(self.devices):
            device_strings.append(f"{dev['name']}")
            if dev['index'] == self.selected_device_index:
                selected_idx = i

        device_dropdown = Gtk.DropDown(model=device_strings)
        device_dropdown.set_selected(selected_idx)

        # Device dropdown row with refresh button
        device_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        device_dropdown.set_hexpand(True)
        device_row.append(device_dropdown)

        refresh_btn = Gtk.Button()
        refresh_btn.set_icon_name("view-refresh-symbolic")
        refresh_btn.set_tooltip_text("Refresh device list")

        def on_refresh(btn):
            # Re-enumerate devices
            self.devices = self.get_input_devices()
            # Rebuild the string list
            new_strings = Gtk.StringList()
            new_selected = 0
            for i, dev in enumerate(self.devices):
                new_strings.append(f"{dev['name']}")
                if dev['index'] == self.selected_device_index:
                    new_selected = i
            device_dropdown.set_model(new_strings)
            device_dropdown.set_selected(new_selected)
            print(f"Refreshed devices: {len(self.devices)} found")

        refresh_btn.connect("clicked", on_refresh)
        device_row.append(refresh_btn)

        main_box.append(device_row)

        # --- Input Gain Section ---
        gain_label = Gtk.Label(label="Input Gain")
        gain_label.set_halign(Gtk.Align.START)
        gain_label.add_css_class("heading")
        gain_label.set_margin_top(12)
        main_box.append(gain_label)

        gain_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        gain_adj = Gtk.Adjustment(
            value=self.config.get("input_gain", 1.0),
            lower=0.5,
            upper=4.0,
            step_increment=0.1,
            page_increment=0.5
        )
        gain_scale = Gtk.Scale(orientation=Gtk.Orientation.HORIZONTAL, adjustment=gain_adj)
        gain_scale.set_hexpand(True)
        gain_scale.set_digits(1)
        gain_scale.add_mark(1.0, Gtk.PositionType.BOTTOM, "1.0x")
        gain_scale.add_mark(2.0, Gtk.PositionType.BOTTOM, "2.0x")
        gain_scale.add_mark(3.0, Gtk.PositionType.BOTTOM, "3.0x")
        gain_box.append(gain_scale)

        gain_value_label = Gtk.Label(label=f"{gain_adj.get_value():.1f}x")
        gain_value_label.set_size_request(45, -1)
        gain_box.append(gain_value_label)

        def on_gain_changed(adj):
            gain_value_label.set_label(f"{adj.get_value():.1f}x")
        gain_adj.connect("value-changed", on_gain_changed)

        main_box.append(gain_box)

        # --- Transcription Model Section ---
        transcription_header = Gtk.Label(label="Transcription Model")
        transcription_header.set_halign(Gtk.Align.START)
        transcription_header.add_css_class("heading")
        transcription_header.set_margin_top(12)
        main_box.append(transcription_header)

        # Model path dropdown - scan for whisper model directories
        trans_model_label = Gtk.Label(label="Model")
        trans_model_label.set_halign(Gtk.Align.START)
        trans_model_label.set_margin_top(8)
        main_box.append(trans_model_label)

        # Find available Whisper models (directories containing model files)
        script_dir = os.path.dirname(os.path.abspath(__file__))
        current_trans_model_path = self.config.get("model_path", "./whisper-base-cpu")
        available_trans_models = []

        # Search in script directory for whisper-* directories
        for item in sorted(os.listdir(script_dir)):
            item_path = os.path.join(script_dir, item)
            if os.path.isdir(item_path) and item.startswith("whisper-"):
                available_trans_models.append(item_path)

        # Ensure current model is in list if it exists
        if current_trans_model_path:
            abs_current = os.path.abspath(current_trans_model_path)
            if os.path.exists(abs_current) and abs_current not in available_trans_models:
                available_trans_models.insert(0, abs_current)

        trans_model_strings = Gtk.StringList()
        trans_model_selected_idx = 0
        if not available_trans_models:
            trans_model_strings.append("No models found")
        else:
            for i, model_path in enumerate(available_trans_models):
                model_name = os.path.basename(model_path)
                trans_model_strings.append(model_name)
                if os.path.abspath(model_path) == os.path.abspath(current_trans_model_path):
                    trans_model_selected_idx = i

        trans_model_dropdown = Gtk.DropDown(model=trans_model_strings)
        trans_model_dropdown.set_selected(trans_model_selected_idx)
        trans_model_dropdown.set_hexpand(True)
        main_box.append(trans_model_dropdown)

        # Store available models for save handler
        dialog._available_trans_models = available_trans_models

        # Device selection for transcription
        trans_device_label = Gtk.Label(label="Device")
        trans_device_label.set_halign(Gtk.Align.START)
        trans_device_label.set_margin_top(8)
        main_box.append(trans_device_label)

        trans_device_strings = Gtk.StringList()
        trans_devices = ["CPU", "GPU", "NPU"]
        current_trans_device = self.config.get("transcription_device", "CPU")
        trans_device_selected_idx = 0
        for i, device in enumerate(trans_devices):
            trans_device_strings.append(device)
            if device == current_trans_device:
                trans_device_selected_idx = i

        trans_device_dropdown = Gtk.DropDown(model=trans_device_strings)
        trans_device_dropdown.set_selected(trans_device_selected_idx)
        trans_device_dropdown.set_hexpand(True)
        main_box.append(trans_device_dropdown)

        dialog._trans_devices = trans_devices

        # Preload model checkbox
        preload_check = Gtk.CheckButton(label="Preload model at startup (reduces first transcription delay)")
        preload_check.set_active(self.config.get("preload_transcription_model", False))
        preload_check.set_margin_top(8)
        main_box.append(preload_check)

        # --- Dual-Daemon Mode Section ---
        dual_daemon_header = Gtk.Label(label="Dual-Daemon Mode (Fast/Accurate Toggle)")
        dual_daemon_header.set_halign(Gtk.Align.START)
        dual_daemon_header.add_css_class("heading")
        dual_daemon_header.set_margin_top(12)
        main_box.append(dual_daemon_header)

        # Enable dual-daemon mode checkbox
        dual_daemon_check = Gtk.CheckButton(label="Enable dual-daemon mode (Ctrl+Alt+Mouse4 to toggle)")
        dual_daemon_check.set_active(self.config.get("dual_daemon_enabled", False))
        main_box.append(dual_daemon_check)

        # Fast mode configuration
        fast_model_label = Gtk.Label(label="Fast Model")
        fast_model_label.set_halign(Gtk.Align.START)
        fast_model_label.set_margin_top(8)
        main_box.append(fast_model_label)

        current_fast_model_path = self.config.get("transcription_model_fast", "./whisper-base-npu")
        fast_model_strings = Gtk.StringList()
        fast_model_selected_idx = 0
        if not available_trans_models:
            fast_model_strings.append("No models found")
        else:
            for i, model_path in enumerate(available_trans_models):
                model_name = os.path.basename(model_path)
                fast_model_strings.append(model_name)
                if os.path.abspath(model_path) == os.path.abspath(current_fast_model_path):
                    fast_model_selected_idx = i

        fast_model_dropdown = Gtk.DropDown(model=fast_model_strings)
        fast_model_dropdown.set_selected(fast_model_selected_idx)
        fast_model_dropdown.set_hexpand(True)
        main_box.append(fast_model_dropdown)

        fast_device_label = Gtk.Label(label="Fast Device")
        fast_device_label.set_halign(Gtk.Align.START)
        fast_device_label.set_margin_top(4)
        main_box.append(fast_device_label)

        fast_device_strings = Gtk.StringList()
        for device in trans_devices:
            fast_device_strings.append(device)
        current_fast_device = self.config.get("transcription_device_fast", "NPU")
        fast_device_selected_idx = 0
        for i, device in enumerate(trans_devices):
            if device == current_fast_device:
                fast_device_selected_idx = i

        fast_device_dropdown = Gtk.DropDown(model=fast_device_strings)
        fast_device_dropdown.set_selected(fast_device_selected_idx)
        fast_device_dropdown.set_hexpand(True)
        main_box.append(fast_device_dropdown)

        # Accurate mode configuration
        accurate_model_label = Gtk.Label(label="Accurate Model")
        accurate_model_label.set_halign(Gtk.Align.START)
        accurate_model_label.set_margin_top(8)
        main_box.append(accurate_model_label)

        current_accurate_model_path = self.config.get("transcription_model_accurate", "./whisper-small-npu")
        accurate_model_strings = Gtk.StringList()
        accurate_model_selected_idx = 0
        if not available_trans_models:
            accurate_model_strings.append("No models found")
        else:
            for i, model_path in enumerate(available_trans_models):
                model_name = os.path.basename(model_path)
                accurate_model_strings.append(model_name)
                if os.path.abspath(model_path) == os.path.abspath(current_accurate_model_path):
                    accurate_model_selected_idx = i

        accurate_model_dropdown = Gtk.DropDown(model=accurate_model_strings)
        accurate_model_dropdown.set_selected(accurate_model_selected_idx)
        accurate_model_dropdown.set_hexpand(True)
        main_box.append(accurate_model_dropdown)

        accurate_device_label = Gtk.Label(label="Accurate Device")
        accurate_device_label.set_halign(Gtk.Align.START)
        accurate_device_label.set_margin_top(4)
        main_box.append(accurate_device_label)

        accurate_device_strings = Gtk.StringList()
        for device in trans_devices:
            accurate_device_strings.append(device)
        current_accurate_device = self.config.get("transcription_device_accurate", "NPU")
        accurate_device_selected_idx = 0
        for i, device in enumerate(trans_devices):
            if device == current_accurate_device:
                accurate_device_selected_idx = i

        accurate_device_dropdown = Gtk.DropDown(model=accurate_device_strings)
        accurate_device_dropdown.set_selected(accurate_device_selected_idx)
        accurate_device_dropdown.set_hexpand(True)
        main_box.append(accurate_device_dropdown)

        # --- Volume Dimming Section ---
        dim_label = Gtk.Label(label="Volume Dimming While Recording")
        dim_label.set_halign(Gtk.Align.START)
        dim_label.add_css_class("heading")
        dim_label.set_margin_top(12)
        main_box.append(dim_label)

        # Enable checkbox
        dim_check = Gtk.CheckButton(label="Enable volume dimming")
        dim_check.set_active(self.config.get("volume_dimming_enabled", False))
        main_box.append(dim_check)

        # Dimmed volume slider
        dim_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        dim_adj = Gtk.Adjustment(
            value=self.config.get("dimmed_volume", 0.10) * 100,
            lower=0,
            upper=100,
            step_increment=5,
            page_increment=10
        )
        dim_scale = Gtk.Scale(orientation=Gtk.Orientation.HORIZONTAL, adjustment=dim_adj)
        dim_scale.set_hexpand(True)
        dim_scale.set_digits(0)
        dim_scale.add_mark(0, Gtk.PositionType.BOTTOM, "0%")
        dim_scale.add_mark(50, Gtk.PositionType.BOTTOM, "50%")
        dim_scale.add_mark(100, Gtk.PositionType.BOTTOM, "100%")
        dim_box.append(dim_scale)

        dim_value_label = Gtk.Label(label=f"{int(dim_adj.get_value())}%")
        dim_value_label.set_size_request(45, -1)
        dim_box.append(dim_value_label)

        def on_dim_changed(adj):
            dim_value_label.set_label(f"{int(adj.get_value())}%")
        dim_adj.connect("value-changed", on_dim_changed)

        main_box.append(dim_box)

        dim_help = Gtk.Label(label="Percentage of current volume (e.g., 10% at 50% volume → 5%)")
        dim_help.set_halign(Gtk.Align.START)
        dim_help.add_css_class("dim-label")
        main_box.append(dim_help)

        # --- LLM Settings Section ---
        llm_header = Gtk.Label(label="LLM Settings")
        llm_header.set_halign(Gtk.Align.START)
        llm_header.add_css_class("heading")
        llm_header.set_margin_top(12)
        main_box.append(llm_header)

        # Enable LLM checkbox
        llm_enable_check = Gtk.CheckButton(label="Enable LLM mode (Ctrl+Mouse4)")
        llm_enable_check.set_active(self.config.get("llm_enabled", True))
        main_box.append(llm_enable_check)

        # Model path dropdown - scan for .gguf files
        model_label = Gtk.Label(label="Model")
        model_label.set_halign(Gtk.Align.START)
        model_label.set_margin_top(8)
        main_box.append(model_label)

        # Find available models - search multiple locations
        script_dir = os.path.dirname(os.path.abspath(__file__))
        models_dir = os.path.join(script_dir, "models")
        available_models = []
        current_model_path = self.config.get("llm_model_path", "")

        # Directories to search for .gguf files
        search_dirs = [models_dir, script_dir]

        # Also search directory of current model if different
        if current_model_path:
            current_model_dir = os.path.dirname(current_model_path)
            if current_model_dir and current_model_dir not in search_dirs:
                search_dirs.append(current_model_dir)

        # Scan all directories for .gguf files
        seen_paths = set()
        for search_dir in search_dirs:
            if os.path.exists(search_dir):
                for f in sorted(os.listdir(search_dir)):
                    if f.endswith(".gguf"):
                        full_path = os.path.join(search_dir, f)
                        if full_path not in seen_paths:
                            available_models.append(full_path)
                            seen_paths.add(full_path)

        # Ensure current model is in list if it exists
        if current_model_path and os.path.exists(current_model_path) and current_model_path not in seen_paths:
            available_models.insert(0, current_model_path)

        model_strings = Gtk.StringList()
        model_selected_idx = 0
        if not available_models:
            model_strings.append("No models found (place .gguf files in models/)")
        else:
            for i, model_path in enumerate(available_models):
                model_name = os.path.basename(model_path)
                model_strings.append(model_name)
                if model_path == current_model_path:
                    model_selected_idx = i

        model_dropdown = Gtk.DropDown(model=model_strings)
        model_dropdown.set_selected(model_selected_idx)
        model_dropdown.set_hexpand(True)
        main_box.append(model_dropdown)

        # Store available models for save handler
        dialog._available_models = available_models

        # Backend selection
        backend_label = Gtk.Label(label="Backend")
        backend_label.set_halign(Gtk.Align.START)
        backend_label.set_margin_top(8)
        main_box.append(backend_label)

        backend_strings = Gtk.StringList()
        backends = [
            ("cpu", "CPU (llama.cpp)"),
            ("openvino", "OpenVINO (Intel CPU optimized)"),
            ("sycl", "SYCL (Intel iGPU)"),
            ("ipex", "IPEX-LLM (Intel NPU/iGPU)"),
        ]
        current_backend = self.config.get("llm_backend", "cpu")
        backend_selected_idx = 0
        for i, (key, name) in enumerate(backends):
            backend_strings.append(name)
            if key == current_backend:
                backend_selected_idx = i

        backend_dropdown = Gtk.DropDown(model=backend_strings)
        backend_dropdown.set_selected(backend_selected_idx)
        backend_dropdown.set_hexpand(True)
        main_box.append(backend_dropdown)

        dialog._backends = backends

        # Context length slider
        ctx_label = Gtk.Label(label="Context Length")
        ctx_label.set_halign(Gtk.Align.START)
        ctx_label.set_margin_top(8)
        main_box.append(ctx_label)

        ctx_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        current_ctx = self.config.get("llm_context_length", 131072)
        ctx_adj = Gtk.Adjustment(
            value=current_ctx,
            lower=2048,
            upper=131072,
            step_increment=2048,
            page_increment=8192
        )
        ctx_scale = Gtk.Scale(orientation=Gtk.Orientation.HORIZONTAL, adjustment=ctx_adj)
        ctx_scale.set_hexpand(True)
        ctx_scale.set_digits(0)
        ctx_scale.add_mark(2048, Gtk.PositionType.BOTTOM, "2K")
        ctx_scale.add_mark(32768, Gtk.PositionType.BOTTOM, "32K")
        ctx_scale.add_mark(131072, Gtk.PositionType.BOTTOM, "128K")
        ctx_box.append(ctx_scale)

        ctx_value_label = Gtk.Label(label=f"{int(current_ctx/1024)}K")
        ctx_value_label.set_size_request(45, -1)
        ctx_box.append(ctx_value_label)

        def on_ctx_changed(adj):
            ctx_value_label.set_label(f"{int(adj.get_value()/1024)}K")
        ctx_adj.connect("value-changed", on_ctx_changed)

        main_box.append(ctx_box)

        # Thread count slider
        threads_label = Gtk.Label(label="Threads (0 = auto)")
        threads_label.set_halign(Gtk.Align.START)
        threads_label.set_margin_top(8)
        main_box.append(threads_label)

        threads_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        current_threads = self.config.get("llm_threads", 0)
        max_threads = os.cpu_count() or 16
        threads_adj = Gtk.Adjustment(
            value=current_threads,
            lower=0,
            upper=max_threads,
            step_increment=1,
            page_increment=4
        )
        threads_scale = Gtk.Scale(orientation=Gtk.Orientation.HORIZONTAL, adjustment=threads_adj)
        threads_scale.set_hexpand(True)
        threads_scale.set_digits(0)
        threads_scale.add_mark(0, Gtk.PositionType.BOTTOM, "Auto")
        threads_scale.add_mark(max_threads // 2, Gtk.PositionType.BOTTOM, str(max_threads // 2))
        threads_scale.add_mark(max_threads, Gtk.PositionType.BOTTOM, str(max_threads))
        threads_box.append(threads_scale)

        threads_value_label = Gtk.Label(label="Auto" if current_threads == 0 else str(current_threads))
        threads_value_label.set_size_request(45, -1)
        threads_box.append(threads_value_label)

        def on_threads_changed(adj):
            val = int(adj.get_value())
            threads_value_label.set_label("Auto" if val == 0 else str(val))
        threads_adj.connect("value-changed", on_threads_changed)

        main_box.append(threads_box)

        # Strip reasoning checkbox
        strip_reasoning_check = Gtk.CheckButton(label="Strip reasoning tokens (<think>, etc.)")
        strip_reasoning_check.set_active(self.config.get("llm_strip_reasoning", True))
        strip_reasoning_check.set_tooltip_text("Disable to see model's chain-of-thought reasoning")
        strip_reasoning_check.set_margin_top(8)
        main_box.append(strip_reasoning_check)

        # --- System Settings Section ---
        system_header = Gtk.Label(label="System Settings")
        system_header.set_halign(Gtk.Align.START)
        system_header.add_css_class("heading")
        system_header.set_margin_top(12)
        main_box.append(system_header)

        # Enable logging checkbox
        logging_check = Gtk.CheckButton(label="Enable logging to ~/.dictation_*.log files")
        logging_check.set_active(self.config.get("logging_enabled", True))
        logging_check.set_tooltip_text("Disable to prevent creation of potentially large log files")
        main_box.append(logging_check)

        # Daemon control buttons
        daemon_label = Gtk.Label(label="Daemon Control")
        daemon_label.set_halign(Gtk.Align.START)
        daemon_label.add_css_class("heading")
        daemon_label.set_margin_top(12)
        main_box.append(daemon_label)

        restart_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        restart_box.set_margin_top(4)

        script_dir_for_btns = os.path.dirname(os.path.abspath(__file__))
        daemon_script = os.path.join(script_dir_for_btns, "daemon_control.sh")

        # Status label (shared by all buttons)
        daemon_status_label = Gtk.Label(label="")
        daemon_status_label.set_hexpand(True)
        daemon_status_label.set_halign(Gtk.Align.END)

        def run_daemon_cmd(cmd, status_msg):
            daemon_status_label.set_text(status_msg)
            def do_restart():
                try:
                    subprocess.run([daemon_script, cmd], timeout=10)
                    print(f"Daemon command: {cmd}")
                    GLib.idle_add(lambda: daemon_status_label.set_text("Done!"))
                    GLib.timeout_add(2000, lambda: daemon_status_label.set_text("") or False)
                except Exception as e:
                    print(f"Error: {e}")
                    GLib.idle_add(lambda: daemon_status_label.set_text(f"Error!"))
            threading.Thread(target=do_restart, daemon=True).start()

        # Restart All button
        restart_all_btn = Gtk.Button(label="Restart All")
        restart_all_btn.set_tooltip_text("Restart all daemons (transcription + LLM)")
        restart_all_btn.connect("clicked", lambda b: run_daemon_cmd("restart", "Restarting..."))
        restart_box.append(restart_all_btn)

        # Restart LLM button
        restart_llm_btn = Gtk.Button(label="Restart LLM")
        restart_llm_btn.set_tooltip_text("Restart LLM daemon only")
        restart_llm_btn.connect("clicked", lambda b: run_daemon_cmd("restart-llm", "Restarting LLM..."))
        restart_box.append(restart_llm_btn)

        # Restart Transcription button
        restart_trans_btn = Gtk.Button(label="Restart Transcription")
        restart_trans_btn.set_tooltip_text("Restart transcription daemon only")
        restart_trans_btn.connect("clicked", lambda b: run_daemon_cmd("restart-transcription", "Restarting..."))
        restart_box.append(restart_trans_btn)

        restart_box.append(daemon_status_label)
        main_box.append(restart_box)

        # Alias for save handler
        llm_status_label = daemon_status_label

        # --- Buttons ---
        button_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        button_box.set_halign(Gtk.Align.END)
        button_box.set_margin_top(20)

        cancel_btn = Gtk.Button(label="Cancel")
        cancel_btn.connect("clicked", lambda b: dialog.close())
        button_box.append(cancel_btn)

        save_btn = Gtk.Button(label="Save")
        save_btn.add_css_class("suggested-action")

        def on_save(btn):
            # Get selected device
            sel_idx = device_dropdown.get_selected()
            if sel_idx < len(self.devices):
                new_device_index = self.devices[sel_idx]['index']
                if new_device_index != self.selected_device_index:
                    self.selected_device_index = new_device_index
                    print(f"Changed input device to: {self.get_device_name(new_device_index)}")

            # Update config - audio settings
            self.config["device_index"] = self.selected_device_index
            self.config["input_gain"] = gain_adj.get_value()
            self.config["volume_dimming_enabled"] = dim_check.get_active()
            self.config["dimmed_volume"] = dim_adj.get_value() / 100.0

            # Update config - transcription model settings
            trans_model_sel_idx = trans_model_dropdown.get_selected()
            trans_model_changed = False
            if dialog._available_trans_models and trans_model_sel_idx < len(dialog._available_trans_models):
                new_model_path = dialog._available_trans_models[trans_model_sel_idx]
                if new_model_path != self.config.get("model_path"):
                    trans_model_changed = True
                self.config["model_path"] = new_model_path

            trans_device_sel_idx = trans_device_dropdown.get_selected()
            if trans_device_sel_idx < len(dialog._trans_devices):
                new_trans_device = dialog._trans_devices[trans_device_sel_idx]
                if new_trans_device != self.config.get("transcription_device"):
                    trans_model_changed = True
                self.config["transcription_device"] = new_trans_device

            # Preload model setting
            self.config["preload_transcription_model"] = preload_check.get_active()

            # Update config - dual-daemon settings
            dual_daemon_changed = False
            new_dual_daemon_enabled = dual_daemon_check.get_active()
            if new_dual_daemon_enabled != self.config.get("dual_daemon_enabled", False):
                dual_daemon_changed = True
                trans_model_changed = True  # Need to restart daemons
            self.config["dual_daemon_enabled"] = new_dual_daemon_enabled

            # Fast mode settings
            fast_model_sel_idx = fast_model_dropdown.get_selected()
            if dialog._available_trans_models and fast_model_sel_idx < len(dialog._available_trans_models):
                new_fast_model = dialog._available_trans_models[fast_model_sel_idx]
                if new_fast_model != self.config.get("transcription_model_fast"):
                    trans_model_changed = True
                self.config["transcription_model_fast"] = new_fast_model

            fast_device_sel_idx = fast_device_dropdown.get_selected()
            if fast_device_sel_idx < len(dialog._trans_devices):
                new_fast_device = dialog._trans_devices[fast_device_sel_idx]
                if new_fast_device != self.config.get("transcription_device_fast"):
                    trans_model_changed = True
                self.config["transcription_device_fast"] = new_fast_device

            # Accurate mode settings
            accurate_model_sel_idx = accurate_model_dropdown.get_selected()
            if dialog._available_trans_models and accurate_model_sel_idx < len(dialog._available_trans_models):
                new_accurate_model = dialog._available_trans_models[accurate_model_sel_idx]
                if new_accurate_model != self.config.get("transcription_model_accurate"):
                    trans_model_changed = True
                self.config["transcription_model_accurate"] = new_accurate_model

            accurate_device_sel_idx = accurate_device_dropdown.get_selected()
            if accurate_device_sel_idx < len(dialog._trans_devices):
                new_accurate_device = dialog._trans_devices[accurate_device_sel_idx]
                if new_accurate_device != self.config.get("transcription_device_accurate"):
                    trans_model_changed = True
                self.config["transcription_device_accurate"] = new_accurate_device

            # Update config - LLM settings
            self.config["llm_enabled"] = llm_enable_check.get_active()

            # Model path
            model_sel_idx = model_dropdown.get_selected()
            if dialog._available_models and model_sel_idx < len(dialog._available_models):
                self.config["llm_model_path"] = dialog._available_models[model_sel_idx]

            # Backend
            backend_sel_idx = backend_dropdown.get_selected()
            if backend_sel_idx < len(dialog._backends):
                self.config["llm_backend"] = dialog._backends[backend_sel_idx][0]

            # Context length, threads, and reasoning
            self.config["llm_context_length"] = int(ctx_adj.get_value())
            self.config["llm_threads"] = int(threads_adj.get_value())
            self.config["llm_strip_reasoning"] = strip_reasoning_check.get_active()

            # System settings
            self.config["logging_enabled"] = logging_check.get_active()

            # Save to file and restart daemons
            try:
                self.save_config()
                print(f"Settings saved to {CONFIG_FILE}")
                print(f"  Audio: device={self.selected_device_index}, gain={self.config['input_gain']:.1f}x")
                if self.config.get("dual_daemon_enabled", False):
                    print(f"  Transcription: dual-daemon mode ENABLED")
                    print(f"    Fast: {self.config.get('transcription_model_fast')} on {self.config.get('transcription_device_fast')}")
                    print(f"    Accurate: {self.config.get('transcription_model_accurate')} on {self.config.get('transcription_device_accurate')}")
                    print(f"    Preload: {self.config.get('preload_transcription_model')}")
                else:
                    print(f"  Transcription: model={self.config.get('model_path')}, device={self.config.get('transcription_device')}, preload={self.config.get('preload_transcription_model')}")
                print(f"  LLM: enabled={self.config.get('llm_enabled')}")
                print(f"  LLM: model={self.config.get('llm_model_path', 'none')}")
                print(f"  LLM: backend={self.config.get('llm_backend')}, ctx={self.config.get('llm_context_length')}, threads={self.config.get('llm_threads')}")

                # Auto-restart daemons to apply changes
                if trans_model_changed:
                    llm_status_label.set_text("Saved! Restarting all daemons...")
                    restart_cmd = "restart"
                else:
                    llm_status_label.set_text("Saved! Restarting LLM...")
                    restart_cmd = "restart-llm"

                def do_restart():
                    try:
                        subprocess.run([daemon_script, restart_cmd], timeout=15)
                        print(f"Daemons restarted after save ({restart_cmd})")
                        GLib.idle_add(lambda: llm_status_label.set_text("Saved & restarted!"))
                    except Exception as e:
                        print(f"Error restarting daemons: {e}")
                        GLib.idle_add(lambda: llm_status_label.set_text("Saved (restart failed)"))
                threading.Thread(target=do_restart, daemon=True).start()

            except Exception as e:
                print(f"Error saving settings: {e}")
                llm_status_label.set_text(f"Error: {e}")

        save_btn.connect("clicked", on_save)
        button_box.append(save_btn)

        main_box.append(button_box)

        scrolled.set_child(main_box)
        dialog.set_child(scrolled)
        dialog.present()

    def save_config(self):
        """Save current configuration to file."""
        try:
            with open(CONFIG_FILE, "w") as f:
                json.dump(self.config, f, indent=2)
        except Exception as e:
            print(f"Error saving config: {e}")

    def cleanup(self):
        """Clean up resources."""
        self.running = False
        self.is_recording = False
        if self.stream:
            try:
                self.stream.stop_stream()
                self.stream.close()
            except:
                pass
        self.audio.terminate()


def on_activate(app):
    """GTK application activate handler."""
    dictation = DictationApp(app)

    # Keep a reference
    app.dictation = dictation

    # Write PID file
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))


def on_shutdown(app):
    """GTK application shutdown handler."""
    if hasattr(app, 'dictation'):
        app.dictation.cleanup()

    try:
        os.unlink(PID_FILE)
    except:
        pass


def check_already_running():
    """Check if app is already running."""
    if os.path.exists(PID_FILE):
        try:
            with open(PID_FILE, "r") as f:
                old_pid = int(f.read().strip())
            os.kill(old_pid, 0)
            print(f"Dictation app already running (PID {old_pid})")
            sys.exit(1)
        except OSError:
            os.remove(PID_FILE)
        except:
            pass


def main():
    check_already_running()

    print("Starting dictation app (GTK4)...")
    print("=" * 50)

    app = Gtk.Application(application_id='com.dictation.app')
    app.connect('activate', on_activate)
    app.connect('shutdown', on_shutdown)

    # Handle signals
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, lambda: app.quit() or True)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, lambda: app.quit() or True)

    app.run(None)


if __name__ == "__main__":
    main()
