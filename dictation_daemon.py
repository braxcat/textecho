#!/usr/bin/env python3
"""
Dictation hotkey daemon - listens for Ctrl+Shift+Space
"""

import os
import signal
import subprocess
import sys

from pynput import keyboard

# PID file for tracking
PID_FILE = os.path.expanduser("~/.dictation_daemon.pid")

HOTKEY = {keyboard.Key.ctrl, keyboard.Key.alt, keyboard.KeyCode.from_char(" ")}
current_keys = set()


def cleanup(signum=None, frame=None):
    """Clean up PID file on exit"""
    if os.path.exists(PID_FILE):
        os.remove(PID_FILE)
    print("\nDictation daemon stopped.")
    sys.exit(0)


def check_already_running():
    """Check if daemon is already running"""
    if os.path.exists(PID_FILE):
        with open(PID_FILE, "r") as f:
            old_pid = int(f.read().strip())

        # Check if process is actually running
        try:
            os.kill(old_pid, 0)  # Signal 0 just checks existence
            print(f"Daemon already running (PID {old_pid})")
            print(f"Run: kill {old_pid} to stop it")
            sys.exit(1)
        except OSError:
            # Process not running, remove stale PID file
            os.remove(PID_FILE)


def write_pid():
    """Write current PID to file"""
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))


def on_press(key):
    current_keys.add(key)

    if HOTKEY.issubset(current_keys):
        print("Hotkey triggered! Starting recording...")
        # Launch the recorder GUI
        script_dir = os.path.dirname(os.path.abspath(__file__))
        log_file = os.path.expanduser("~/.dictation_gui.log")
        with open(log_file, "a") as log:
            log.write(f"\n--- GUI launched at {subprocess.check_output(['date']).decode().strip()} ---\n")
            subprocess.Popen(
                ["uv", "run", "python", "recorder_gui.py"],
                cwd=script_dir,
                stdout=log,
                stderr=subprocess.STDOUT
            )


def on_release(key):
    try:
        current_keys.remove(key)
    except KeyError:
        pass


if __name__ == "__main__":
    # Register signal handlers
    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    # Check if already running
    check_already_running()

    # Write PID file
    write_pid()

    print("Dictation daemon running. Press Ctrl+Alt+Space to record.")
    print(f"PID: {os.getpid()}")
    print("Press Ctrl+C to quit.")

    try:
        with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
            listener.join()
    finally:
        cleanup()
