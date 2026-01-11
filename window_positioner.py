"""
D-Bus client for GNOME Shell extension window positioning.

This module communicates with a GNOME Shell extension to position
windows at the mouse cursor - a workaround for Wayland's restrictions.
"""

import subprocess

DBUS_NAME = "com.dictation.WindowPositioner"
DBUS_PATH = "/com/dictation/WindowPositioner"
DBUS_INTERFACE = "com.dictation.WindowPositioner"


def position_window_at_mouse(wm_class: str) -> bool:
    """
    Request the GNOME Shell extension to position a window at the mouse cursor.

    Args:
        wm_class: The WM_CLASS of the window to position

    Returns:
        True if window was found and positioned, False otherwise
    """
    try:
        result = subprocess.run(
            [
                "gdbus", "call",
                "--session",
                "--dest", DBUS_NAME,
                "--object-path", DBUS_PATH,
                "--method", f"{DBUS_INTERFACE}.PositionAtMouse",
                wm_class
            ],
            capture_output=True,
            text=True,
            timeout=2
        )

        if result.returncode == 0:
            # Parse result like "(true,)" or "(false,)"
            return "true" in result.stdout.lower()
        else:
            print(f"[WindowPositioner] D-Bus error: {result.stderr}")
            return False

    except FileNotFoundError:
        print("[WindowPositioner] gdbus not found")
        return False
    except subprocess.TimeoutExpired:
        print("[WindowPositioner] D-Bus call timed out")
        return False
    except Exception as e:
        print(f"[WindowPositioner] Error: {e}")
        return False


def get_mouse_position() -> tuple[int, int] | None:
    """
    Get the current mouse position via the GNOME Shell extension.

    Returns:
        Tuple of (x, y) coordinates, or None if failed
    """
    try:
        result = subprocess.run(
            [
                "gdbus", "call",
                "--session",
                "--dest", DBUS_NAME,
                "--object-path", DBUS_PATH,
                "--method", f"{DBUS_INTERFACE}.GetMousePosition"
            ],
            capture_output=True,
            text=True,
            timeout=2
        )

        if result.returncode == 0:
            # Parse result like "(1234, 567)"
            import re
            match = re.search(r'\((\d+),\s*(\d+)\)', result.stdout)
            if match:
                return int(match.group(1)), int(match.group(2))
        return None

    except Exception as e:
        print(f"[WindowPositioner] Error getting mouse position: {e}")
        return None


def start_following(wm_class: str) -> bool:
    """
    Start following the mouse with the specified window.
    The extension will handle tracking internally at 60 FPS.

    Args:
        wm_class: The WM_CLASS/title of the window to follow

    Returns:
        True if following started, False otherwise
    """
    try:
        result = subprocess.run(
            [
                "gdbus", "call",
                "--session",
                "--dest", DBUS_NAME,
                "--object-path", DBUS_PATH,
                "--method", f"{DBUS_INTERFACE}.StartFollowing",
                wm_class
            ],
            capture_output=True,
            text=True,
            timeout=2
        )
        return result.returncode == 0 and "true" in result.stdout.lower()
    except:
        return False


def stop_following() -> bool:
    """
    Stop following the mouse.

    Returns:
        True if stopped successfully, False otherwise
    """
    try:
        result = subprocess.run(
            [
                "gdbus", "call",
                "--session",
                "--dest", DBUS_NAME,
                "--object-path", DBUS_PATH,
                "--method", f"{DBUS_INTERFACE}.StopFollowing"
            ],
            capture_output=True,
            text=True,
            timeout=2
        )
        return result.returncode == 0
    except:
        return False


def is_extension_available() -> bool:
    """Check if the GNOME Shell extension is running and responding."""
    try:
        result = subprocess.run(
            [
                "gdbus", "introspect",
                "--session",
                "--dest", DBUS_NAME,
                "--object-path", DBUS_PATH
            ],
            capture_output=True,
            timeout=2
        )
        return result.returncode == 0
    except:
        return False


if __name__ == "__main__":
    # Test the extension
    print("Testing GNOME Shell extension connection...")

    if is_extension_available():
        print("Extension is available!")

        pos = get_mouse_position()
        if pos:
            print(f"Mouse position: {pos}")
        else:
            print("Could not get mouse position")

        # Try positioning a test window
        print("\nTo test window positioning, run your app and then:")
        print('  python -c "from window_positioner import *; position_window_at_mouse(\'dictation\')"')
    else:
        print("Extension NOT available.")
        print("\nTo install:")
        print("  1. Copy extension to ~/.local/share/gnome-shell/extensions/")
        print("  2. Log out and back in (or restart GNOME Shell)")
        print("  3. Enable with: gnome-extensions enable dictation@local")
