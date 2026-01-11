#!/usr/bin/env python3
"""
Transcription daemon that keeps Whisper model in memory with auto-unload
"""

import json
import os
import socket
import threading
import time
import warnings
from pathlib import Path

import numpy as np
import openvino_genai as ov_genai
import soundfile as sf

# Configuration
SOCKET_PATH = "/tmp/dictation_transcription.sock"
PID_FILE = os.path.expanduser("~/.dictation_transcription.pid")
CONFIG_FILE = os.path.expanduser("~/.dictation_config")


class TranscriptionDaemon:
    def __init__(self):
        self.model = None
        self.model_loaded = False
        self.last_request_time = None
        self.unload_timer = None
        self.lock = threading.Lock()

        # Load config
        self.config = self.load_config()
        self.idle_timeout = self.config.get("model_idle_timeout", 3600)  # Default 1 hour
        self.device = self.config.get("transcription_device", "CPU")
        self.model_path = self.config.get("model_path", "./whisper-base-cpu")

        print(f"Transcription daemon initialized")
        print(f"Model idle timeout: {self.idle_timeout}s ({self.idle_timeout/60:.1f} minutes)")
        print(f"Device: {self.device}")
        print(f"Model path: {self.model_path}")

    def load_config(self):
        """Load configuration from file"""
        if os.path.exists(CONFIG_FILE):
            try:
                with open(CONFIG_FILE, "r") as f:
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

    def load_model(self):
        """Load Whisper model into memory"""
        with self.lock:
            if self.model_loaded:
                return

            print("Loading Whisper model...")
            start_time = time.time()

            # Suppress deprecation warnings
            warnings.filterwarnings('ignore', message='Whisper decoder models with past is deprecated')

            try:
                self.model = ov_genai.WhisperPipeline(self.model_path, self.device)
                self.model_loaded = True
                elapsed = time.time() - start_time
                print(f"Model loaded successfully in {elapsed:.2f}s")
            except Exception as e:
                print(f"Error loading model: {e}")
                raise

    def unload_model(self):
        """Unload model from memory to free RAM"""
        with self.lock:
            if not self.model_loaded:
                return

            print("Unloading model to free RAM...")
            self.model = None
            self.model_loaded = False
            print("Model unloaded")

    def reset_unload_timer(self):
        """Reset the auto-unload timer"""
        # Cancel existing timer
        if self.unload_timer:
            self.unload_timer.cancel()

        # Start new timer
        self.unload_timer = threading.Timer(self.idle_timeout, self.unload_model)
        self.unload_timer.daemon = True
        self.unload_timer.start()

    def transcribe(self, audio_file):
        """Transcribe audio file"""
        try:
            # Load model if not loaded
            if not self.model_loaded:
                self.load_model()

            # Update last request time and reset unload timer
            self.last_request_time = time.time()
            self.reset_unload_timer()

            # Read and resample audio if needed
            data, samplerate = sf.read(audio_file)
            if samplerate != 16000:
                ratio = 16000 / samplerate
                new_length = int(len(data) * ratio)
                data = np.interp(np.linspace(0, len(data), new_length), np.arange(len(data)), data)

            # Generate transcription
            with self.lock:
                result = self.model.generate(data.tolist(), max_new_tokens=100)

                # Extract text from WhisperDecodedResults object
                if hasattr(result, 'texts'):
                    # Result has multiple texts, join them
                    transcription = ' '.join(result.texts)
                elif hasattr(result, 'text'):
                    # Result has single text attribute
                    transcription = result.text
                else:
                    # Fall back to string conversion
                    transcription = str(result)

            return {"success": True, "transcription": transcription}

        except Exception as e:
            return {"success": False, "error": str(e)}

    def handle_client(self, conn):
        """Handle client connection"""
        try:
            # Receive request
            data = b""
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
                if b"\n" in chunk:  # Use newline as message delimiter
                    break

            if not data:
                return

            request = json.loads(data.decode())
            command = request.get("command")

            if command == "transcribe":
                audio_file = request.get("audio_file")
                result = self.transcribe(audio_file)
                response = json.dumps(result) + "\n"
                conn.sendall(response.encode())

            elif command == "status":
                status = {
                    "model_loaded": self.model_loaded,
                    "last_request": self.last_request_time,
                    "idle_timeout": self.idle_timeout
                }
                response = json.dumps(status) + "\n"
                conn.sendall(response.encode())

            elif command == "unload":
                self.unload_model()
                response = json.dumps({"success": True}) + "\n"
                conn.sendall(response.encode())

        except Exception as e:
            print(f"Error handling client: {e}")
            try:
                error_response = json.dumps({"success": False, "error": str(e)}) + "\n"
                conn.sendall(error_response.encode())
            except:
                pass
        finally:
            conn.close()

    def run(self):
        """Run the daemon server"""
        # Remove old socket if exists
        try:
            os.unlink(SOCKET_PATH)
        except OSError:
            if os.path.exists(SOCKET_PATH):
                raise

        # Create Unix domain socket
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(SOCKET_PATH)
        server.listen(5)

        # Write PID file
        with open(PID_FILE, "w") as f:
            f.write(str(os.getpid()))

        print(f"Transcription daemon listening on {SOCKET_PATH}")
        print(f"PID: {os.getpid()}")

        try:
            while True:
                conn, _ = server.accept()
                # Handle each client in a thread
                client_thread = threading.Thread(target=self.handle_client, args=(conn,))
                client_thread.daemon = True
                client_thread.start()
        except KeyboardInterrupt:
            print("\nShutting down...")
        finally:
            server.close()
            os.unlink(SOCKET_PATH)
            os.unlink(PID_FILE)


if __name__ == "__main__":
    daemon = TranscriptionDaemon()
    daemon.run()
