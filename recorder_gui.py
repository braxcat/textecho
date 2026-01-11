#!/usr/bin/env python3
"""
Recording GUI with waveform visualization
"""

import json
import os
import socket
import subprocess
import tempfile
import threading
import tkinter as tk
import wave
from datetime import datetime
from tkinter import ttk

import numpy as np
import pyaudio


class RecorderGUI:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("Dictation Recording")
        self.root.geometry("500x300")
        self.root.attributes("-topmost", True)

        # Audio settings
        self.CHUNK = 1024
        self.FORMAT = pyaudio.paInt16
        self.CHANNELS = 1
        self.RATE = 16000

        # Config file for device persistence
        self.config_file = os.path.expanduser("~/.dictation_config")

        # Silence detection settings
        self.silence_duration = self.load_silence_duration()  # seconds
        self.silence_threshold = self.load_silence_threshold()  # amplitude threshold for silence
        self.silence_chunks = 0  # counter for consecutive silent chunks

        self.audio = pyaudio.PyAudio()
        self.frames = []
        self.is_recording = False
        self.stream = None

        # Daemon socket path
        self.daemon_socket = "/tmp/dictation_transcription.sock"

        # Get input devices
        self.devices = self.get_input_devices()
        self.default_device_index = self.get_default_device_index()

        self.setup_ui()

        # Auto-start recording
        self.root.after(100, self.start_recording)

    def get_input_devices(self):
        """Get list of input devices"""
        devices = []
        for i in range(self.audio.get_device_count()):
            info = self.audio.get_device_info_by_index(i)
            if info["maxInputChannels"] > 0:
                devices.append({"index": i, "name": info["name"]})
        return devices

    def get_default_device_index(self):
        """Get the default input device index, or last used device from config"""
        # First try to load saved device from config
        try:
            config = self.load_config()
            if "device_index" in config:
                saved_index = int(config["device_index"])
                # Verify it's still a valid device
                if any(d["index"] == saved_index for d in self.devices):
                    return saved_index
        except:
            pass

        # Fall back to system default
        try:
            default_device = self.audio.get_default_input_device_info()
            default_index = default_device["index"]
            return default_index
        except:
            # If all else fails, use first device
            return self.devices[0]["index"] if self.devices else 0

    def save_device_preference(self, device_index):
        """Save the selected device for next time"""
        try:
            config = self.load_config()
            config["device_index"] = device_index
            self.save_config(config)
        except:
            pass

    def load_silence_duration(self):
        """Load silence duration from config, default to 2.5 seconds"""
        try:
            config = self.load_config()
            return float(config.get("silence_duration", 2.5))
        except:
            return 2.5

    def load_silence_threshold(self):
        """Load silence threshold from config, default to 300"""
        try:
            config = self.load_config()
            return int(config.get("silence_threshold", 300))
        except:
            return 300

    def load_config(self):
        """Load configuration from file"""
        if os.path.exists(self.config_file):
            try:
                with open(self.config_file, "r") as f:
                    import json
                    config = json.load(f)
                    # Handle old format (single int) vs new format (dict)
                    if isinstance(config, dict):
                        return config
                    elif isinstance(config, (int, str)):
                        # Old format - just device index
                        return {"device_index": int(config)}
            except:
                pass
        return {}

    def save_config(self, config):
        """Save configuration to file"""
        try:
            import json
            with open(self.config_file, "w") as f:
                json.dump(config, f)
        except:
            pass


    def setup_ui(self):
        """Create the GUI"""
        # Device selector
        device_frame = ttk.Frame(self.root, padding="10")
        device_frame.pack(fill=tk.X)

        ttk.Label(device_frame, text="Input Device:").pack(side=tk.LEFT)

        self.device_var = tk.StringVar()
        device_names = [d["name"] for d in self.devices]
        self.device_combo = ttk.Combobox(
            device_frame,
            textvariable=self.device_var,
            values=device_names,
            state="readonly",
        )
        # Select the default or last-used device
        if device_names:
            # Find the index in the combo box that matches our default device
            for i, device in enumerate(self.devices):
                if device["index"] == self.default_device_index:
                    self.device_combo.current(i)
                    break
            else:
                # Fallback to first device if not found
                self.device_combo.current(0)
        self.device_combo.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=5)

        # Waveform canvas
        self.canvas = tk.Canvas(self.root, bg="black", height=150)
        self.canvas.pack(fill=tk.BOTH, expand=True, padx=10, pady=10)

        # Transcription text (optional - shown after recording)
        self.transcription_label = ttk.Label(
            self.root, text="", wraplength=480, font=("Arial", 10)
        )
        self.transcription_label.pack(fill=tk.X, padx=10)

        # Status and controls
        control_frame = ttk.Frame(self.root, padding="10")
        control_frame.pack(fill=tk.X)

        self.status_label = ttk.Label(control_frame, text="Ready", foreground="gray")
        self.status_label.pack(side=tk.LEFT)

        # Silence indicator
        self.silence_label = ttk.Label(
            control_frame,
            text="",
            foreground="gray",
            font=("Arial", 9),
        )
        self.silence_label.pack(side=tk.LEFT, padx=20)

        # Silence duration info
        silence_info = ttk.Label(
            control_frame,
            text=f"Auto-stop: {self.silence_duration}s silence",
            foreground="gray",
            font=("Arial", 8),
        )
        silence_info.pack(side=tk.RIGHT)

        self.stop_btn = ttk.Button(
            control_frame, text="Stop & Transcribe", command=self.stop_recording
        )
        self.stop_btn.pack(side=tk.RIGHT)

        # Bind ESC to cancel
        self.root.bind("<Escape>", lambda e: self.cancel())

    def start_recording(self):
        """Start audio recording"""
        self.is_recording = True
        self.frames = []
        self.silence_chunks = 0  # Reset silence counter

        device_index = self.devices[self.device_combo.current()]["index"]

        # Save device preference for next time
        self.save_device_preference(device_index)

        # Get device info to check supported sample rate
        device_info = self.audio.get_device_info_by_index(device_index)

        # Try to use our preferred rate, fall back to device default
        try:
            # Test if our preferred rate is supported
            if self.audio.is_format_supported(
                self.RATE,
                input_device=device_index,
                input_channels=self.CHANNELS,
                input_format=self.FORMAT
            ):
                sample_rate = self.RATE
            else:
                # Use device's default sample rate
                sample_rate = int(device_info['defaultSampleRate'])
        except:
            # Fallback to common rates
            for rate in [16000, 44100, 48000, 22050, 8000]:
                try:
                    if self.audio.is_format_supported(
                        rate,
                        input_device=device_index,
                        input_channels=self.CHANNELS,
                        input_format=self.FORMAT
                    ):
                        sample_rate = rate
                        break
                except:
                    continue
            else:
                sample_rate = int(device_info['defaultSampleRate'])

        self.actual_rate = sample_rate  # Store for later use

        self.stream = self.audio.open(
            format=self.FORMAT,
            channels=self.CHANNELS,
            rate=sample_rate,
            input=True,
            input_device_index=device_index,
            frames_per_buffer=self.CHUNK,
        )

        self.status_label.config(text="Recording...", foreground="red")

        # Start recording thread
        self.record_thread = threading.Thread(target=self.record_audio)
        self.record_thread.start()

        # Start visualization
        self.visualize()

    def record_audio(self):
        """Record audio in background thread"""
        while self.is_recording:
            try:
                data = self.stream.read(self.CHUNK, exception_on_overflow=False)
                self.frames.append(data)

                # Check for silence
                audio_data = np.frombuffer(data, dtype=np.int16)
                amplitude = np.abs(audio_data).mean()

                if amplitude < self.silence_threshold:
                    self.silence_chunks += 1
                else:
                    self.silence_chunks = 0

                # Calculate how many chunks represent the silence duration
                # chunks_per_second = sample_rate / chunk_size
                chunks_per_second = self.actual_rate / self.CHUNK
                required_silent_chunks = int(self.silence_duration * chunks_per_second)

                # Update silence indicator
                current_silence_duration = self.silence_chunks / chunks_per_second
                if self.silence_chunks > 0:
                    # Show silence progress
                    self.root.after(0, lambda: self.silence_label.config(
                        text=f"🔇 Silence: {current_silence_duration:.1f}s / {self.silence_duration}s",
                        foreground="orange"
                    ))
                else:
                    # Show speaking
                    self.root.after(0, lambda: self.silence_label.config(
                        text="🎤 Speaking",
                        foreground="green"
                    ))

                # Auto-stop if silence detected for configured duration
                if self.silence_chunks >= required_silent_chunks:
                    print(f"Silence detected for {self.silence_duration}s, auto-stopping...")
                    self.root.after(0, self.stop_recording)
                    break

            except Exception as e:
                print(f"Recording error: {e}")
                break

    def visualize(self):
        """Draw waveform visualization"""
        if not self.is_recording:
            return

        if self.frames:
            # Get latest chunk
            latest = np.frombuffer(self.frames[-1], dtype=np.int16)

            # Normalize to canvas height
            canvas_height = self.canvas.winfo_height()
            canvas_width = self.canvas.winfo_width()

            if canvas_height > 0:
                normalized = (latest / 32768.0) * (canvas_height / 2)

                # Clear canvas
                self.canvas.delete("all")

                # Draw waveform
                points = []
                step = max(1, len(normalized) // canvas_width)
                for i, val in enumerate(normalized[::step]):
                    x = (i / len(normalized[::step])) * canvas_width
                    y = (canvas_height / 2) + val
                    points.append((x, y))

                if len(points) > 1:
                    self.canvas.create_line(points, fill="green", width=2)

        # Schedule next update
        self.root.after(50, self.visualize)

    def stop_recording(self):
        """Stop recording and transcribe"""
        self.is_recording = False
        self.status_label.config(text="Processing...", foreground="orange")

        if self.stream:
            self.stream.stop_stream()
            self.stream.close()

        # Save to temporary file
        temp_wav = tempfile.NamedTemporaryFile(delete=False, suffix=".wav")
        wf = wave.open(temp_wav.name, "wb")
        wf.setnchannels(self.CHANNELS)
        wf.setsampwidth(self.audio.get_sample_size(self.FORMAT))
        wf.setframerate(self.actual_rate)  # Use actual recording rate
        wf.writeframes(b"".join(self.frames))
        wf.close()

        # Transcribe
        threading.Thread(target=self.transcribe, args=(temp_wav.name,)).start()

    def send_to_daemon(self, audio_file):
        """Send transcription request to daemon"""
        try:
            # Connect to daemon
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.connect(self.daemon_socket)

            # Send request
            request = {
                "command": "transcribe",
                "audio_file": audio_file
            }
            client.sendall((json.dumps(request) + "\n").encode())

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

            response = json.loads(response_data.decode())
            return response

        except Exception as e:
            return {"success": False, "error": f"Daemon communication error: {e}"}

    def transcribe(self, audio_file):
        """Send audio to daemon and handle result"""
        try:
            # Send to daemon
            result = self.send_to_daemon(audio_file)

            if result.get("success"):
                transcription = result.get("transcription", "")

                # Show in GUI
                self.root.after(
                    0,
                    lambda: self.transcription_label.config(
                        text=f"Transcribed: {transcription}", foreground="green"
                    ),
                )

                # Close GUI immediately so it doesn't capture the typed text
                self.root.after(0, self.root.destroy)

                # Wait a bit for GUI to close, then type
                import time
                time.sleep(0.3)

                # Paste to active window
                self.paste_text(transcription)
            else:
                error_msg = result.get("error", "Unknown error")
                self.root.after(
                    0,
                    lambda: self.status_label.config(text=f"Error: {error_msg}", foreground="red"),
                )

        except Exception as e:
            self.root.after(
                0,
                lambda: self.status_label.config(text=f"Error: {e}", foreground="red"),
            )
        finally:
            # Clean up temporary audio file
            try:
                os.unlink(audio_file)
            except:
                pass

    def paste_text(self, text):
        """Type text into active window"""
        # Try ydotool first (Wayland - most reliable)
        if subprocess.run(["which", "ydotool"], capture_output=True).returncode == 0:
            try:
                subprocess.run(
                    ["ydotool", "type", text],
                    check=True,
                    timeout=30,
                    capture_output=True
                )
                return
            except Exception as e:
                print(f"ydotool failed: {e}")

        # Try xdotool (X11)
        if subprocess.run(["which", "xdotool"], capture_output=True).returncode == 0:
            try:
                subprocess.run(["xdotool", "type", "--", text], check=True, timeout=30)
                return
            except Exception as e:
                print(f"xdotool failed: {e}")

        # Try wtype (Wayland - may not work on all compositors)
        if subprocess.run(["which", "wtype"], capture_output=True).returncode == 0:
            try:
                subprocess.run(["wtype", text], check=True, timeout=30)
                return
            except Exception as e:
                print(f"wtype failed: {e}")

        # No tool available
        print(f"No text input tool found. Transcription: {text}")

    def cancel(self):
        """Cancel recording"""
        self.is_recording = False
        if self.stream:
            self.stream.stop_stream()
            self.stream.close()
        self.root.destroy()

    def run(self):
        self.root.mainloop()
        self.audio.terminate()


if __name__ == "__main__":
    app = RecorderGUI()
    app.run()
