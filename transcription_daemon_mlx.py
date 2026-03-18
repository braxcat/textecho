#!/usr/bin/env python3
"""
Transcription daemon for macOS using mlx-whisper (Apple Silicon optimized)

Uses mlx-whisper for Whisper inference on Apple Silicon via MLX.
Supports large-v3-turbo and large-v3 models from mlx-community on HuggingFace.
"""

import json
import os
import socket
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import soundfile as sf

# mlx-whisper import
try:
    import mlx_whisper
except ImportError as e:
    import traceback
    print("Error: mlx-whisper not installed.")
    print(f"Import error: {e}")
    print("Traceback:")
    traceback.print_exc()
    print("Install with: pip install mlx-whisper")
    sys.exit(1)

# Configuration (can be overridden by command-line args)
DAEMON_MODE = sys.argv[1] if len(sys.argv) > 1 else "single"  # "single", "fast", or "accurate"

if DAEMON_MODE == "fast":
    SOCKET_PATH = "/tmp/textecho_transcription_fast.sock"
    PID_FILE = os.path.expanduser("~/.textecho_transcription_fast.pid")
    LOG_SUFFIX = "_fast"
elif DAEMON_MODE == "accurate":
    SOCKET_PATH = "/tmp/textecho_transcription_accurate.sock"
    PID_FILE = os.path.expanduser("~/.textecho_transcription_accurate.pid")
    LOG_SUFFIX = "_accurate"
else:  # single mode (default)
    SOCKET_PATH = "/tmp/textecho_transcription.sock"
    PID_FILE = os.path.expanduser("~/.textecho_transcription.pid")
    LOG_SUFFIX = ""

CONFIG_FILE = os.path.expanduser("~/.textecho_config")

# mlx-whisper model options (HuggingFace repo IDs from mlx-community)
# large-v3-turbo: 809M params, ~1.6GB RAM, near large-v3 quality at 8x speed
# large-v3: 1.55B params, ~3GB RAM, highest quality
# distil-large-v3: 756M params, ~1.5GB RAM, fast with good quality
DEFAULT_MODELS = {
    "fast": {"model": "mlx-community/whisper-large-v3-turbo"},
    "accurate": {"model": "mlx-community/whisper-large-v3-mlx"},
    "single": {"model": "mlx-community/whisper-large-v3-turbo"},
}


