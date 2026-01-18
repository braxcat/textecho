#!/usr/bin/env python3
"""
Transcription daemon for macOS using MLX Whisper (Apple Silicon optimized)

Replaces OpenVINO-based transcription_daemon.py for macOS.
Uses lightning-whisper-mlx for fast Whisper inference on Apple Silicon.
"""

import json
import os
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path

import numpy as np
import soundfile as sf

# MLX Whisper import - will fail on non-macOS or without the package
try:
    from lightning_whisper_mlx import LightningWhisperMLX
except ImportError:
    print("Error: lightning-whisper-mlx not installed.")
    print("Install with: pip install lightning-whisper-mlx")
    sys.exit(1)

# Configuration (can be overridden by command-line args)
DAEMON_MODE = sys.argv[1] if len(sys.argv) > 1 else "single"  # "single", "fast", or "accurate"

if DAEMON_MODE == "fast":
    SOCKET_PATH = "/tmp/dictation_transcription_fast.sock"
    PID_FILE = os.path.expanduser("~/.dictation_transcription_fast.pid")
    LOG_SUFFIX = "_fast"
elif DAEMON_MODE == "accurate":
    SOCKET_PATH = "/tmp/dictation_transcription_accurate.sock"
    PID_FILE = os.path.expanduser("~/.dictation_transcription_accurate.pid")
    LOG_SUFFIX = "_accurate"
else:  # single mode (default)
    SOCKET_PATH = "/tmp/dictation_transcription.sock"
    PID_FILE = os.path.expanduser("~/.dictation_transcription.pid")
    LOG_SUFFIX = ""

CONFIG_FILE = os.path.expanduser("~/.dictation_config")

