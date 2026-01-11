#!/usr/bin/env python3
"""
Unified dictation app - combines evdev mouse monitoring and recording GUI
in a single process for reliable push-to-talk dictation.
"""

import argparse
import json
import os
import select
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import tkinter as tk
import wave
from tkinter import ttk

import numpy as np
import pyaudio
from evdev import InputDevice, categorize, ecodes, list_devices

# Configuration
PID_FILE = os.path.expanduser("~/.dictation_app.pid")
CONFIG_FILE = os.path.expanduser("~/.dictation_config")
DAEMON_SOCKET = "/tmp/dictation_transcription.sock"
MOUSE_BUTTON = ecodes.BTN_EXTRA  # Mouse 4 (first side button)


class DictationApp:
    def __init__(self):
        # State
        self.is_recording = False
        self.frames = []
        self.stream = None
        self.mouse_devices = []
        self.running = True

        # Thread-safe communication
        self.pending_actions = []
        self.action_lock = threading.Lock()

        # Load config
        self.config = self.load_config()

        # Audio settings
        self.CHUNK = 1024
        self.FORMAT = pyaudio.paInt16
        self.CHANNELS = 1
        self.RATE = 16000
        self.actual_rate = self.RATE

        # Initialize PyAudio once and keep it
        self.audio = pyaudio.PyAudio()
        self.devices = self.get_input_devices()
        self.selected_device_index = self.get_default_device_index()

        # Setup GUI (hidden initially)
        self.setup_gui()

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

        # Start evdev monitoring thread
        self.evdev_thread = threading.Thread(target=self.monitor_mouse, daemon=True)
        self.evdev_thread.start()

        # Start action processor
        self.process_actions()

    def load_config(self):
        """Load configuration from file"""
        if os.path.exists(CONFIG_FILE):
            try:
                with open(CONFIG_FILE, "r") as f:
                    config = json.load(f)
                    if isinstance(config, dict):
                        return config
                    elif isinstance(config, (int, str)):
                        return {"device_index": int(config)}
            except:
                pass
        return {}

    def save_config(self):
        """Save configuration to file"""
        try:
            with open(CONFIG_FILE, "w") as f:
                json.dump(self.config, f)
        except Exception as e:
            print(f"Warning: Could not save config: {e}")

    def get_input_devices(self):
        """Get list of input devices"""
        devices = []
        for i in range(self.audio.get_device_count()):
            info = self.audio.get_device_info_by_index(i)
            if info["maxInputChannels"] > 0:
                devices.append({"index": i, "name": info["name"]})
        return devices

    def get_device_name(self, index):
        """Get device name by index"""
        for d in self.devices:
            if d["index"] == index:
                return d["name"]
        return f"Device {index}"

    def get_default_device_index(self):
        """Get the default input device index, or last used from config"""
        # Try saved device first
        if "device_index" in self.config:
            saved_index = int(self.config["device_index"])
            if any(d["index"] == saved_index for d in self.devices):
                return saved_index

        # Fall back to system default
        try:
            default_device = self.audio.get_default_input_device_info()
            return default_device["index"]
        except:
            return self.devices[0]["index"] if self.devices else 0

    def find_mouse_devices(self):
        """Find mouse devices with side buttons"""
        devices = []
        for path in list_devices():
            try:
                device = InputDevice(path)
                # Skip virtual devices
                if 'virtual' in device.name.lower():
                    continue
                # Must have key capabilities with our button
                if ecodes.EV_KEY in device.capabilities():
                    keys = device.capabilities()[ecodes.EV_KEY]
                    if MOUSE_BUTTON in keys:
                        devices.append(device)
            except Exception as e:
                continue
        return devices

    def setup_gui(self):
        """Create the GUI (hidden initially)"""
        self.root = tk.Tk()
        self.root.title("Dictation")
        self.root.geometry("400x200")
        self.root.attributes("-topmost", True)
        self.root.withdraw()  # Start hidden

        # Prevent window manager from stealing focus aggressively
        self.root.overrideredirect(False)

        # Main frame
        main_frame = ttk.Frame(self.root, padding="10")
        main_frame.pack(fill=tk.BOTH, expand=True)

        # Status label
        self.status_label = ttk.Label(
            main_frame,
            text="Recording...",
            font=("Arial", 14, "bold"),
            foreground="red"
        )
        self.status_label.pack(pady=10)

        # Waveform canvas
        self.canvas = tk.Canvas(main_frame, bg="black", height=100)
        self.canvas.pack(fill=tk.BOTH, expand=True, pady=10)

        # Info label
        self.info_label = ttk.Label(
            main_frame,
            text="Release mouse button to transcribe",
            font=("Arial", 10),
            foreground="gray"
        )
        self.info_label.pack()

        # Handle window close
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

        # Bind escape to cancel
        self.root.bind("<Escape>", lambda e: self.cancel_recording())

    def on_close(self):
        """Handle window close request"""
        self.running = False
        self.root.quit()

    def queue_action(self, action):
        """Queue an action to be processed in the main thread"""
        with self.action_lock:
            self.pending_actions.append(action)
            print(f"[DEBUG] Queued action: {action}, queue size: {len(self.pending_actions)}")

    def process_actions(self):
        """Process queued actions in the main thread"""
        with self.action_lock:
            actions = self.pending_actions[:]
            self.pending_actions.clear()

        for action in actions:
            print(f"[DEBUG] Processing action: {action}, is_recording={self.is_recording}")
            if action == "start":
                self.show_and_start_recording()
            elif action == "stop":
                self.stop_and_transcribe()

        # Schedule next check
        if self.running:
            self.root.after(10, self.process_actions)

    def monitor_mouse(self):
        """Monitor mouse devices for button events (runs in background thread)"""
        device_map = {dev.fd: dev for dev in self.mouse_devices}

        while self.running:
            try:
                # Wait for events with timeout so we can check self.running
                r, _, _ = select.select(list(device_map.keys()), [], [], 0.1)

                for fd in r:
                    device = device_map[fd]
                    for event in device.read():
                        if event.type == ecodes.EV_KEY and event.code == MOUSE_BUTTON:
                            key_event = categorize(event)
                            if key_event.keystate == key_event.key_down:
                                print("Mouse button pressed - starting recording")
                                self.queue_action("start")
                            elif key_event.keystate == key_event.key_up:
                                print("Mouse button released - stopping recording")
                                self.queue_action("stop")
            except Exception as e:
                if self.running:
                    print(f"Error in mouse monitoring: {e}")

    def show_and_start_recording(self):
        """Show window and start recording"""
        print(f"[DEBUG] show_and_start_recording called, is_recording={self.is_recording}")
        if self.is_recording:
            print("[DEBUG] Already recording, skipping")
            return

        # Position window near mouse cursor
        try:
            mouse_x = self.root.winfo_pointerx()
            mouse_y = self.root.winfo_pointery()
            # Offset so window doesn't appear directly under cursor
            self.root.geometry(f"400x200+{mouse_x + 20}+{mouse_y + 20}")
        except:
            pass

        # Show window
        self.root.deiconify()
        self.root.lift()

        # Update status
        self.status_label.config(text="Recording...", foreground="red")
        self.info_label.config(text="Release mouse button to transcribe")

        # Start recording
        self.start_recording()

    def start_recording(self):
        """Start audio recording"""
        self.is_recording = True
        self.frames = []

        device_index = self.selected_device_index

        # Determine sample rate
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
            self.root.withdraw()
            return

        # Start recording thread
        self.record_thread = threading.Thread(target=self.record_audio, daemon=True)
        self.record_thread.start()

        # Start visualization
        self.visualize()

    def record_audio(self):
        """Record audio in background thread"""
        while self.is_recording and self.stream:
            try:
                data = self.stream.read(self.CHUNK, exception_on_overflow=False)
                self.frames.append(data)
            except Exception as e:
                if self.is_recording:
                    print(f"Recording error: {e}")
                break

        # Clean up stream in this thread to avoid race condition
        if self.stream:
            try:
                self.stream.stop_stream()
                self.stream.close()
            except:
                pass
            self.stream = None
        print(f"[DEBUG] Recording thread finished, captured {len(self.frames)} frames")

    def visualize(self):
        """Draw waveform visualization"""
        if not self.is_recording:
            return

        if self.frames:
            try:
                latest = np.frombuffer(self.frames[-1], dtype=np.int16)
                canvas_height = self.canvas.winfo_height()
                canvas_width = self.canvas.winfo_width()

                if canvas_height > 0 and canvas_width > 0:
                    normalized = (latest / 32768.0) * (canvas_height / 2)
                    self.canvas.delete("all")

                    points = []
                    step = max(1, len(normalized) // canvas_width)
                    for i, val in enumerate(normalized[::step]):
                        x = (i / len(normalized[::step])) * canvas_width
                        y = (canvas_height / 2) + val
                        points.append((x, y))

                    if len(points) > 1:
                        self.canvas.create_line(points, fill="lime", width=2)
            except:
                pass

        if self.is_recording:
            self.root.after(50, self.visualize)

    def stop_and_transcribe(self):
        """Stop recording and transcribe"""
        print(f"[DEBUG] stop_and_transcribe called, is_recording={self.is_recording}, frames={len(self.frames)}")
        if not self.is_recording:
            print("[DEBUG] Not recording, skipping stop")
            return

        self.is_recording = False

        # Wait for recording thread to finish and clean up stream
        if hasattr(self, 'record_thread') and self.record_thread.is_alive():
            print("[DEBUG] Waiting for recording thread to finish...")
            self.record_thread.join(timeout=1.0)

        # Check if we have enough audio
        min_frames = 10  # Minimum frames to attempt transcription
        if len(self.frames) < min_frames:
            print(f"Too short ({len(self.frames)} frames), skipping transcription")
            self.root.withdraw()
            return

        # Update UI
        self.status_label.config(text="Transcribing...", foreground="orange")
        self.info_label.config(text="Please wait...")

        # Save audio and transcribe in background
        threading.Thread(target=self.save_and_transcribe, daemon=True).start()

    def save_and_transcribe(self):
        """Save audio to file and send to transcription daemon"""
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

            # Send to transcription daemon
            result = self.send_to_daemon(temp_wav.name)

            if result.get("success"):
                transcription = result.get("transcription", "").strip()

                if transcription:
                    # Filter out common Whisper hallucinations
                    hallucinations = [
                        "thanks for watching",
                        "thank you for watching",
                        "please subscribe",
                        "like and subscribe",
                        "[music]",
                        "(music)",
                    ]
                    if transcription.lower() in hallucinations:
                        print(f"Filtered hallucination: {transcription}")
                        transcription = ""

                if transcription:
                    print(f"Transcription: {transcription}")
                    # Hide window before typing
                    self.root.after(0, self.root.withdraw)
                    # Small delay then type
                    import time
                    time.sleep(0.2)
                    self.type_text(transcription)
                else:
                    print("No transcription (empty or filtered)")
                    self.root.after(0, self.root.withdraw)
            else:
                error = result.get("error", "Unknown error")
                print(f"Transcription error: {error}")
                self.root.after(0, lambda: self.show_error(error))

            # Clean up temp file
            try:
                os.unlink(temp_wav.name)
            except:
                pass

        except Exception as e:
            print(f"Error in transcription: {e}")
            self.root.after(0, self.root.withdraw)

    def send_to_daemon(self, audio_file):
        """Send transcription request to daemon"""
        try:
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(30)  # 30 second timeout
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
            return {"success": False, "error": "Transcription daemon not running. Start it with: ./daemon_control.sh start"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def type_text(self, text):
        """Paste text into active window using clipboard"""
        env = os.environ.copy()
        env['YDOTOOL_SOCKET'] = '/tmp/.ydotool_socket'

        try:
            # Save current clipboard contents
            old_clipboard = None
            try:
                result = subprocess.run(
                    ["wl-paste", "-n"],
                    capture_output=True,
                    timeout=2
                )
                if result.returncode == 0:
                    old_clipboard = result.stdout
            except:
                pass  # Clipboard might be empty or contain non-text

            # Set clipboard to transcription
            subprocess.run(
                ["wl-copy", "--", text],
                check=True,
                timeout=2
            )

            # Small delay for clipboard to update
            import time
            time.sleep(0.05)

            # Paste with Shift+Insert (universal - works in terminals and GUI apps)
            subprocess.run(
                ["ydotool", "key", "shift+insert"],
                env=env,
                check=True,
                timeout=5
            )

            # Small delay before restoring clipboard
            time.sleep(0.1)

            # Restore original clipboard
            if old_clipboard is not None:
                subprocess.run(
                    ["wl-copy", "--"],
                    input=old_clipboard,
                    timeout=2
                )

            print(f"[DEBUG] Pasted text via clipboard")

        except FileNotFoundError as e:
            print(f"Required tool not found: {e}. Need wl-copy, wl-paste, and ydotool.")
        except subprocess.CalledProcessError as e:
            print(f"Paste error: {e.stderr.decode() if e.stderr else e}")
        except Exception as e:
            print(f"Paste error: {e}")

    def show_error(self, error):
        """Show error in GUI"""
        self.status_label.config(text="Error", foreground="red")
        self.info_label.config(text=error[:50])
        # Auto-hide after 2 seconds
        self.root.after(2000, self.root.withdraw)

    def cancel_recording(self):
        """Cancel current recording"""
        self.is_recording = False
        if self.stream:
            try:
                self.stream.stop_stream()
                self.stream.close()
            except:
                pass
            self.stream = None
        self.root.withdraw()

    def run(self):
        """Run the application"""
        # Write PID file
        with open(PID_FILE, "w") as f:
            f.write(str(os.getpid()))

        try:
            self.root.mainloop()
        finally:
            self.running = False
            self.audio.terminate()
            # Clean up PID file
            try:
                os.unlink(PID_FILE)
            except:
                pass


def check_already_running():
    """Check if app is already running"""
    if os.path.exists(PID_FILE):
        try:
            with open(PID_FILE, "r") as f:
                old_pid = int(f.read().strip())
            os.kill(old_pid, 0)
            print(f"Dictation app already running (PID {old_pid})")
            print(f"Run: kill {old_pid} to stop it")
            sys.exit(1)
        except OSError:
            os.remove(PID_FILE)
        except:
            pass


def main():
    # Handle signals
    signal.signal(signal.SIGINT, lambda s, f: sys.exit(0))
    signal.signal(signal.SIGTERM, lambda s, f: sys.exit(0))

    # Check if already running
    check_already_running()

    print("Starting dictation app...")
    print("=" * 50)

    app = DictationApp()
    app.run()


if __name__ == "__main__":
    main()
