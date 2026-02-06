#!/usr/bin/env python3
"""Quick test of pynput mouse listener."""

from pynput import mouse

def on_click(x, y, button, pressed):
    print(f"Click: button={button}, pressed={pressed}, pos=({x}, {y})")
    if button == mouse.Button.middle:
        print("  -> MIDDLE BUTTON DETECTED!")

print("Starting pynput mouse listener...")
print("Click any mouse button. Middle-click to test trigger.")
print("Press Ctrl+C to quit.")

with mouse.Listener(on_click=on_click) as listener:
    listener.join()
