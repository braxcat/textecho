#!/usr/bin/env python3
"""
Python wrapper for the Swift-based overlay helper.

Communicates with DictationOverlayHelper via stdin/stdout JSON commands.
All methods are thread-safe and can be called from any thread.
"""

import json
import os
import subprocess
import threading
from pathlib import Path
from typing import Optional


class SwiftOverlay:
    """
    Thread-safe wrapper for the Swift overlay helper.

    Usage:
        overlay = SwiftOverlay()
        overlay.start()

        # From any thread:
        overlay.show_recording()
        overlay.show_processing()
        overlay.show_result("Hello world", is_llm=False)
        overlay.hide()

        # When done:
        overlay.stop()
    """

    def __init__(self, helper_path: Optional[str] = None):
        """
        Initialize the overlay wrapper.

        Args:
            helper_path: Path to DictationOverlayHelper binary.
                        Defaults to DictationOverlay/DictationOverlayHelper in same dir.
                        Falls back to .app bundle Resources path if running frozen.
        """
        if helper_path is None:
            helper_path = self._find_helper()

        self.helper_path = Path(helper_path)
        self.process: Optional[subprocess.Popen] = None
        self._lock = threading.Lock()
        self._started = False

    @staticmethod
    def _find_helper() -> Path:
        """Locate DictationOverlayHelper, checking source dir and .app bundle."""
        import sys

        # Source tree layout
        script_dir = Path(__file__).parent
        source_path = script_dir / "DictationOverlay" / "DictationOverlayHelper"
        if source_path.exists():
            return source_path

        # .app bundle layout: Contents/Resources/DictationOverlay/DictationOverlayHelper
        if getattr(sys, 'frozen', False):
            bundle_resources = Path(sys.executable).parent.parent / "Resources"
            bundle_path = bundle_resources / "DictationOverlay" / "DictationOverlayHelper"
            if bundle_path.exists():
                return bundle_path

        # Fallback — return source path even if it doesn't exist (will fail at start())
        return source_path

    def start(self) -> bool:
        """
        Start the overlay helper process.

        Returns:
            True if started successfully, False otherwise.
        """
        with self._lock:
            if self._started:
                return True

            if not self.helper_path.exists():
                print(f"Overlay helper not found: {self.helper_path}")
                return False

            try:
                self.process = subprocess.Popen(
                    [str(self.helper_path)],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    bufsize=1  # Line buffered
                )

                # Wait for READY signal
                ready = self.process.stdout.readline().strip()
                if ready != "READY":
                    print(f"Unexpected startup response: {ready}")
                    self._cleanup_process()
                    return False

                self._started = True
                print("Overlay helper started")
                return True

            except Exception as e:
                print(f"Failed to start overlay helper: {e}")
                self._cleanup_process()
                return False

    def _cleanup_process(self):
        """Clean up subprocess and close all pipes."""
        if self.process:
            try:
                self.process.terminate()
            except Exception:
                pass
            # Close all pipes to avoid file descriptor leaks
            for pipe in [self.process.stdin, self.process.stdout, self.process.stderr]:
                if pipe:
                    try:
                        pipe.close()
                    except Exception:
                        pass
            try:
                self.process.wait(timeout=1)
            except Exception:
                try:
                    self.process.kill()
                except Exception:
                    pass
            self.process = None

    def stop(self):
        """Stop the overlay helper process."""
        with self._lock:
            if self.process:
                self._send_command({"action": "quit"})
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                # Close all pipes
                for pipe in [self.process.stdin, self.process.stdout, self.process.stderr]:
                    if pipe:
                        try:
                            pipe.close()
                        except Exception:
                            pass
                self.process = None
            self._started = False

    def _send_command(self, command: dict):
        """Send a command to the helper (internal, must hold lock or be thread-safe)."""
        if not self.process or self.process.poll() is not None:
            return

        try:
            json_str = json.dumps(command)
            self.process.stdin.write(json_str + "\n")
            self.process.stdin.flush()
        except (BrokenPipeError, OSError) as e:
            print(f"Failed to send overlay command: {e}")

    def _send(self, command: dict):
        """Thread-safe command sending."""
        with self._lock:
            if self._started:
                self._send_command(command)

    # Public API - all thread-safe

    def show_recording(self):
        """Show recording state."""
        self._send({"action": "show_recording"})

    def show_processing(self):
        """Show processing state."""
        self._send({"action": "show_processing"})

    def show_result(self, text: str, is_llm: bool = False):
        """Show transcription/LLM result."""
        self._send({"action": "show_result", "text": text, "isLLM": is_llm})

    def show_error(self, message: str):
        """Show error message."""
        self._send({"action": "show_error", "text": message})

    def hide(self):
        """Hide the overlay."""
        self._send({"action": "hide"})

    def update_position(self):
        """Update overlay position to follow cursor."""
        self._send({"action": "update_position"})

    def update_waveform(self, levels: list):
        """Update waveform visualization with audio levels (0.0 to 1.0)."""
        self._send({"action": "update_waveform", "levels": levels})

    # Aliases for compatibility with old overlay API
    schedule_show_recording = show_recording
    schedule_show_processing = show_processing
    schedule_show_result = show_result
    schedule_show_error = show_error
    schedule_hide = hide
    schedule_update_position = update_position

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.stop()
        return False


def test_overlay():
    """Test the Swift overlay."""
    import time
    import math
    import random

    print("=" * 50)
    print("Testing Swift Overlay")
    print("=" * 50)
    print()

    overlay = SwiftOverlay()

    if not overlay.start():
        print("Failed to start overlay!")
        return

    print("Showing recording state with waveform...")
    overlay.show_recording()

    # Simulate waveform for 3 seconds
    levels = [0.05] * 40
    for i in range(60):  # 60 frames at 50ms = 3 seconds
        # Generate simulated audio level (sine wave + noise for realistic look)
        level = 0.3 + 0.3 * math.sin(i * 0.3) + random.random() * 0.3
        level = max(0.05, min(level, 1.0))

        levels.pop(0)
        levels.append(level)
        overlay.update_waveform(levels)
        time.sleep(0.05)

    print("Showing processing state...")
    overlay.show_processing()
    time.sleep(1)

    print("Showing result...")
    overlay.show_result("Hello! This is a test transcription from the Swift overlay.", is_llm=False)
    time.sleep(2)

    print("Showing LLM result...")
    overlay.show_result("This is an LLM response with some helpful information.", is_llm=True)
    time.sleep(2)

    print("Showing error...")
    overlay.show_error("Test error message")
    time.sleep(2)

    print("Hiding overlay...")
    overlay.hide()
    time.sleep(1)

    print("Stopping overlay...")
    overlay.stop()

    print()
    print("=" * 50)
    print("SUCCESS!")
    print("=" * 50)


if __name__ == "__main__":
    test_overlay()
