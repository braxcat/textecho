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
from dictation_overlay import DictationOverlay, LAYER_SHELL_AVAILABLE

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

        # Load config
        self.config = self.load_config()

        # Audio settings
        self.CHUNK = 1024
        self.FORMAT = pyaudio.paInt16
        self.CHANNELS = 1
        self.RATE = 16000
        self.actual_rate = self.RATE

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

        print(f"Monitoring {len(self.mouse_devices)} mouse device(s):")
        for dev in self.mouse_devices:
            print(f"  - {dev.name}")
        print(f"\nUsing audio device: {self.get_device_name(self.selected_device_index)}")
        print(f"Press Mouse 4 (BTN_EXTRA) to record, release to transcribe")
        print(f"Press Ctrl+C to quit\n")

        # Start evdev monitoring in a thread
        self.evdev_thread = threading.Thread(target=self.monitor_mouse, daemon=True)
        self.evdev_thread.start()

    def load_config(self):
        """Load configuration from file."""
        if os.path.exists(CONFIG_FILE):
            try:
                with open(CONFIG_FILE, "r") as f:
                    config = json.load(f)
                    if isinstance(config, dict):
                        return config
            except:
                pass
        return {}

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

    def monitor_mouse(self):
        """Monitor mouse devices for button events (runs in background thread)."""
        device_map = {dev.fd: dev for dev in self.mouse_devices}

        while self.running:
            try:
                r, _, _ = select.select(list(device_map.keys()), [], [], 0.1)

                for fd in r:
                    device = device_map[fd]
                    for event in device.read():
                        # Handle button press/release
                        if event.type == ecodes.EV_KEY and event.code == MOUSE_BUTTON:
                            key_event = categorize(event)
                            if key_event.keystate == key_event.key_down:
                                # Get mouse position right when button is pressed
                                x, y = self.get_mouse_position()
                                print(f"Mouse button pressed at ({x}, {y})")
                                GLib.idle_add(self.start_recording_at_mouse)
                            elif key_event.keystate == key_event.key_up:
                                print("Mouse button released - stopping recording")
                                GLib.idle_add(self.stop_and_transcribe)
            except Exception as e:
                if self.running:
                    print(f"Error in mouse monitoring: {e}")

    def get_mouse_position(self):
        """Get current mouse position using xdotool."""
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
            print(f"[DEBUG] xdotool failed: {e}")

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
            self.overlay.hide()
            return

        # Start recording thread
        self.record_thread = threading.Thread(target=self.record_audio, daemon=True)
        self.record_thread.start()

        # Start waveform updates
        GLib.timeout_add(50, self.update_waveform)

    def record_audio(self):
        """Record audio in background thread."""
        while self.is_recording and self.stream:
            try:
                data = self.stream.read(self.CHUNK, exception_on_overflow=False)
                self.frames.append(data)
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
        print(f"[DEBUG] Recording thread finished, captured {len(self.frames)} frames")

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

        # Check if we have enough audio
        if len(self.frames) < 10:
            print(f"Too short ({len(self.frames)} frames), skipping")
            self.overlay.hide()
            return

        # Update status
        self.overlay.set_status("transcribing")

        # Transcribe in background
        threading.Thread(target=self.save_and_transcribe, daemon=True).start()

    def save_and_transcribe(self):
        """Save audio and send to transcription daemon."""
        try:
            # Save to temp file
            temp_wav = tempfile.NamedTemporaryFile(delete=False, suffix=".wav")
            wf = wave.open(temp_wav.name, "wb")
            wf.setnchannels(self.CHANNELS)
            wf.setsampwidth(self.audio.get_sample_size(self.FORMAT))
            wf.setframerate(self.actual_rate)
            wf.writeframes(b"".join(self.frames))
            wf.close()

            print(f"Saved {len(self.frames)} frames to {temp_wav.name}")

            # Send to daemon
            result = self.send_to_daemon(temp_wav.name)

            if result.get("success"):
                transcription = result.get("transcription", "").strip()

                # Filter hallucinations (common Whisper artifacts on silence/short audio)
                hallucination_phrases = [
                    "thanks for watching", "thank you for watching",
                    "please subscribe", "like and subscribe",
                    "see you next time", "see you in the next",
                    "don't forget to subscribe",
                    "[music]", "(music)", "[silence]", "[blank_audio]",
                ]
                lower_text = transcription.lower()
                is_hallucination = any(phrase in lower_text for phrase in hallucination_phrases)
                # Also filter if too short (likely noise)
                is_too_short = len(transcription) < 2

                if is_hallucination or is_too_short:
                    print(f"Filtered: '{transcription}' (hallucination={is_hallucination}, too_short={is_too_short})")
                    transcription = ""

                if transcription:
                    print(f"Transcription: {transcription}")
                    GLib.idle_add(self.overlay.hide)
                    import time
                    time.sleep(0.2)
                    self.type_text(transcription)
                else:
                    print("No transcription (empty or filtered)")
                    GLib.idle_add(self.overlay.hide)
            else:
                error = result.get("error", "Unknown error")
                print(f"Transcription error: {error}")
                GLib.idle_add(self.overlay.hide)

            # Clean up
            try:
                os.unlink(temp_wav.name)
            except:
                pass

        except Exception as e:
            print(f"Error in transcription: {e}")
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

    def type_text(self, text):
        """Paste text using clipboard."""
        env = os.environ.copy()
        env['YDOTOOL_SOCKET'] = '/tmp/.ydotool_socket'

        try:
            # Save clipboard
            old_clipboard = None
            try:
                result = subprocess.run(["wl-paste", "-n"], capture_output=True, timeout=2)
                if result.returncode == 0:
                    old_clipboard = result.stdout
            except:
                pass

            # Set clipboard
            subprocess.run(["wl-copy", "--", text], check=True, timeout=2)

            import time
            time.sleep(0.05)

            # Paste with Shift+Insert
            subprocess.run(["ydotool", "key", "shift+insert"], env=env, check=True, timeout=5)

            time.sleep(0.1)

            # Restore clipboard
            if old_clipboard is not None:
                subprocess.run(["wl-copy", "--"], input=old_clipboard, timeout=2)

            print("[DEBUG] Pasted text via clipboard")

        except Exception as e:
            print(f"Paste error: {e}")

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
