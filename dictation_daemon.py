#!/usr/bin/env python3
"""
Dictation hotkey daemon - listens for Mouse 4 (side button) using evdev
Works on Wayland and X11
"""

import os
import select
import signal
import subprocess
import sys
import time
from evdev import InputDevice, categorize, ecodes, list_devices

# PID file for tracking
PID_FILE = os.path.expanduser("~/.dictation_daemon.pid")

# Mouse button: BTN_EXTRA (Mouse 4)
MOUSE_BUTTON = ecodes.BTN_EXTRA

gui_process = None
recording_active = False


def cleanup(signum=None, frame=None):
    """Clean up PID file and GUI process on exit"""
    global gui_process

    # Terminate GUI process if running
    if gui_process and gui_process.poll() is None:
        gui_process.terminate()
        try:
            gui_process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            gui_process.kill()

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


def start_gui_background():
    """Start the GUI process in background mode (hidden)"""
    global gui_process

    script_dir = os.path.dirname(os.path.abspath(__file__))
    log_file = os.path.expanduser("~/.dictation_gui.log")

    # Set environment variable for ydotool socket
    env = os.environ.copy()
    env['YDOTOOL_SOCKET'] = '/tmp/.ydotool_socket'

    with open(log_file, "a") as log:
        log.write(f"\n--- GUI started in background mode ---\n")
        gui_process = subprocess.Popen(
            ["uv", "run", "python", "recorder_gui.py", "--push-to-talk", "--background"],
            cwd=script_dir,
            stdout=log,
            stderr=subprocess.STDOUT,
            env=env
        )

    # Give GUI time to initialize
    time.sleep(0.5)
    print(f"GUI process started in background (PID {gui_process.pid})")


def find_mouse_devices():
    """Find mouse devices with side buttons"""
    devices = [InputDevice(path) for path in list_devices()]

    # Filter for mice with side buttons
    mice = []
    for device in devices:
        # Skip virtual devices
        if 'virtual' in device.name.lower():
            continue
        # Must have mouse capabilities
        if ecodes.EV_KEY in device.capabilities():
            keys = device.capabilities()[ecodes.EV_KEY]
            # Must have side button (BTN_EXTRA or BTN_SIDE)
            if MOUSE_BUTTON in keys:
                mice.append(device)

    return mice


def handle_button_press():
    """Called when mouse button is pressed"""
    global gui_process, recording_active

    if recording_active:
        return

    # Check if GUI is still running
    if not gui_process or gui_process.poll() is not None:
        print("WARNING: GUI process died, restarting...")
        start_gui_background()

    print("Mouse button pressed! Starting recording...")
    recording_active = True

    # Send SIGUSR1 to GUI to start recording
    if gui_process and gui_process.poll() is None:
        try:
            gui_process.send_signal(signal.SIGUSR1)
        except Exception as e:
            print(f"Error sending signal to GUI: {e}")


def handle_button_release():
    """Called when mouse button is released"""
    global gui_process, recording_active

    if not recording_active:
        return

    print("Mouse button released! Stopping recording...")
    recording_active = False

    # Send SIGUSR2 to GUI to stop recording
    if gui_process and gui_process.poll() is None:
        try:
            gui_process.send_signal(signal.SIGUSR2)
        except Exception as e:
            print(f"Error sending signal to GUI: {e}")


def monitor_mice(devices):
    """Monitor multiple mouse devices simultaneously"""
    print(f"Monitoring {len(devices)} mouse device(s):")
    for device in devices:
        print(f"  - {device.name}")
    print()
    print(f"Waiting for Mouse 4 (BTN_EXTRA = {MOUSE_BUTTON}) press/release events...")
    print("Press and hold Mouse 4 (side button) to record")
    print("Release to stop and transcribe")
    print()

    # Create a dict mapping file descriptors to devices
    device_map = {dev.fd: dev for dev in devices}

    while True:
        # Wait for events from any device
        r, w, x = select.select(device_map, [], [])

        for fd in r:
            device = device_map[fd]

            for event in device.read():
                if event.type == ecodes.EV_KEY:
                    key_event = categorize(event)

                    # Debug: log all button events
                    if key_event.keystate in (key_event.key_down, key_event.key_up):
                        state = "PRESSED" if key_event.keystate == key_event.key_down else "RELEASED"
                        print(f"Button event: code={event.code} ({ecodes.BTN.get(event.code, 'UNKNOWN')}) {state}")

                    # Button pressed
                    if event.code == MOUSE_BUTTON:
                        if key_event.keystate == key_event.key_down:
                            print(f"*** MOUSE BUTTON 4 PRESSED ***")
                            handle_button_press()
                        # Button released
                        elif key_event.keystate == key_event.key_up:
                            print(f"*** MOUSE BUTTON 4 RELEASED ***")
                            handle_button_release()


if __name__ == "__main__":
    # Register signal handlers
    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    # Check if already running
    check_already_running()

    # Write PID file
    write_pid()

    # Find mouse devices
    print("Looking for mouse devices with side buttons...")
    devices = find_mouse_devices()

    if not devices:
        print("ERROR: No mouse devices with side buttons found!")
        print("Make sure you're in the 'input' group:")
        print("  sudo usermod -aG input $USER")
        print("Then log out and log back in.")
        cleanup()

    print(f"Dictation daemon running (PID {os.getpid()})")

    # Start GUI in background mode
    print("Starting GUI in background mode...")
    start_gui_background()

    print("Press Ctrl+C to quit.")
    print()

    try:
        # Monitor mice without grabbing (don't block system use)
        monitor_mice(devices)
    except PermissionError:
        print("ERROR: Permission denied accessing input device")
        print("Make sure you're in the 'input' group and have logged out/in")
        cleanup()
    finally:
        cleanup()
