#!/usr/bin/env python3
"""Test if pynput can detect keyboard events"""

from pynput import keyboard

def on_press(key):
    try:
        print(f"Key pressed: {key.char}")
    except AttributeError:
        print(f"Special key pressed: {key}")

def on_release(key):
    print(f"Key released: {key}")
    if key == keyboard.Key.esc:
        return False

print("Testing keyboard detection...")
print("Press ESC to quit")
print("Try pressing some keys...")

try:
    with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
        listener.join()
except Exception as e:
    print(f"Error: {e}")
    import traceback
    traceback.print_exc()
