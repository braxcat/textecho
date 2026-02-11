#!/usr/bin/env python3
"""
Test script for MLX Whisper transcription on macOS.

Usage:
    # Test with an audio file
    python test_mlx_transcription.py /path/to/audio.wav

    # Test with microphone recording (5 seconds)
    python test_mlx_transcription.py --record

    # Test daemon connection
    python test_mlx_transcription.py --daemon /path/to/audio.wav
"""

import argparse
import json
import os
import socket
import sys
import tempfile
import time


def test_direct_transcription(audio_path: str):
    """Test MLX Whisper directly (no daemon)"""
    print("Testing direct MLX Whisper transcription...")
    print(f"Audio file: {audio_path}")

    try:
        from lightning_whisper_mlx import LightningWhisperMLX
    except ImportError:
        print("Error: lightning-whisper-mlx not installed.")
        print("Install with: pip install lightning-whisper-mlx")
        return False

    print("Loading model (distil-medium.en)...")
    start = time.time()
    whisper = LightningWhisperMLX(model="distil-medium.en", batch_size=12, quant=None)
    print(f"Model loaded in {time.time() - start:.2f}s")

    print("Transcribing...")
    start = time.time()
    result = whisper.transcribe(audio_path=audio_path)
    elapsed = time.time() - start

    text = result.get("text", "").strip()
    print(f"\nTranscription ({elapsed:.2f}s):")
    print(f"  \"{text}\"")
    return True


def test_daemon_transcription(audio_path: str):
    """Test transcription via daemon"""
    socket_path = "/tmp/textecho_transcription.sock"

    if not os.path.exists(socket_path):
        print(f"Error: Daemon socket not found at {socket_path}")
        print("Start the daemon with: python transcription_daemon_mlx.py")
        return False

    print(f"Testing daemon transcription...")
    print(f"Audio file: {audio_path}")

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(socket_path)

        # Send transcribe command
        request = {"command": "transcribe", "audio_file": audio_path}
        sock.sendall((json.dumps(request) + "\n").encode())

        # Receive response
        response = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            response += chunk
            if b"\n" in response:
                break

        sock.close()

        result = json.loads(response.decode().strip())
        if result.get("success"):
            print(f"\nTranscription:")
            print(f"  \"{result.get('transcription', '')}\"")
            return True
        else:
            print(f"Error: {result.get('error')}")
            return False

    except Exception as e:
        print(f"Error connecting to daemon: {e}")
        return False


def test_microphone_recording():
    """Test microphone recording with PyAudio"""
    print("Testing microphone recording (5 seconds)...")

    try:
        import pyaudio
        import numpy as np
        import soundfile as sf
    except ImportError as e:
        print(f"Error: Missing dependency: {e}")
        print("Install with: pip install pyaudio soundfile numpy")
        return None

    RATE = 16000
    CHANNELS = 1
    FORMAT = pyaudio.paInt16
    DURATION = 5

    p = pyaudio.PyAudio()

    # List available input devices
    print("\nAvailable input devices:")
    default_device = None
    for i in range(p.get_device_count()):
        info = p.get_device_info_by_index(i)
        if info["maxInputChannels"] > 0:
            marker = ""
            if info.get("isDefaultInputDevice", False) or i == p.get_default_input_device_info()["index"]:
                marker = " (default)"
                default_device = i
            print(f"  [{i}] {info['name']}{marker}")

    print(f"\nRecording from default device for {DURATION} seconds...")
    print("Speak now!")

    try:
        stream = p.open(
            format=FORMAT,
            channels=CHANNELS,
            rate=RATE,
            input=True,
            frames_per_buffer=1024
        )

        frames = []
        for _ in range(0, int(RATE / 1024 * DURATION)):
            data = stream.read(1024, exception_on_overflow=False)
            frames.append(data)

        stream.stop_stream()
        stream.close()
        p.terminate()

        print("Recording complete.")

        # Save to temp file
        audio_data = b"".join(frames)
        audio_np = np.frombuffer(audio_data, dtype=np.int16).astype(np.float32) / 32768.0

        tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        sf.write(tmp.name, audio_np, RATE)
        print(f"Saved to: {tmp.name}")
        return tmp.name

    except Exception as e:
        print(f"Error recording: {e}")
        p.terminate()
        return None


def main():
    parser = argparse.ArgumentParser(description="Test MLX Whisper transcription")
    parser.add_argument("audio_file", nargs="?", help="Path to audio file")
    parser.add_argument("--record", action="store_true", help="Record from microphone")
    parser.add_argument("--daemon", action="store_true", help="Test via daemon")
    args = parser.parse_args()

    if args.record:
        audio_path = test_microphone_recording()
        if not audio_path:
            sys.exit(1)
    elif args.audio_file:
        audio_path = args.audio_file
        if not os.path.exists(audio_path):
            print(f"Error: File not found: {audio_path}")
            sys.exit(1)
    else:
        parser.print_help()
        sys.exit(1)

    print()
    if args.daemon:
        success = test_daemon_transcription(audio_path)
    else:
        success = test_direct_transcription(audio_path)

    # Clean up temp file if we recorded
    if args.record and audio_path:
        try:
            os.unlink(audio_path)
        except:
            pass

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