class TranscriptionDaemon:
    def __init__(self):
        self.model_loaded = False
        self.last_request_time = None
        self.unload_timer = None
        self.lock = threading.Lock()
        self._shutdown_flag = False

        # Load config
        self.config = self.load_config()
        self.idle_timeout = self.config.get("model_idle_timeout", 3600)  # Default 1 hour

        # Get model settings based on daemon mode
        mode_defaults = DEFAULT_MODELS.get(DAEMON_MODE, DEFAULT_MODELS["single"])

        # Allow config overrides for model
        if DAEMON_MODE == "fast":
            self.model_repo = self.config.get("mlx_model_fast", mode_defaults["model"])
        elif DAEMON_MODE == "accurate":
            self.model_repo = self.config.get("mlx_model_accurate", mode_defaults["model"])
        else:
            self.model_repo = self.config.get("mlx_model", mode_defaults["model"])

        # Language setting (None = auto-detect, "en" = force English)
        self.language = self.config.get("language", None)

        # Preload model option
        self.preload_model = self.config.get("preload_transcription_model", False)

        print(f"Transcription daemon initialized (mode: {DAEMON_MODE.upper()}, backend: mlx-whisper)")
        print(f"Model: {self.model_repo}")
        print(f"Model idle timeout: {self.idle_timeout}s ({self.idle_timeout / 60:.1f} minutes)")

        # Preload model if configured — mlx_whisper downloads and caches on first call,
        # so we do a dummy transcribe to warm the cache
        if self.preload_model:
            print("Preloading model at startup...")
            self._preload_model()

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

    def _preload_model(self):
        """Preload model by running a short dummy transcription."""
        with self.lock:
            if self.model_loaded:
                return
            print("Downloading/loading MLX Whisper model...")
            start_time = time.time()
            try:
                # Generate a short silent WAV to trigger model download/load
                with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                    tmp_path = tmp.name
                    silence = np.zeros(16000, dtype=np.float32)  # 1 second of silence
                    sf.write(tmp_path, silence, 16000)
                try:
                    kwargs = {"path_or_hf_repo": self.model_repo}
                    if self.language:
                        kwargs["language"] = self.language
                    mlx_whisper.transcribe(tmp_path, **kwargs)
                finally:
                    os.unlink(tmp_path)
                self.model_loaded = True
                elapsed = time.time() - start_time
                print(f"Model loaded successfully in {elapsed:.2f}s")
            except Exception as e:
                print(f"Error preloading model: {e}")

    def unload_model(self):
        """Mark model as unloaded. mlx-whisper manages its own caching,
        but we track load state for status reporting."""
        with self.lock:
            if not self.model_loaded:
                return
            print("Marking model as idle (mlx-whisper manages memory internally)")
            self.model_loaded = False

    def reset_unload_timer(self):
        """Reset the auto-unload timer"""
        if self.unload_timer:
            self.unload_timer.cancel()

        self.unload_timer = threading.Timer(self.idle_timeout, self.unload_model)
        self.unload_timer.daemon = True
        self.unload_timer.start()

    def _transcribe_file(self, audio_path):
        """Run mlx_whisper.transcribe on an audio file."""
        kwargs = {"path_or_hf_repo": self.model_repo}
        if self.language:
            kwargs["language"] = self.language
        result = mlx_whisper.transcribe(audio_path, **kwargs)
        self.model_loaded = True
        return result.get("text", "").strip()

    def transcribe(self, audio_file):
        """Transcribe audio file"""
        try:
            with self.lock:
                if self.unload_timer:
                    self.unload_timer.cancel()
                transcription = self._transcribe_file(audio_file)

            self.last_request_time = time.time()
            self.reset_unload_timer()
            return {"success": True, "transcription": transcription}

        except Exception as e:
            return {"success": False, "error": str(e)}

    # Known Whisper hallucination phrases (lowercased).
    # These appear when the model is fed silence or noise.
    HALLUCINATION_PHRASES = {
        "you're going to be",
        "you're going to",
        "you're",
        "thank you",
        "thanks for watching",
        "thank you for watching",
        "please subscribe",
        "like and subscribe",
        "the end",
        "bye",
        "goodbye",
        "subtitles by",
        "translated by",
        "amara.org",
        "www.mooji.org",
        "moffatts",
    }

    # Minimum RMS energy to attempt transcription (below this = silence)
    SILENCE_RMS_THRESHOLD = 0.005

    def _is_hallucination(self, text):
        """Detect Whisper hallucination patterns."""
        if not text:
            return True

        cleaned = text.strip().rstrip(".!?,").lower()

        # Check against known hallucination phrases
        if cleaned in self.HALLUCINATION_PHRASES:
            return True

        # Detect repeated segments: "Hello. Hello. Hello." → hallucination
        # Split on sentence boundaries and check for repetition
        import re
        segments = [s.strip() for s in re.split(r'[.!?]+', cleaned) if s.strip()]
        if len(segments) >= 2:
            unique = set(segments)
            if len(unique) == 1:
                return True
            # Mostly repeated (e.g. 4 out of 5 segments identical)
            if len(segments) >= 3:
                from collections import Counter
                most_common_count = Counter(segments).most_common(1)[0][1]
                if most_common_count / len(segments) >= 0.7:
                    return True

        return False

    def _audio_rms(self, float_data):
        """Compute RMS energy of float32 audio data."""
        if len(float_data) == 0:
            return 0.0
        return float(np.sqrt(np.mean(float_data ** 2)))

    def transcribe_raw(self, audio_data, sample_rate):
        """Transcribe raw audio data (write to temp file for mlx-whisper)"""
        try:
            # Convert bytes to numpy array
            data = np.frombuffer(audio_data, dtype=np.int16).astype(np.float32) / 32768.0

            # Skip transcription if audio is too quiet (silence/noise)
            rms = self._audio_rms(data)
            if rms < self.SILENCE_RMS_THRESHOLD:
                print(f"Skipping transcription: audio too quiet (RMS={rms:.6f})")
                return {"success": True, "transcription": ""}

            # Resample if needed (Whisper expects 16kHz)
            if sample_rate != 16000:
                ratio = 16000 / sample_rate
                new_length = int(len(data) * ratio)
                data = np.interp(
                    np.linspace(0, len(data), new_length), np.arange(len(data)), data
                )

            # Write to temporary file (mlx-whisper API uses file paths)
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                tmp_path = tmp.name
                sf.write(tmp_path, data, 16000)

            try:
                with self.lock:
                    if self.unload_timer:
                        self.unload_timer.cancel()
                    transcription = self._transcribe_file(tmp_path)

                # Filter hallucinated output
                if self._is_hallucination(transcription):
                    print(f"Filtered hallucination: \"{transcription}\"")
                    transcription = ""

                self.last_request_time = time.time()
                self.reset_unload_timer()
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
                    "backend": "mlx-whisper",
                    "model": self.model_repo,
                }
                response = json.dumps(status) + "\n"
                conn.sendall(response.encode())

            elif command == "preload":
                self._preload_model()
                response = json.dumps({"success": True, "model_loaded": self.model_loaded}) + "\n"
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
        # Handle SIGTERM gracefully (launchd sends this on stop)
        import signal

        def _shutdown(signum, frame):
            print(f"\nReceived signal {signum}, shutting down...")
            self._shutdown_flag = True

        signal.signal(signal.SIGTERM, _shutdown)

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
        server.settimeout(1.0)

        # Write PID file
        with open(PID_FILE, "w") as f:
            f.write(str(os.getpid()))

        print(f"Transcription daemon (mlx-whisper) listening on {SOCKET_PATH}")
        print(f"PID: {os.getpid()}")

        # Use thread pool to limit concurrent connections
        executor = ThreadPoolExecutor(max_workers=4)

        try:
            while not self._shutdown_flag:
                try:
                    conn, _ = server.accept()
                    executor.submit(self.handle_client, conn)
                except socket.timeout:
                    continue
        except KeyboardInterrupt:
            print("\nShutting down...")
        finally:
            executor.shutdown(wait=True, cancel_futures=True)
            server.close()
            try:
                os.unlink(SOCKET_PATH)
            except OSError:
                pass
            try:
                os.unlink(PID_FILE)
            except OSError:
                pass


if __name__ == "__main__":
    daemon = TranscriptionDaemon()
    daemon.run()