# MLX Whisper model options
# Models: "tiny", "base", "small", "medium", "large-v3", "distil-medium.en", "distil-large-v3"
# Quantization: None, "4bit", "8bit"
DEFAULT_MODELS = {
    "fast": {"model": "distil-medium.en", "batch_size": 12, "quant": "4bit"},
    "accurate": {"model": "distil-large-v3", "batch_size": 6, "quant": None},
    "single": {"model": "distil-medium.en", "batch_size": 12, "quant": None},
}


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

        # Get model settings based on daemon mode
        mode_defaults = DEFAULT_MODELS.get(DAEMON_MODE, DEFAULT_MODELS["single"])

        # Allow config overrides for MLX-specific settings
        if DAEMON_MODE == "fast":
            self.model_name = self.config.get("mlx_model_fast", mode_defaults["model"])
            self.batch_size = self.config.get("mlx_batch_size_fast", mode_defaults["batch_size"])
            self.quant = self.config.get("mlx_quant_fast", mode_defaults["quant"])
        elif DAEMON_MODE == "accurate":
            self.model_name = self.config.get("mlx_model_accurate", mode_defaults["model"])
            self.batch_size = self.config.get("mlx_batch_size_accurate", mode_defaults["batch_size"])
            self.quant = self.config.get("mlx_quant_accurate", mode_defaults["quant"])
        else:
            self.model_name = self.config.get("mlx_model", mode_defaults["model"])
            self.batch_size = self.config.get("mlx_batch_size", mode_defaults["batch_size"])
            self.quant = self.config.get("mlx_quant", mode_defaults["quant"])

        # Language setting (None = auto-detect, "en" = force English)
        self.language = self.config.get("language", None)

        # Preload model option
        self.preload_model = self.config.get("preload_transcription_model", False)

        print(f"Transcription daemon initialized (mode: {DAEMON_MODE.upper()}, backend: MLX)")
        print(f"Model: {self.model_name}, Batch size: {self.batch_size}, Quantization: {self.quant}")
        print(f"Model idle timeout: {self.idle_timeout}s ({self.idle_timeout / 60:.1f} minutes)")

        # Preload model if configured
        if self.preload_model:
            print("Preloading model at startup...")
            self.load_model()

    def load_config(self):
        """Load configuration from file"""
        if os.path.exists(CONFIG_FILE):
            try:
                with open(CONFIG_FILE, "r") as f:
                    config = json.load(f)
                    if isinstance(config, dict):
                        return config
            except Exception as e:
                print(f"Warning: Could not load config: {e}")
        return {}

    def load_model(self):
        """Load Whisper model into memory"""
        with self.lock:
            if self.model_loaded:
                return

            print("Loading MLX Whisper model...")
            start_time = time.time()

            try:
                self.model = LightningWhisperMLX(
                    model=self.model_name,
                    batch_size=self.batch_size,
                    quant=self.quant
                )
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
        if self.unload_timer:
            self.unload_timer.cancel()

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

            # Transcribe using MLX Whisper
            with self.lock:
                result = self.model.transcribe(audio_path=audio_file)
                transcription = result.get("text", "").strip()

            return {"success": True, "transcription": transcription}

        except Exception as e:
            return {"success": False, "error": str(e)}

    def transcribe_raw(self, audio_data, sample_rate):
        """Transcribe raw audio data (write to temp file for MLX)"""
        try:
            # Load model if not loaded
            if not self.model_loaded:
                self.load_model()

            # Update last request time and reset unload timer
            self.last_request_time = time.time()
            self.reset_unload_timer()

            # Convert bytes to numpy array
            data = np.frombuffer(audio_data, dtype=np.int16).astype(np.float32) / 32768.0

            # Resample if needed (MLX Whisper expects 16kHz)
            if sample_rate != 16000:
                ratio = 16000 / sample_rate
                new_length = int(len(data) * ratio)
                data = np.interp(
                    np.linspace(0, len(data), new_length), np.arange(len(data)), data
                )

            # Write to temporary file (MLX Whisper API uses file paths)
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                tmp_path = tmp.name
                sf.write(tmp_path, data, 16000)

            try:
                # Transcribe using MLX Whisper
                with self.lock:
                    result = self.model.transcribe(audio_path=tmp_path)
                    transcription = result.get("text", "").strip()

                return {"success": True, "transcription": transcription}
            finally:
                # Clean up temp file
                try:
                    os.unlink(tmp_path)
                except:
                    pass

        except Exception as e:
            return {"success": False, "error": str(e)}

    def handle_client(self, conn):
        """Handle client connection"""
        try:
            # Receive request header (JSON until newline)
            data = b""
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
                if b"\n" in data:
                    break

            if not data:
                return

            # Split at newline - only decode the JSON part
            json_end = data.index(b"\n")
            json_bytes = data[:json_end]
            extra_bytes = data[json_end + 1:]

            request = json.loads(json_bytes.decode())
            command = request.get("command")

            if command == "transcribe":
                audio_file = request.get("audio_file")
                result = self.transcribe(audio_file)
                response = json.dumps(result) + "\n"
                conn.sendall(response.encode())

            elif command == "transcribe_raw":
                sample_rate = request.get("sample_rate")
                data_length = request.get("data_length")

                # Start with any extra bytes that came with the header
                audio_data = extra_bytes
                remaining = data_length - len(audio_data)

                # Receive the rest of the audio data
                while remaining > 0:
                    chunk = conn.recv(min(remaining, 65536))
                    if not chunk:
                        break
                    audio_data += chunk
                    remaining -= len(chunk)

                if len(audio_data) != data_length:
                    result = {
                        "success": False,
                        "error": f"Incomplete audio data: expected {data_length}, got {len(audio_data)}"
                    }
                else:
                    result = self.transcribe_raw(audio_data, sample_rate)

                response = json.dumps(result) + "\n"
                conn.sendall(response.encode())

            elif command == "status":
                status = {
                    "model_loaded": self.model_loaded,
                    "last_request": self.last_request_time,
                    "idle_timeout": self.idle_timeout,
                    "backend": "mlx",
                    "model": self.model_name,
                    "quant": self.quant,
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

        print(f"Transcription daemon (MLX) listening on {SOCKET_PATH}")
        print(f"PID: {os.getpid()}")

        try:
            while True:
                conn, _ = server.accept()
                client_thread = threading.Thread(
                    target=self.handle_client, args=(conn,)
                )
                client_thread.daemon = True
                client_thread.start()
        except KeyboardInterrupt:
            print("\nShutting down...")
        finally:
            server.close()
            try:
                os.unlink(SOCKET_PATH)
            except:
                pass
            try:
                os.unlink(PID_FILE)
            except:
                pass


if __name__ == "__main__":
    daemon = TranscriptionDaemon()
    daemon.run()
