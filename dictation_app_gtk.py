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
import tempfile
import threading
import wave

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

        # Volume dimming state
        self.original_volume = None

        # Load config
        self.config = self.load_config()

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

    def dim_volume(self):
        """Dim system volume for recording."""
        if not self.config.get("volume_dimming_enabled", False):
            return

        self.original_volume = self.get_system_volume()
        if self.original_volume is not None:
            dimmed = self.config.get("dimmed_volume", 0.10)
            if self.set_system_volume(dimmed):
                print(f"Volume dimmed: {self.original_volume:.0%} -> {dimmed:.0%}")

    def restore_volume(self):
        """Restore system volume after recording."""
        if not self.config.get("volume_dimming_enabled", False):
            return

        if self.original_volume is not None:
            if self.set_system_volume(self.original_volume):
                print(f"Volume restored: {self.original_volume:.0%}")
            self.original_volume = None

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
                            if dev_type == 'mouse' and event.code == MOUSE_BUTTON:
                                if key_event.keystate == key_event.key_down:
                                    # Get mouse position right when button is pressed
                                    x, y = self.get_mouse_position()
                                    print(f"Mouse button pressed at ({x}, {y})")
                                    GLib.idle_add(self.start_recording_at_mouse)
                                elif key_event.keystate == key_event.key_up:
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

                            # Escape key during transcription (early cancel)
                            elif dev_type == 'keyboard' and self.is_transcribing and key_event.keystate == key_event.key_down:
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

        # Start recording
        self.start_recording()

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

    def record_audio(self):
        """Record audio in background thread with pause detection."""
        consecutive_silent_chunks = 0
        last_speech_frame = 0  # Track where speech ended
        MIN_FRAMES_BEFORE_INTERIM = int(0.5 * self.RATE / self.CHUNK)  # 0.5s minimum

        while self.is_recording and self.stream:
            try:
                data = self.stream.read(self.CHUNK, exception_on_overflow=False)
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
            # Save frames to temp file
            temp_wav = tempfile.NamedTemporaryFile(delete=False, suffix=".wav")
            wf = wave.open(temp_wav.name, "wb")
            wf.setnchannels(self.CHANNELS)
            wf.setsampwidth(self.audio.get_sample_size(self.FORMAT))
            wf.setframerate(self.actual_rate)
            wf.writeframes(b"".join(frames))
            wf.close()

            # Send to daemon
            result = self.send_to_daemon(temp_wav.name)

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

            # Clean up temp file
            try:
                os.unlink(temp_wav.name)
            except:
                pass

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
                    temp_wav = tempfile.NamedTemporaryFile(delete=False, suffix=".wav")
                    wf = wave.open(temp_wav.name, "wb")
                    wf.setnchannels(self.CHANNELS)
                    wf.setsampwidth(self.audio.get_sample_size(self.FORMAT))
                    wf.setframerate(self.actual_rate)
                    wf.writeframes(b"".join(remaining_frames))
                    wf.close()

                    print(f"[Concatenate] Transcribing {len(remaining_frames)} remaining frames")
                    result = self.send_to_daemon(temp_wav.name)

                    if result.get("success"):
                        remaining_text = result.get("transcription", "").strip()
                        if remaining_text and len(remaining_text) >= 2:
                            self.interim_transcriptions.append(remaining_text)

                    try:
                        os.unlink(temp_wav.name)
                    except:
                        pass

                # Combine all interim transcriptions
                final_transcription = " ".join(self.interim_transcriptions)
                print(f"[Concatenate] Final: {final_transcription}")

            else:
                # Full mode (default): transcribe entire recording
                temp_wav = tempfile.NamedTemporaryFile(delete=False, suffix=".wav")
                wf = wave.open(temp_wav.name, "wb")
                wf.setnchannels(self.CHANNELS)
                wf.setsampwidth(self.audio.get_sample_size(self.FORMAT))
                wf.setframerate(self.actual_rate)
                wf.writeframes(b"".join(self.frames))
                wf.close()

                print(f"[Full] Transcribing {len(self.frames)} frames (RMS={rms:.4f})")
                result = self.send_to_daemon(temp_wav.name)

                if result.get("success"):
                    final_transcription = result.get("transcription", "").strip()

                try:
                    os.unlink(temp_wav.name)
                except:
                    pass

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

    def send_to_daemon(self, audio_file):
        """Send transcription request to daemon."""
        try:
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(30)
            client.connect(DAEMON_SOCKET)

            request = {"command": "transcribe", "audio_file": audio_file}
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
            return json.loads(response_data.decode())

        except FileNotFoundError:
            return {"success": False, "error": "Transcription daemon not running"}
        except Exception as e:
            return {"success": False, "error": str(e)}

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
