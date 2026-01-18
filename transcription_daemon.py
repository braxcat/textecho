#!/usr/bin/env python3
"""
Transcription daemon that keeps Whisper model in memory with auto-unload
"""

import json
import os
import socket
import sys
import threading
import time
import warnings
from pathlib import Path

import numpy as np
import openvino_genai as ov_genai
import soundfile as sf

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
else:  # single mode (legacy)
    SOCKET_PATH = "/tmp/dictation_transcription.sock"
    PID_FILE = os.path.expanduser("~/.dictation_transcription.pid")
    LOG_SUFFIX = ""

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
        self.idle_timeout = self.config.get(
            "model_idle_timeout", 3600
        )  # Default 1 hour

        # Determine model/device based on daemon mode
        if DAEMON_MODE == "fast":
            self.device = self.config.get("transcription_device_fast", "NPU")
            self.model_path = self.config.get("transcription_model_fast", "./whisper-base-npu")
        elif DAEMON_MODE == "accurate":
            self.device = self.config.get("transcription_device_accurate", "NPU")
            self.model_path = self.config.get("transcription_model_accurate", "./whisper-small-npu")
        else:  # single mode (legacy)
            self.device = self.config.get("transcription_device", "CPU")
            self.model_path = self.config.get("model_path", "./whisper-base-cpu")

        # Transcription quality parameters (all optional, for accent optimization)
        self.num_beams = self.config.get(
            "num_beams", None
        )  # None = greedy (default), 5 = beam search
        self.temperature = self.config.get(
            "temperature", None
        )  # None = default, 0.0 = deterministic
        self.repetition_penalty = self.config.get(
            "repetition_penalty", None
        )  # None = default, >1.0 reduces repetition
        self.length_penalty = self.config.get(
            "length_penalty", None
        )  # None = default, >0 favors longer outputs
        self.language = self.config.get(
            "language", None
        )  # None = auto-detect, "en" = force English
        self.task = self.config.get(
            "task", None
        )  # None = default, "transcribe" or "translate"
        self.initial_prompt = self.config.get(
            "initial_prompt", None
        )  # Hint for style/spelling
        self.hotwords = self.config.get(
            "hotwords", None
        )  # Words to favor (space-separated)

        # Preload model option (load at startup instead of on first use)
        self.preload_model = self.config.get("preload_transcription_model", False)

        print(f"Transcription daemon initialized (mode: {DAEMON_MODE.upper()})")
        print(
            f"Model idle timeout: {self.idle_timeout}s ({self.idle_timeout / 60:.1f} minutes)"
        )
        print(f"Device: {self.device}")
        print(f"Model path: {self.model_path}")

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
            warnings.filterwarnings(
                "ignore", message="Whisper decoder models with past is deprecated"
            )

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
                data = np.interp(
                    np.linspace(0, len(data), new_length), np.arange(len(data)), data
                )

            # Generate transcription
            with self.lock:
                # Build generate kwargs from config
                kwargs = {"max_new_tokens": 100}
                if self.num_beams:
                    kwargs["num_beams"] = self.num_beams
                if self.temperature is not None:
                    kwargs["temperature"] = self.temperature
                if self.repetition_penalty:
                    kwargs["repetition_penalty"] = self.repetition_penalty
                if self.length_penalty is not None:
                    kwargs["length_penalty"] = self.length_penalty
                if self.language:
                    kwargs["language"] = self.language
                if self.task:
                    kwargs["task"] = self.task
                if self.initial_prompt:
                    kwargs["initial_prompt"] = self.initial_prompt
                if self.hotwords:
                    kwargs["hotwords"] = self.hotwords

                print(f"[DEBUG] Calling model.generate() with kwargs: {kwargs}")
                result = self.model.generate(data.tolist(), **kwargs)
                print(f"[DEBUG] generate() returned: {type(result)}")

                # Extract text from WhisperDecodedResults object
                if hasattr(result, "texts"):
                    # Result has multiple texts, join them
                    transcription = " ".join(result.texts)
                elif hasattr(result, "text"):
                    # Result has single text attribute
                    transcription = result.text
                else:
                    # Fall back to string conversion
                    transcription = str(result)

            return {"success": True, "transcription": transcription}

        except Exception as e:
            return {"success": False, "error": str(e)}

    def transcribe_raw(self, audio_data, sample_rate):
        """Transcribe raw audio data (no disk I/O)"""
        try:
            # Load model if not loaded
            if not self.model_loaded:
                self.load_model()

            # Update last request time and reset unload timer
            self.last_request_time = time.time()
            self.reset_unload_timer()

            # Convert bytes to numpy array
            data = np.frombuffer(audio_data, dtype=np.int16).astype(np.float32) / 32768.0

            # Resample if needed
            if sample_rate != 16000:
                ratio = 16000 / sample_rate
                new_length = int(len(data) * ratio)
                data = np.interp(
                    np.linspace(0, len(data), new_length), np.arange(len(data)), data
                )

            # Generate transcription
            with self.lock:
                # Build generate kwargs from config
                kwargs = {"max_new_tokens": 100}
                if self.num_beams:
                    kwargs["num_beams"] = self.num_beams
                if self.temperature is not None:
                    kwargs["temperature"] = self.temperature
                if self.repetition_penalty:
                    kwargs["repetition_penalty"] = self.repetition_penalty
                if self.length_penalty is not None:
                    kwargs["length_penalty"] = self.length_penalty
                if self.language:
                    kwargs["language"] = self.language
                if self.task:
                    kwargs["task"] = self.task
                if self.initial_prompt:
                    kwargs["initial_prompt"] = self.initial_prompt
                if self.hotwords:
                    kwargs["hotwords"] = self.hotwords

                print(f"[DEBUG] Calling model.generate() with kwargs: {kwargs}")
                result = self.model.generate(data.tolist(), **kwargs)
                print(f"[DEBUG] generate() returned: {type(result)}")

                # Extract text from WhisperDecodedResults object
                if hasattr(result, "texts"):
                    # Result has multiple texts, join them
                    transcription = " ".join(result.texts)
                elif hasattr(result, "text"):
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
            # Receive request header (JSON until newline)
            data = b""
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
                if b"\n" in data:  # Use newline as message delimiter
                    break

            if not data:
                return

            # Split at newline - only decode the JSON part
            json_end = data.index(b"\n")
            json_bytes = data[:json_end]
            extra_bytes = data[json_end + 1:]  # Any audio data that came with the header

            request = json.loads(json_bytes.decode())
            command = request.get("command")

            if command == "transcribe":
                audio_file = request.get("audio_file")
                result = self.transcribe(audio_file)
                response = json.dumps(result) + "\n"
                conn.sendall(response.encode())

            elif command == "transcribe_raw":
                # Receive raw audio data (no disk I/O)
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
                    result = {"success": False, "error": f"Incomplete audio data: expected {data_length}, got {len(audio_data)}"}
                else:
                    result = self.transcribe_raw(audio_data, sample_rate)

                response = json.dumps(result) + "\n"
                conn.sendall(response.encode())

            elif command == "status":
                status = {
                    "model_loaded": self.model_loaded,
                    "last_request": self.last_request_time,
                    "idle_timeout": self.idle_timeout,
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
                client_thread = threading.Thread(
                    target=self.handle_client, args=(conn,)
                )
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
